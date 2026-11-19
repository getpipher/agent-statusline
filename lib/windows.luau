--!strict
-- Quota window math ported from omp-statusline src/quota/project.ts.
-- All timestamps are JS-style milliseconds since the epoch, like the TS sources;
-- UTC arithmetic is pure epoch math (no os.time on UTC fields).
local M = {}

local FIVE_HOUR_MS = 5 * 3600000
local WEEK_MS = 7 * 24 * 3600000
M.FIVE_HOUR_MS = FIVE_HOUR_MS
M.WEEK_MS = WEEK_MS

-- Days between 1970-01-01 and the given UTC civil date (Hinnant's days_from_civil).
local function daysFromCivil(y: number, m: number, d: number): number
	local yy = y
	if m <= 2 then
		yy -= 1
	end
	local era = math.floor((if yy >= 0 then yy else yy - 399) / 400)
	local yoe = yy - era * 400 -- [0, 399]
	local doy = math.floor((153 * (if m > 2 then m - 3 else m + 9) + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

local function daysInUtcMonth(y: number, m: number): number
	return daysFromCivil(if m == 12 then y + 1 else y, if m == 12 then 1 else m + 1, 1) - daysFromCivil(y, m, 1)
end

-- Window-clock percent for the quota row's usage%/elapsed% segment. Clamped 0–100
-- (stale nextResetTime → 100, not-yet-started → 0); Math.round half-up on positives.
function M.windowElapsedPercent(nextResetTime: number, lengthMs: number, now: number): number
	local elapsed = (now - (nextResetTime - lengthMs)) / lengthMs
	if elapsed ~= elapsed or elapsed == math.huge or elapsed == -math.huge then
		return 0
	end
	local clamped = math.min(1, math.max(0, elapsed))
	return math.floor(clamped * 100 + 0.5)
end

-- OpenCode Go monthly meter: window starts on the same UTC day-of-month in the
-- previous month, clamped to that month's last day (Mar 31 → Feb 28/29; Jan → prev year).
-- Luau timestamps are second-resolution, so the sub-second part of the TS port is dropped.
function M.previousMonthStartUtc(ts: number): number
	local d = os.date("!*t", math.floor(ts / 1000))
	local prevMonth = if d.month == 1 then 12 else d.month - 1
	local prevYear = if d.month == 1 then d.year - 1 else d.year
	local lastDay = daysInUtcMonth(prevYear, prevMonth)
	local day = math.min(d.day, lastDay)
	local secs = d.hour * 3600 + d.min * 60 + d.sec
	return daysFromCivil(prevYear, prevMonth, day) * 86400000 + secs * 1000
end

function M.monthlyWindowMs(nextResetTime: number): number
	return nextResetTime - M.previousMonthStartUtc(nextResetTime)
end

-- Positive = burning faster than the clock (over), negative = under.
function M.paceSeconds(windowMs: number, usagePct: number, elapsedPct: number): number
	return windowMs * (usagePct - elapsedPct) / 100
end

-- Exact omp paceText (index.ts v0.3.0): minute-ROUNDED gap; "3h 12m" spacing;
-- day-scale drops stray minutes ("1d 6h"); over/under purely by sign.
function M.paceText(windowMs: number, usagePct: number, elapsedPct: number): string
	local gapMs = windowMs * (usagePct - elapsedPct) / 100
	local m = math.floor(math.abs(gapMs) / 60000 + 0.5)
	local d = math.floor(m / 1440)
	local h = math.floor((m % 1440) / 60)
	local mm = m % 60
	local t: string
	if d > 0 then
		t = d .. "d " .. h .. "h"
	elseif h > 0 then
		t = h .. "h " .. mm .. "m"
	else
		t = mm .. "m"
	end
	return t .. (if gapMs > 0 then " over" else " under")
end

-- Heat bands (plan + omp index.ts heat): usage <70 accent, >=70 warn, >=90 error;
-- pace-over escalates to warn (>=90 stays error).
function M.heat(usagePct: number, paceOver: boolean): string
	if usagePct >= 90 then
		return "error"
	elseif usagePct >= 70 then
		return "warn"
	elseif paceOver then
		return "warn"
	end
	return "accent"
end

return M
