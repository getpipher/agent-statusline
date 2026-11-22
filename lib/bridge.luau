--!strict
-- Window→host command channel for config and manual refresh.
-- tern.kv writes from the window VM have never been observed landing in the
-- host's persisted store (same diagnosis as lib/keys.luau), so both commands
-- ALSO write a read-back-verified file in <tern.plugin.data> (the dir holding
-- kv.json). Config reads that file first so stale kv cannot mask newer values;
-- refresh returns the max of both rungs so a kv-only stamp still forces a poll
-- when the file write failed.
-- Every native call is pcall'd; no lookup here raises.
local M = {}

local function dataPath(name: string): string
	local okData, data = pcall(function()
		return tern.plugin.data
	end)
	if okData and type(data) == "string" and data ~= "" then
		return data .. "/" .. name .. ".json"
	end
	return ""
end

local function readJsonFile(path: string): any?
	if path == "" then
		return nil
	end
	local okRead, raw = pcall(tern.fs.read, path, 16384)
	if not okRead or type(raw) ~= "string" then
		return nil
	end
	local okJson, parsed = pcall(tern.json.decode, raw)
	if not okJson or type(parsed) ~= "table" then
		return nil
	end
	return parsed
end

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function M.storeConfig(cfg: any): boolean
	pcall(tern.kv.set, "asl/config", cfg)
	local path = dataPath("config")
	if path == "" then
		return false
	end
	local okEnc, encoded = pcall(tern.json.encode, cfg)
	if not okEnc then
		return false
	end
	if not pcall(tern.fs.write, path, encoded) then
		return false
	end
	local saved = readJsonFile(path)
	if saved == nil then
		return false
	end
	for member, value in cfg do
		if saved[member] ~= value then
			return false
		end
	end
	return true
end

function M.readConfig(): any
	local saved = readJsonFile(dataPath("config"))
	if saved ~= nil then
		return saved
	end
	local ok, cfg = pcall(tern.kv.get, "asl/config")
	if ok and type(cfg) == "table" then
		return cfg
	end
	return {}
end

-- Strictly increasing stamps: two clicks within one os.time() second must not
-- produce an equal stamp that the host would ignore as already handled.
local lastStamp = 0

function M.requestRefresh(): boolean
	local stamp = math.max(os.time() * 1000, lastStamp + 1)
	lastStamp = stamp
	pcall(tern.kv.set, "asl/refresh-request", stamp)
	local path = dataPath("refresh")
	if path == "" then
		return false
	end
	local okEnc, encoded = pcall(tern.json.encode, { requestMs = stamp })
	if not okEnc then
		return false
	end
	if not pcall(tern.fs.write, path, encoded) then
		return false
	end
	local saved = readJsonFile(path)
	return saved ~= nil and saved.requestMs == stamp
end

function M.readRefresh(): number?
	local fromFile = readJsonFile(dataPath("refresh"))
	local fileStamp: number? = nil
	if fromFile ~= nil and finite(fromFile.requestMs) then
		fileStamp = fromFile.requestMs
	end
	local ok, v = pcall(tern.kv.get, "asl/refresh-request")
	local kvStamp: number? = nil
	if ok and finite(v) then
		kvStamp = v
	end
	if fileStamp ~= nil and kvStamp ~= nil then
		return math.max(fileStamp, kvStamp)
	end
	return fileStamp or kvStamp
end

return M
