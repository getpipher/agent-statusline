--!strict
-- Deen poller ported from omp-statusline src/deen/{source,api,time,cache}.ts:
-- aladhan timingsByCity prayer times, gToH hijri rollover at Maghrib, per
-- city-day cache in tern.kv, boundary-driven self-re-arming tern.timer loop.
--
-- PATCH (delivered once per cycle via on_part; the host merges it into
-- asl/snapshot.deen — this module NEVER writes kv "asl/snapshot"):
--   {
--     city = "Jakarta",                    -- resolved city (ipwho.is answer when config city == "auto")
--     hijri = "27 Rabīʿ al-awwal 1448",    -- Maghrib-rollover-resolved hijri, omp infoLine format
--     gregorian = "19 Nov 2026",           -- format.formatGregorian(nowEpochMs)
--     prayers = {                          -- exactly five, omp display order
--       { name = "Fajr", time = "04:12", past = false },  -- time "HH:MM" city wall clock;
--       { name = "Dhuhr", ... }, { name = "Asr", ... },   -- past = minutesUntil <= 0
--       { name = "Maghrib", ... }, { name = "Isha", ... },-- (covers omp's past + adhan ✓ states)
--     },
--     nextPrayer = { name = "Asr", inSec = 4213 },  -- never nil: after Isha it is
--   }                                               -- tomorrow's Fajr (inSec + 86400)
--
-- kv CACHE "asl/deen" — one current city-day record (older days are overwritten):
--   {
--     key = "<city>|<country>|<method>|<YYYY-MM-DD>",  -- machine-local date
--     fetchedAt = <epoch ms>,            -- written ONLY on a successful fetch
--     data = {                           -- exactly api.ts's DeenData
--       prayers = { Fajr = "04:12", Dhuhr = "...", Asr = "...", Maghrib = "...", Isha = "..." },
--       timezone = "Asia/Jakarta",       -- IANA name from aladhan meta (stored, unused: see TZ NOTE)
--       hijri = "27 Rabīʿ al-awwal 1448",
--     },
--     geo = { city, country, timezone, fetchedAt } | nil,  -- ipwho.is answer, 7-day TTL
--     tomorrowHijri = "28 Rabīʿ al-awwal 1448" | nil,      -- gToH answer for the hijri
--   }                                                      -- day starting tonight at Maghrib
-- Freshness = key matches today's city|country|method|date AND age < 24 h
-- (cache.ts isDataFresh). Corrupt/missing cache = cold start, never fatal.
-- A failed cycle writes no cache, so the next cycle refetches automatically.
--
-- HIJRI ROLLOVER (time.ts maghribRolloverActive): once the wall clock reaches the
-- Maghrib minute the Islamic day has turned, so hijri = gToH(DD-MM-YYYY of
-- now + 24 h) — tomorrow's hijri. Cached in tomorrowHijri; a failed fetch keeps
-- today's hijri and retries at most every 5 min; before Maghrib it is today's.
--
-- CADENCE: the next timer fires at the next interesting boundary — the next
-- prayer's state flip (one minute before its wall time, where minutesUntil hits
-- 0), local midnight (cache-key day roll), a pending Maghrib rollover retry
-- (≤ 5 min), or a pending manual refresh (2 s) — capped at 15 min so config
-- city changes apply promptly. Failures retry after 5 min. Fetch timeouts 5 s.
--
-- TZ NOTE: Luau has no Intl/IANA tz database. All wall-clock math (prayer
-- minute comparisons, cache date key, gToH date param, day rollover) uses
-- MACHINE-LOCAL time (os.date/os.time), matching lib/format.luau's convention.
-- Exact when the host clock shares the configured city's zone (the default:
-- Jakarta on a WIB machine); otherwise minutes skew by the zone offset.
--
-- PUBLIC API:
--   M.start(on_part)  — start the loop; on_part(patch, nil) on success,
--                       on_part(nil, "deen <reason>") on failure, exactly once
--                       per cycle. Never raises.
--   M.refresh()       — force one immediate cycle, then the loop resumes
--                       (no-op before start or while a cycle is mid-fetch).

