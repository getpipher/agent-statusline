--!strict
-- Pure formatting helpers ported from omp-statusline src/format.ts and src/index.ts.
-- All timestamps are JS-style milliseconds since the epoch, like the TS sources.
local M = {}

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local function pad2(n: number): string
	return string.format("%02d", n)
end

-- Dashboard-style compact credits (index.ts compactK): 7664 → "7.7K", 28000 → "28K",
-- 140000 → "140K". Math.round is half-up on positives; floor(x + 0.5) matches here.
function M.compactK(v: number): string
	if v < 1000 then
		return tostring(math.floor(v + 0.5))
	end
	local k = v / 1000
	local s: string
	if k < 100 then
		s = string.format("%.1f", k)
	else
		s = tostring(math.floor(k + 0.5))
	end
	if s:sub(-2) == ".0" then
		s = s:sub(1, -3)
	end
	return s .. "K"
end

-- Token volumes per window (index.ts fmtTokens): one decimal for K/M/B.
function M.fmtTokens(t: number): string
	if t >= 1e9 then
		return string.format("%.1f", t / 1e9) .. "B"
	elseif t >= 1e6 then
		return string.format("%.1f", t / 1e6) .. "M"
	elseif t >= 1e3 then
		return string.format("%.1f", t / 1e3) .. "K"
	end
	return tostring(math.floor(t + 0.5))
end

function M.formatMoney(n: number): string
	return string.format("%.2f", n)
end

function M.formatClock(ts: number): string
	return os.date("%H:%M", ts / 1000) :: string
end

-- "3h12m" (no space) — compact pace durations.
function M.formatSpan(ms: number): string
	local totalMinutes = math.floor(ms / 60000)
	local hours = math.floor(totalMinutes / 60)
	if hours <= 0 then
		return totalMinutes .. "m"
	end
	return hours .. "h" .. (totalMinutes % 60) .. "m"
end

-- Countdown ("3h 57m", "6d 6h") — unit spaces beyond a day.
function M.formatReset(targetMs: number, now: number): string
	local remaining = targetMs - now
	if remaining <= 0 then
		return "now"
	end
	local hours = math.floor(remaining / 3600000)
	local minutes = math.floor((remaining % 3600000) / 60000)
	if hours > 24 then
		return math.floor(hours / 24) .. "d " .. (hours % 24) .. "h"
	end
	return hours .. "h " .. minutes .. "m"
end

-- Absolute reset wall-clock: same local calendar day reads as clock time,
-- otherwise "Sat Sep 12 04:09". Machine-local like formatClock.
function M.formatResetAbs(targetMs: number, now: number): string
	if targetMs <= now then
		return "now"
	end
	local t = os.date("*t", targetMs / 1000)
	local n = os.date("*t", now / 1000)
	if t.year == n.year and t.month == n.month and t.day == n.day then
		return M.formatClock(targetMs)
	end
	return WEEKDAYS[t.wday] .. " " .. MONTHS[t.month] .. " " .. pad2(t.day) .. " " .. M.formatClock(targetMs)
end

-- Gregorian gloss beside the Hijri date: "09 Sep 2026".
function M.formatGregorian(ts: number): string
	local d = os.date("*t", ts / 1000)
	return pad2(d.day) .. " " .. MONTHS[d.month] .. " " .. d.year
end

function M.formatWeekday(ts: number): string
	local d = os.date("*t", ts / 1000)
	return WEEKDAYS[d.wday]
end

return M
