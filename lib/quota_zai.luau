--!strict
-- z.ai quota poller — port of omp-statusline src/quota/zai.ts (endpoint, auth,
-- response gate, field paths) plus its index.ts poller semantics (immediate
-- first poll, then interval; refresh forces one immediate poll; keep last-good
-- on failure). Emits one patch per cycle to the host snapshot merger:
--   { fetchedMs = <epoch ms>, windows = { {label, usagePct, elapsedPct,
--     paceOverSec, resetMs}, … } }
-- Labels follow omp index.ts L269-271: lowercase "5hrs" (unit 3), uppercase
-- "7DAY" (unit 6). Fail-soft: every failure delivers on_part(nil, reason) and
-- the timer loop re-arms on every path.
local keys = require("./keys")
local windows = require("./windows")

local QUOTA_API = "https://api.z.ai/api/monitor/usage/quota/limit"
local DEFAULT_POLL_MS = 180000
local MIN_POLL_MS = 30000
-- quota/zai.ts fetchQuota: AbortSignal.timeout(10_000).
local FETCH_TIMEOUT_MS = 10000

local M = {}
local onPart: ((part: any, err: string?) -> ())? = nil
local generation = 0

-- Fresh per cycle: kv "asl/config".zaiPollMs, default 180000, floor 30000.
-- tern.kv.get can raise on read errors — pcall and fall back to the default.
local function pollMs(): number
	local ok, cfg = pcall(tern.kv.get, "asl/config")
	if ok and type(cfg) == "table" then
		local v = cfg.zaiPollMs
		if type(v) == "number" and v == v and v < math.huge and v > 0 then
			return math.max(MIN_POLL_MS, math.floor(v))
		end
	end
	return DEFAULT_POLL_MS
end

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- parseQuotaLimit: all seven numeric fields must be finite, else the limit is
-- skipped (TS `continue`s past it; the response can still yield the other
-- window).
local LIMIT_FIELDS = { "unit", "number", "usage", "currentValue", "remaining", "percentage", "nextResetTime" }

local function parseLimit(entry: any): any
	if type(entry) ~= "table" then
		return nil
	end
	for i = 1, #LIMIT_FIELDS do
		if not finite(entry[LIMIT_FIELDS[i]]) then
			return nil
		end
	end
	return entry
end

-- parseQuotaResponse: {code: 200, success: true, data: {level, limits: [...]}}.
-- unit 3 → 5-hour window, unit 6 → weekly (later duplicates win, as in TS).
local function parseBody(body: string): any
	local ok, parsed = pcall(tern.json.decode, body)
	if not ok or type(parsed) ~= "table" then
		return nil
	end
	if parsed.code ~= 200 or parsed.success ~= true then
		return nil
	end
	local data = parsed.data
	if type(data) ~= "table" then
		return nil
	end
	local limits = data.limits
	if type(limits) ~= "table" or #limits == 0 then
		return nil
	end
	local level = data.level
	if level ~= "lite" and level ~= "pro" and level ~= "max" then
		return nil
	end
	local fiveHour: any = nil
	local weekly: any = nil
	for i = 1, #limits do
		local limit = parseLimit(limits[i])
		if limit then
			if limit.unit == 3 then
				fiveHour = limit
			elseif limit.unit == 6 then
				weekly = limit
			end
		end
	end
	if not fiveHour and not weekly then
		return nil
	end
	return { fiveHour = fiveHour, weekly = weekly }
end

-- Result → patch, fail-soft. Returns (patch, nil) or (nil, reason). Runs in
-- the fetch callback (its own 2 s `fetch` hook budget).
local function handleResult(result: any): (any, string?)
	if type(result) ~= "table" then
		return nil, "zai fetch: no response"
	end
	if result.error ~= nil then
		return nil, "zai network: " .. tostring(result.error)
	end
	if result.status < 200 or result.status >= 300 then
		return nil, "zai http " .. tostring(result.status)
	end
	local parsed = parseBody(result.body)
	if not parsed then
		return nil, "zai parse"
	end
	-- Wall clock only: tern.now is monotonic and never feeds reset math.
	local now = os.time() * 1000
	local windowsOut = tern.json.array({})
	local spec = {
		{ label = "5hrs", limit = parsed.fiveHour, len = windows.FIVE_HOUR_MS },
		{ label = "7DAY", limit = parsed.weekly, len = windows.WEEK_MS },
	}
	for i = 1, #spec do
		local s = spec[i]
		local limit = s.limit
		if limit then
			local elapsedPct = windows.windowElapsedPercent(limit.nextResetTime, s.len, now)
			windowsOut[#windowsOut + 1] = {
				label = s.label,
				usagePct = limit.percentage,
				elapsedPct = elapsedPct,
				paceOverSec = windows.paceSeconds(s.len, limit.percentage, elapsedPct) / 1000,
				resetMs = limit.nextResetTime,
			}
		end
	end
	return { fetchedMs = now, windows = windowsOut }, nil
end

local scheduleNext: (number) -> ()
local startCycle: (number) -> ()

-- Deliver once and re-arm; the loop continues on every path (error callbacks
-- included). on_part itself is pcall'd so a host-side raise can never kill it.
local function finishCycle(gen: number, patch: any, err: string?)
	local cb = onPart
	if cb then
		if err ~= nil then
			pcall(cb, nil, err)
		else
			pcall(cb, patch, nil)
		end
	end
	scheduleNext(pollMs())
end

-- One poll cycle, fail-soft. tern.fetch runs off the VM's thread and only its
-- callback comes back (runtime.md, "Timers, process and fetch callbacks"), so
-- the checks and patch math run inside the cb under its own `fetch` budget. A
-- cycle that never starts a fetch (no key, fetch raise) finishes inline;
-- fetch-raise and cb-fire are mutually exclusive, so delivery stays
-- exactly-once per cycle.
local function startCycle(gen: number)
	local key = keys.resolve("zai")
	if type(key) ~= "string" then
		finishCycle(gen, nil, "no key")
		return
	end
	local ok, err = pcall(tern.fetch, QUOTA_API, {
		headers = {
			Authorization = "Bearer " .. key,
			Accept = "application/json",
		},
		timeout_ms = FETCH_TIMEOUT_MS,
	}, function(result: any)
		if generation ~= gen then
			return -- superseded while in flight (refresh); that cycle delivers
		end
		local okPatch, patch, ferr = pcall(handleResult, result)
		if not okPatch then
			patch, ferr = nil, "zai internal: " .. tostring(patch)
		end
		finishCycle(gen, patch, ferr)
	end)
	if not ok then
		-- fetch never started (malformed args): no cb will fire for it
		finishCycle(gen, nil, "zai internal: " .. tostring(err))
	end
end

-- Self-re-arming one-shot tern.timer. Each schedule invalidates any pending
-- tick via a generation counter, so refresh() can force an immediate cycle
-- without ever leaving two live chains.
function scheduleNext(ms: number)
	generation += 1
	local gen = generation
	tern.timer(ms, function()
		if generation ~= gen then
			return -- superseded by a refresh; that call owns scheduling
		end
		startCycle(gen)
	end)
end

function M.start(on_part: (part: any, err: string?) -> ())
	if onPart ~= nil then
		return -- already started; a reload replaces the whole VM
	end
	onPart = on_part
	scheduleNext(0) -- omp poller: fires immediately on start
end

function M.refresh()
	scheduleNext(0)
end

return M