local M = {}

local format = require("./format")
local bridge = require("./bridge")

-- --- api.ts constants ---
local ALADHAN_URL = "https://api.aladhan.com/v1/timingsByCity"
local G_TO_H_URL = "https://api.aladhan.com/v1/gToH"
local GEO_URL = "https://ipwho.is/"

local PRAYER_NAMES = { "Fajr", "Dhuhr", "Asr", "Maghrib", "Isha" }

-- --- timing knobs (source.ts/cache.ts) ---
local DAY_MS = 86400000
local GEO_TTL_MS = 7 * DAY_MS
local HIJRI_RETRY_MS = 5 * 60000
local MAX_WAIT_MS = 15 * 60000 -- boundary cap so config changes apply promptly
local FAIL_WAIT_MS = 5 * 60000
local REFRESH_WAIT_MS = 2000

-- kv contract defaults (asl/config nil/missing fields fall back here).
local DEFAULT_CITY = "Jakarta"
local DEFAULT_COUNTRY = "Indonesia"
local DEFAULT_METHOD = "auto"

-- --- loop state (per VM, like source.ts's closure state) ---
local onPart: ((part: any, err: string?) -> ())? = nil
local started = false
local cycleActive = false
local pending: any = nil -- tern TimerHandle
local lastHijriAttempt = 0 -- HIJRI_RETRY_MS throttle, source.ts lastHijriAttempt
local lastHandledRefresh = 0

-- --- time.ts wall-clock helpers, machine-local (see TZ NOTE) ---

-- JS-style epoch ms; os.time() is second-resolution, plenty for minute math.
local function nowMs(): number
	return os.time() * 1000
end

-- source.ts localDateKey: local YYYY-MM-DD cache-key component.
local function localDateKey(now: number): string
	return os.date("%Y-%m-%d", math.floor(now / 1000)) :: string
end

-- time.ts gToHDateParam: DD-MM-YYYY of now+24h — the gToH query for the hijri
-- day that begins at this evening's Maghrib (only called while rollover is
-- active, so +24h always lands on the next civil date).
local function gToHDateParam(now: number): string
	return os.date("%d-%m-%Y", math.floor(now / 1000) + 86400) :: string
end

local function wallClockParts(now: number): (number, number, number)
	local d = os.date("*t", math.floor(now / 1000))
	return d.hour, d.min, d.sec
end

-- time.ts wallSeconds: seconds since local midnight.
local function wallSeconds(now: number): number
	local h, m, s = wallClockParts(now)
	return h * 3600 + m * 60 + s
end

-- time.ts wallMinutes: minutes since local midnight.
local function wallMinutes(now: number): number
	local h, m = wallClockParts(now)
	return h * 60 + m
end

-- time.ts parseWallMin: "HH:MM" → minutes since midnight.
local function parseWallMin(hhmm: string): number
	local h, m = hhmm:match("^(%d%d):(%d%d)$")
	return (tonumber(h) or 0) * 60 + (tonumber(m) or 0)
end

-- api.ts WALL_TIME (^([01]\d|2[0-3]):[0-5]\d$) — Luau patterns have no
-- alternation, so match "DD:DD" and range-check; same acceptance set.
local function validWall(v: any): boolean
	if type(v) ~= "string" then
		return false
	end
	local h, m = v:match("^(%d%d):(%d%d)$")
	if h == nil or m == nil then
		return false
	end
	local hn, mn = tonumber(h) :: number, tonumber(m) :: number
	return hn <= 23 and mn <= 59
end

-- --- api.ts response parsing ---

-- api.ts parseHijri: `${day} ${month.en} ${year}` e.g. "27 Rabīʿ al-awwal 1448".
local function parseHijri(h: any): string?
	if type(h) ~= "table" then
		return nil
	end
	local month = if type(h.month) == "table" then h.month.en else nil
	if type(h.day) ~= "string" or type(h.year) ~= "string" or type(month) ~= "string" then
		return nil
	end
	return h.day .. " " .. month .. " " .. h.year
