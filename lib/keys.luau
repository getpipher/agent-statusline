--!strict
-- API-key ladder for the quota pollers (host reads; the window half stores).
-- Resolution order:
--   1. tern.kv "asl/keys" — {zai="…", opencode="…"}, the designed window→host
--      bridge. The window half's tern.kv writes have never been observed
--      landing in the host's persisted store, so this rung is best-effort.
--   2. Keys FILE — <tern.plugin.data>/keys.json (the dir that holds kv.json),
--      written by the window half alongside the kv write and read back to
--      verify. The channel callers bet on; M.store returns whether it landed.
--   3. Environment: ZAI_API_KEY / OPENCODE_API_KEY (the daemon's env).
--   4. zai only: $HOME/.pi/agent/auth.json — same fallback file omp-statusline
--      resolves (src/index.ts PI_AUTH_JSON); shape is quota/zai.ts readZaiKey:
--      a JSON object whose "zai" member holds {"key": "<string>"}.
-- Resolved fresh on every call; every lookup is fail-soft (nil, never raises).
-- The keys file holds plaintext secrets in the user-scoped Tern state dir —
-- same at-rest model as ~/.pi/agent/auth.json (mode 600, user-owned dir).
local M = {}

-- Where the keys file lives: the plugin's own data dir (tern.plugin.data —
-- the same directory that holds kv.json), so the path is host-independent.
local function keysFilePath(): string
	local okData, data = pcall(function()
		return tern.plugin.data
	end)
	if okData and type(data) == "string" and data ~= "" then
		return data .. "/keys.json"
	end
	return ""
end

-- Window-side entry point: the designed kv write (best-effort — it may
-- silently not reach the host's store), then the keys file ALWAYS, and the
-- file write is self-verifying: read back, decode, compare every member.
-- Returns true only when the file provably holds the payload, so callers can
-- gate their success toast on a channel that demonstrably landed.
function M.store(keys: any): boolean
	pcall(tern.kv.set, "asl/keys", keys)
	local path = keysFilePath()
	if path == "" then
		return false
	end
	if not pcall(tern.fs.write, path, tern.json.encode(keys)) then
		return false
	end
	local okRead, raw = pcall(tern.fs.read, path)
	if not okRead or type(raw) ~= "string" then
		return false
	end
	local okJson, parsed = pcall(tern.json.decode, raw)
	if not okJson or type(parsed) ~= "table" then
		return false
	end
	for member, value in keys do
		if parsed[member] ~= value then
			return false
		end
	end
	return true
end

local ENV_NAMES: { [string]: string } = {
	zai = "ZAI_API_KEY",
	opencode = "OPENCODE_API_KEY",
}

local function nonEmptyString(v: any): string?
	if type(v) == "string" and v ~= "" then
		return v
	end
	return nil
end

-- Rung 1: shared kv store. tern.kv.get can raise on read errors (stale mtime
-- reread, invalid JSON), so it goes through pcall.
local function kvKey(kind: string): string?
	local ok, keys = pcall(tern.kv.get, "asl/keys")
	if not ok or type(keys) ~= "table" then
		return nil
	end
	return nonEmptyString(keys[kind])
end

-- Rung 1b: keys file written by the window half (see header). Same fail-soft
-- shape checks as kvKey.
local function fileKey(kind: string): string?
	local path = keysFilePath()
	if path == "" then
		return nil
	end
	local okRead, raw = pcall(tern.fs.read, path)
	if not okRead or type(raw) ~= "string" then
		return nil
	end
	local okJson, parsed = pcall(tern.json.decode, raw)
	if not okJson or type(parsed) ~= "table" then
		return nil
	end
	return nonEmptyString(parsed[kind])
end

-- Rung 2: daemon environment.
local function envKey(kind: string): string?
	local ok, v = pcall(tern.getenv, ENV_NAMES[kind])
	if not ok then
		return nil
	end
	return nonEmptyString(v)
end

-- Rung 3 (zai only): $HOME/.pi/agent/auth.json with {"zai":{"key":"…"}}.
-- Mirrors quota/zai.ts readZaiKey exactly: unreadable file, invalid JSON,
-- missing/typless zai member or key → nil.
local function authJsonZaiKey(): string?
	local okHome, home = pcall(tern.getenv, "HOME")
	if not okHome or type(home) ~= "string" or home == "" then
		return nil
	end
	local okRead, raw = pcall(tern.fs.read, home .. "/.pi/agent/auth.json")
	if not okRead or type(raw) ~= "string" then
		return nil
	end
	local okJson, parsed = pcall(tern.json.decode, raw)
	if not okJson or type(parsed) ~= "table" then
		return nil
	end
	local zai = parsed.zai
	if type(zai) ~= "table" then
		return nil
	end
	return nonEmptyString(zai.key)
end

function M.resolve(kind: "zai" | "opencode"): string?
	if kind ~= "zai" and kind ~= "opencode" then
		return nil
	end
	return kvKey(kind) or fileKey(kind) or envKey(kind)
		or (if kind == "zai" then authJsonZaiKey() else nil)
end

return M
