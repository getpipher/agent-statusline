--!strict
-- Host-side API-key ladder for the quota pollers. Resolution order per plan:
--   1. tern.kv "asl/keys" — {zai="…", opencode="…"} published by the window half
--      from keychain secrets (tern.secrets has no host API).
--   2. Environment: ZAI_API_KEY / OPENCODE_API_KEY (the daemon's env).
--   3. zai only: $HOME/.pi/agent/auth.json — same fallback file omp-statusline
--      resolves (src/index.ts PI_AUTH_JSON); shape is quota/zai.ts readZaiKey:
--      a JSON object whose "zai" member holds {"key": "<string>"}.
-- Resolved fresh on every call; every lookup is fail-soft (nil, never raises).
local M = {}

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

-- Rung 1: shared kv store. tern.kv.get raises on read errors (stale mtime
-- reread, invalid JSON), so it goes through pcall.
local function kvKey(kind: string): string?
	local ok, keys = pcall(tern.kv.get, "asl/keys")
	if not ok or type(keys) ~= "table" then
		return nil
	end
	return nonEmptyString(keys[kind])
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
	return kvKey(kind) or envKey(kind) or (if kind == "zai" then authJsonZaiKey() else nil)
end

return M