end

-- api.ts parseTimingsResponse: code 200, status "OK", meta.timezone, hijri,
-- and all five prayer names matching WALL_TIME → DeenData, else nil.
local function parseTimings(body: string): any?
	local ok, parsed = pcall(function(): any
		return tern.json.decode(body)
	end)
	if not ok or type(parsed) ~= "table" then
		return nil
	end
	if parsed.code ~= 200 or parsed.status ~= "OK" or type(parsed.data) ~= "table" then
		return nil
	end
	local data: any = parsed.data
	if type(data.timings) ~= "table" then
		return nil
	end
	local timezone = if type(data.meta) == "table" then data.meta.timezone else nil
	local hijri = if type(data.date) == "table" then parseHijri(data.date.hijri) else nil
	if type(timezone) ~= "string" or hijri == nil then
		return nil
	end
	local prayers: any = {}
	for _, name in PRAYER_NAMES do
		local v = data.timings[name]
		if not validWall(v) then
			return nil
		end
		prayers[name] = v
	end
	return { prayers = prayers, timezone = timezone, hijri = hijri }
end

-- api.ts fetchHijriForDate's parser: code 200 + data.hijri → hijri string.
local function parseGToH(body: string): string?
	local ok, parsed = pcall(function(): any
		return tern.json.decode(body)
	end)
	if not ok or type(parsed) ~= "table" then
		return nil
	end
	if parsed.code ~= 200 or type(parsed.data) ~= "table" then
		return nil
	end
	return parseHijri(parsed.data.hijri)
end

-- Percent-encode a query value (URLSearchParams stand-in); space → %20.
local function enc(v: string): string
	return (v:gsub("[^%w%-_.~]", function(c: string): string
		return string.format("%%%02X", string.byte(c))
	end))
end

-- TS res.ok: whole response arrived and status is 2xx.
local function resOk(res: any): boolean
	return type(res) == "table" and res.error == nil and res.status >= 200 and res.status < 300
end

-- --- kv cache (cache.ts loadDeenCache/saveDeenCache over tern.kv) ---

local function readCache(): any?
	local ok, v = pcall(tern.kv.get, "asl/deen")
	if not ok or type(v) ~= "table" then
		return nil
	end
	if type(v.key) ~= "string" or type(v.fetchedAt) ~= "number" or type(v.data) ~= "table" then
		return nil
	end
	if not (v.fetchedAt > 0) then
		return nil
	end
	local data: any = v.data
	if type(data.prayers) ~= "table" or type(data.timezone) ~= "string" or type(data.hijri) ~= "string" then
		return nil
	end
	for _, name in PRAYER_NAMES do
		if not validWall(data.prayers[name]) then
			return nil
		end
	end
	-- TS's typeof guards: drop corrupt optional fields instead of NaN-comparing
	-- or a raise at `key = city .. "|" .. country` string concat.
	if v.geo ~= nil then
		if
			type(v.geo) ~= "table"
			or type(v.geo.fetchedAt) ~= "number"
			or type(v.geo.city) ~= "string"
			or type(v.geo.country) ~= "string"
		then
			v.geo = nil
		end
	end
	if v.tomorrowHijri ~= nil and type(v.tomorrowHijri) ~= "string" then
		v.tomorrowHijri = nil
	end
	return v
end

-- Non-fatal write (cache.ts: locked-down dir / full disk degrades to memory).
local function writeCache(rec: any)
	pcall(tern.kv.set, "asl/deen", rec)
end

-- --- config (verified file first via lib/bridge; read fresh, never write) ---

local function readConfig(): (string, string, string)
	local city, country, method = DEFAULT_CITY, DEFAULT_COUNTRY, DEFAULT_METHOD
	local cfg = bridge.readConfig()
	if type(cfg.city) == "string" and #cfg.city > 0 then
		city = cfg.city
	end
	if type(cfg.country) == "string" and #cfg.country > 0 then
		country = cfg.country
	end
	if type(cfg.method) == "string" and #cfg.method > 0 then
		method = cfg.method
	end
	return city, country, method
