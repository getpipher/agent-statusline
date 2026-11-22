--!strict
-- OpenCode Go plan quota poller — port of omp-statusline src/quota/opencode.ts
-- (endpoint, auth, response shape) plus quota/zai.ts poller semantics
-- (immediate first poll, then interval; refresh forces one immediate poll;
-- keep last-good on failure). Emits one patch per cycle to the host snapshot
-- merger:
--   { fetchedMs = <epoch ms>, windows = { {label, usagePct, elapsedPct,
--     paceOverSec, resetMs}, … } }
-- Labels follow omp index.ts L286-287 + the MONTH rule: rolling → "5hrs",
-- weekly → "7DAY", monthly → "MONTH" — MONTH is the anniversary-based meter
-- (windows.monthlyWindowMs), not a rolling 30 days. Fail-soft: every failure
-- delivers on_part(nil, reason) and the timer loop re-arms on every path.
local keys = require("./keys")
local bridge = require("./bridge")
local windows = require("./windows")

local QUOTA_API = "https://opencode.ai/zen/go/v1/usage"
local DEFAULT_POLL_MS = 180000
local MIN_POLL_MS = 30000
-- opencode.ts fetchOpencodeQuota: AbortSignal.timeout(10_000).
local FETCH_TIMEOUT_MS = 10000

local M = {}
local onPart: ((part: any, err: string?) -> ())? = nil
local generation = 0

-- Fresh per cycle: the verified config file (kv fallback) via lib/bridge —
-- default 180000, floor 30000. bridge never raises.
local function pollMs(): number
	local cfg = bridge.readConfig()
	local v = cfg.opencodePollMs
	if type(v) == "number" and v == v and v < math.huge and v > 0 then
		return math.max(MIN_POLL_MS, math.floor(v))
	end
	return DEFAULT_POLL_MS
end

-- Hinnant days_from_civil, same algorithm as lib/windows.luau (not exported
-- there, so a local copy). Pure UTC civil-date → day-number math.
local function daysFromCivil(y: number, m: number, d: number): number
	local yy = y
	if m <= 2 then
		yy -= 1
	end
	local era = math.floor((if yy >= 0 then yy else yy - 399) / 400)
	local yoe = yy - era * 400
	local doy = math.floor((153 * (if m > 2 then m - 3 else m + 9) + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

-- JS Date.parse for the ISO-8601 shapes this API emits:
-- "YYYY-MM-DDTHH:MM:SS(.frac)?(Z | ±HH:MM | ±HHMM | ±HH)". Returns epoch ms,
-- or nil when unparseable (the TS port would skip the window, so do we).
local function parseIsoMs(s: string): number?
	local y, mo, d, timePart = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)[Tt ](.*)$")
	if not (y and mo and d and timePart) then
		return nil
	end
	local h, mi, sec, frac, off = timePart:match("^(%d%d):(%d%d):(%d%d)%.?(%d*)(.-)$")
	if not (h and mi and sec) then
		return nil
	end
	local offsetSec = 0
	if off ~= "" and off ~= "Z" and off ~= "z" then
		-- Normalize "+HH:MM" to "+HHMM", then allow two- or three-digit forms.
		local flat = off:gsub(":", "")
		local sign, oh, om = flat:match("^([+-])(%d%d)(%d%d?)$")
		if not sign then
			sign, oh = flat:match("^([+-])(%d%d)$")
			om = nil
		end
		if not sign then
			return nil
		end
		offsetSec = (tonumber(oh) or 0) * 3600 + (tonumber(om) or 0) * 60
		if sign == "-" then
			offsetSec = -offsetSec
		end
	end
	local ms = 0
	if frac ~= nil and frac ~= "" then
		ms = tonumber((frac .. "000"):sub(1, 3)) or 0
	end
	local days = daysFromCivil(tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number)
	local secs = days * 86400
		+ (tonumber(h) :: number) * 3600
		+ (tonumber(mi) :: number) * 60
		+ (tonumber(sec) :: number)
		- offsetSec
	return secs * 1000 + ms
end

-- opencode.ts parseWindow: percent must be a finite number and resetsAt a
-- Date.parse-able string, else the window is dropped. API `status` is carried
-- by the TS type but unused by the rendered rows, so not ported.
local function parseWindow(entry: any): (number?, number?)
	if type(entry) ~= "table" then
		return nil, nil
	end
	local pct = entry.percent
	if type(pct) ~= "number" or pct ~= pct or pct == math.huge or pct == -math.huge then
		return nil, nil
	end
	local resetsAt = entry.resetsAt
	if type(resetsAt) ~= "string" then
		return nil, nil
	end
	local resetMs = parseIsoMs(resetsAt)
	if not resetMs then
		return nil, nil
	end
	return pct, resetMs
end

local function addWindow(out: { any }, label: string, entry: any, fixedLen: number?, now: number): boolean
	local pct, resetMs = parseWindow(entry)
	if not pct or not resetMs then
		return false
	end
	-- MONTH gets the anniversary window ending at resetsAt; the others are fixed.
	local len = if fixedLen ~= nil then fixedLen else windows.monthlyWindowMs(resetMs)
	local elapsedPct = windows.windowElapsedPercent(resetMs, len, now)
	out[#out + 1] = {
		label = label,
		usagePct = pct,
		elapsedPct = elapsedPct,
		paceOverSec = windows.paceSeconds(len, pct, elapsedPct) / 1000,
		resetMs = resetMs,
	}
	return true
end

-- opencode.ts parseOpencodeQuota: needs a table `usage`; null members are
-- dropped by tern.json.decode, so absent/null windows come back nil. At least
-- one window must survive (TS returns null otherwise).
local function parseBody(body: string, now: number): any
	local ok, parsed = pcall(tern.json.decode, body)
	if not ok or type(parsed) ~= "table" then
		return nil
	end
	local usage = parsed.usage
	if type(usage) ~= "table" then
		return nil
	end
	local out = tern.json.array({})
	local count = 0
	if addWindow(out, "5hrs", usage.rolling, windows.FIVE_HOUR_MS, now) then
		count += 1
	end
	if addWindow(out, "7DAY", usage.weekly, windows.WEEK_MS, now) then
		count += 1
	end
	if addWindow(out, "MONTH", usage.monthly, nil, now) then
		count += 1
	end
	if count == 0 then
		return nil
	end
	return out
end

-- Result → patch, fail-soft. Returns (patch, nil) or (nil, reason). Runs in
-- the fetch callback (its own 2 s `fetch` hook budget).
local function handleResult(result: any): (any, string?)
	if type(result) ~= "table" then
		return nil, "opencode fetch: no response"
	end
	if result.error ~= nil then
		return nil, "opencode network: " .. tostring(result.error)
	end
	if result.status < 200 or result.status >= 300 then
		return nil, "opencode http " .. tostring(result.status)
	end
	-- Wall clock only: tern.now is monotonic and never feeds reset math.
	local now = os.time() * 1000
	local windowsOut = parseBody(result.body, now)
	if not windowsOut then
		return nil, "opencode parse"
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
	local key = keys.resolve("opencode")
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
			patch, ferr = nil, "opencode internal: " .. tostring(patch)
		end
		finishCycle(gen, patch, ferr)
	end)
	if not ok then
		-- fetch never started (malformed args): no cb will fire for it
		finishCycle(gen, nil, "opencode internal: " .. tostring(err))
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