end

-- Manual refresh stamp ("asl/refresh-request"); newer than last handled → force.
local function refreshPending(): boolean
	local v = bridge.readRefresh()
	return v ~= nil and v > lastHandledRefresh
end

-- --- network ---
-- Every async continuation body runs under safePhase: a raise there would
-- otherwise leave cycleActive stuck true with no successor timer scheduled
-- (loop dead until reload). finish's delivered-guard absorbs a body that
-- raised after already delivering.

-- Runs one continuation body; a raise becomes a failed cycle.
local function safePhase(finish: (any, string?, number?) -> (), fn: () -> ())
	local ok, err = pcall(fn)
	if not ok then
		finish(nil, "deen " .. tostring(err), FAIL_WAIT_MS)
	end
end

-- source.ts defaultFetchGeo: ipwho.is → {city, country, timezone, fetchedAt}.
local function fetchGeo(finish: (any, string?, number?) -> (), cb: (any?) -> ())
	tern.fetch(GEO_URL, { timeout_ms = 5000 }, function(res: any)
		safePhase(finish, function()
			local geo: any = nil
			if resOk(res) then
				local ok, j = pcall(function(): any
					return tern.json.decode(res.body)
				end)
				if
					ok
					and type(j) == "table"
					and j.success == true
					and type(j.city) == "string"
					and type(j.country) == "string"
					and type(j.timezone) == "table"
					and type(j.timezone.id) == "string"
				then
					geo = { city = j.city, country = j.country, timezone = j.timezone.id, fetchedAt = nowMs() }
				end
			end
			cb(geo)
		end)
	end)
end

-- source.ts resolveHijri (v0.6.0 Maghrib rollover): pick the hijri the snapshot
-- renders and, when a gToH fetch produced it, the value to persist. Callback
-- receives (hijri, tomorrow | nil); every terminal branch calls cb exactly once.
-- Sync branches run inside the caller's wrapped phase; the gToH fetch callback
-- wraps itself.
local function resolveHijri(
	data: any,
	cachedTomorrow: any,
	allowFetch: boolean,
	finish: (any, string?, number?) -> (),
	cb: (string, string?) -> ()
)
	local now = nowMs()
	-- Before the city's Maghrib minute the Islamic day is still today's.
	if wallMinutes(now) < parseWallMin(data.prayers.Maghrib) then
		cb(data.hijri, nil)
		return
	end
	if type(cachedTomorrow) == "string" then
		cb(cachedTomorrow, cachedTomorrow)
		return
	end
	if not allowFetch then
		cb(data.hijri, nil)
		return
	end
	if now - lastHijriAttempt < HIJRI_RETRY_MS then
		cb(data.hijri, nil)
		return
	end
	lastHijriAttempt = now
	local url = G_TO_H_URL .. "?date=" .. enc(gToHDateParam(now))
	tern.fetch(url, { headers = { Accept = "application/json" }, timeout_ms = 5000 }, function(res: any)
		safePhase(finish, function()
			local tomorrow: string? = nil
			if resOk(res) then
				tomorrow = parseGToH(res.body)
			end
			if tomorrow == nil then
				cb(data.hijri, nil) -- failed fetch keeps today's hijri; retry later
			else
				cb(tomorrow, tomorrow)
			end
		end)
	end)
end

-- --- patch assembly (time.ts computeSchedule + assignment patch shape) ---

-- omp display grammar: past/adhan dim ✓ (past = minutesUntil <= 0), next green
-- countdown, upcoming plain. Exactly one entry is in state "next" (computeSchedule
-- rewrites Fajr with +1440 minutes once all five are past → tomorrow's Fajr).
local function buildPatch(data: any, city: string, hijri: string, now: number): any
	local nowSec = math.floor(now / 1000)
	local nowMin = wallSeconds(now) / 60
	local wallSec = wallSeconds(now)

	local entries: any = {}
	for i = 1, #PRAYER_NAMES do
		entries[i] = { name = PRAYER_NAMES[i], wallMin = parseWallMin(data.prayers[PRAYER_NAMES[i]]) }
	end

	-- First prayer strictly in the future (floor(wallMin − nowMin) > 0).
	local nextIdx: number? = nil
	for i = 1, #entries do
		local e: any = entries[i]
		e.minutesUntil = math.floor(e.wallMin - nowMin)
		if e.minutesUntil > 0 and nextIdx == nil then
			nextIdx = i
		end
	end
	local allPast = nextIdx == nil

	local prayers: any = {}
	local nextPrayer: any = nil
	for i = 1, #entries do
		local e: any = entries[i]
		local mu = e.minutesUntil
		if allPast and i == 1 then
			mu += 1440 -- Fajr carries tomorrow's countdown; wall time stays today's
		end
		local state: string
		if mu <= 0 and mu > -10 then
			state = "adhan"
		elseif mu <= 0 then
			state = "past"
		elseif i == (if allPast then 1 else nextIdx) then
			state = "next"
		else
			state = "upcoming"
		end
		prayers[i] = { name = e.name, time = data.prayers[e.name], past = mu <= 0 }
		if state == "next" then
			-- Whole seconds until the prayer's wall minute; tomorrow's Fajr adds a day.
			local inSec = e.wallMin * 60 - wallSec
			if allPast and i == 1 then
				inSec += 86400
			end
			nextPrayer = { name = e.name, inSec = inSec }
		end
	end

	return {
		city = city,
		hijri = hijri,
		gregorian = format.formatGregorian(now),
		prayers = prayers,
		nextPrayer = nextPrayer,
		computedAtMs = now, -- inSec was computed against this instant; consumers subtract elapsed wall time
	}
end

-- Next interesting boundary: the next prayer's state flip lands inSec − 59 s
-- from now (minutesUntil hits 0 one minute before the wall time); midnight rolls
-- the cache-key date; an unresolved Maghrib rollover retries ≤ every 5 min.
local function nextDelay(patch: any, data: any, tomorrow: any, now: number): number
	local delay = MAX_WAIT_MS
	local np = patch.nextPrayer
	if type(np) == "table" and type(np.inSec) == "number" then
		delay = math.min(delay, math.max(1000, (np.inSec - 59) * 1000))
	end
	local nowSec = math.floor(now / 1000)
	local d = os.date("*t", nowSec)
	local nextMid = os.time({ year = d.year, month = d.month, day = d.day + 1, hour = 0, min = 0, sec = 0 })
	delay = math.min(delay, math.max(1000, (nextMid - nowSec) * 1000 + 1000))
	if wallMinutes(now) >= parseWallMin(data.prayers.Maghrib) and type(tomorrow) ~= "string" then
		delay = math.min(delay, math.max(1000, lastHijriAttempt + HIJRI_RETRY_MS - now))
	end
	return delay
end

-- --- cycle (source.ts refresh() port; cb-form fetch chains the phases) ---

local function continueCycle(
	finish: (any, string?, number?) -> (),
	cfg: any,
	city: string,
	country: string,
	force: boolean,
	cached: any,
	now: number,
	geo: any
)
	local key = city .. "|" .. country .. "|" .. cfg.method .. "|" .. localDateKey(now)

	-- Fresh cache for today's city-day: no prayer-time network at all.
	if not force and cached ~= nil and cached.key == key and (now - cached.fetchedAt) < DAY_MS then
		resolveHijri(cached.data, cached.tomorrowHijri, true, finish, function(hijri: string, tomorrow: string?)
			-- Persist the evening's gToH answer without resetting data freshness.
			if tomorrow ~= nil and tomorrow ~= cached.tomorrowHijri then
				writeCache({
					key = cached.key,
					fetchedAt = cached.fetchedAt,
					data = cached.data,
					geo = cached.geo,
					tomorrowHijri = tomorrow,
				})
			end
			local part = buildPatch(cached.data, city, hijri, now)
			finish(part, nil, nextDelay(part, cached.data, tomorrow, now))
		end)
		return
	end

	-- api.ts fetchPrayerTimes: timingsByCity?city=&country= [&method=] (auto omits).
	local url = ALADHAN_URL .. "?city=" .. enc(city) .. "&country=" .. enc(country)
	if cfg.method ~= "auto" then
		url = url .. "&method=" .. enc(cfg.method)
	end
	tern.fetch(url, { headers = { Accept = "application/json" }, timeout_ms = 5000 }, function(res: any)
		safePhase(finish, function()
			local data: any = nil
			if resOk(res) then
				data = parseTimings(res.body)
			end
			if data == nil then
				finish(nil, "deen timings unavailable", FAIL_WAIT_MS)
				return
			end
			-- A same-day refetch (force/refresh) may reuse today's already-resolved rollover.
			local prior: any = nil
			if cached ~= nil and cached.key == key then
				prior = cached.tomorrowHijri
			end
			resolveHijri(data, prior, true, finish, function(hijri: string, tomorrow: string?)
				local rec: any = { key = key, fetchedAt = now, data = data, tomorrowHijri = tomorrow }
				if geo ~= nil then
					rec.geo = geo
				elseif cached ~= nil and cached.geo ~= nil then
					rec.geo = cached.geo -- IP geo is city-agnostic; carry it (source.ts)
				end
				writeCache(rec) -- success-only cache write
				local part = buildPatch(data, city, hijri, now)
				finish(part, nil, nextDelay(part, data, tomorrow, now))
			end)
		end)
	end)
end

local function cycleBody(finish: (any, string?, number?) -> ())
	local now = nowMs()

	-- Manual refresh stamp consumed at cycle start.
	local req = bridge.readRefresh()
	local force = false
	if req ~= nil and req > lastHandledRefresh then
		force = true
		lastHandledRefresh = req
	end

	local city, country, method = readConfig()
	local cfg = { city = city, country = country, method = method }
	local cached = readCache()

	-- source.ts: config city wins; "auto" resolves via ipwho.is (7-day cache).
	if cfg.city == "auto" then
		if cached ~= nil and type(cached.geo) == "table" and (now - cached.geo.fetchedAt) < GEO_TTL_MS then
			continueCycle(finish, cfg, cached.geo.city, cached.geo.country, force, cached, now, nil)
		else
			fetchGeo(finish, function(geo: any?)
				if geo == nil then
					finish(nil, "deen geo unavailable", FAIL_WAIT_MS)
					return
				end
				continueCycle(finish, cfg, geo.city, geo.country, force, cached, now, geo)
			end)
		end
		return
	end

	continueCycle(finish, cfg, cfg.city, cfg.country, force, cached, now, nil)
end

-- One cycle = one on_part call, then the loop re-arms — on every path.
local function runCycle()
	if cycleActive then
		return
	end
	cycleActive = true
	local delivered = false
	local function finish(part: any, err: string?, delayMs: number?)
		if delivered then
			return
		end
		delivered = true
		cycleActive = false
		local cb = onPart
		if cb ~= nil then
			pcall(cb, part, err) -- a faulty consumer must not kill the loop
		end
		local delay = delayMs or FAIL_WAIT_MS
		if refreshPending() then -- manual refresh lands within ~2 s
			delay = REFRESH_WAIT_MS
		end
		if pending ~= nil then
			pending:cancel()
		end
		pending = tern.timer(math.max(1000, math.min(delay, MAX_WAIT_MS)), runCycle)
	end
	local ok, err = pcall(cycleBody, finish)
	if not ok and not delivered then
		finish(nil, "deen " .. tostring(err), FAIL_WAIT_MS)
	end
end

-- --- public API ---

function M.start(cb: (part: any, err: string?) -> ())
	if started then
		return
	end
	started = true
	onPart = cb
	tern.timer(100, runCycle)
end

function M.refresh()
	if not started or cycleActive then
		return
	end
	if pending ~= nil then
		pending:cancel()
		pending = nil
	end
	runCycle()
end

return M
