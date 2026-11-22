--!strict
-- Agent Statusline — host half.
-- All data work lives in lib/*.luau pollers (quota zai/opencode, deen,
-- money). This entry starts them and assembles their patches into ONE
-- snapshot written to tern.kv "asl/snapshot" (seq-bumped on every accepted
-- patch; last-good data kept on provider failure; errors.* records why).
-- The panel block ("plugin.agent-statusline.panel") is defined here in the
-- panel phase; the manifest's [[blocks]] table lands with it.
local zai = require("./lib/quota_zai")
local opencode = require("./lib/quota_opencode")
local deen = require("./lib/deen")
local money = require("./lib/money")
local format = require("./lib/format")
local windows = require("./lib/windows")

local seq = 0
local snapshot: any = nil

-- Wall-clock epoch ms (os.time, NOT tern.now — that one is monotonic).
local function epochMs(): number
	return os.time() * 1000
end

-- Merge one provider patch into the snapshot and publish. patch nil = the
-- provider failed this cycle: keep last good data, record the error.
local function publish()
	seq += 1
	snapshot.seq = seq
	snapshot.updatedMs = epochMs()
	pcall(tern.kv.set, "asl/snapshot", snapshot)
end

local function mergeProvider(name: string, patch: any, err: string?)
	if snapshot == nil then
		return
	end
	if patch ~= nil then
		snapshot[name] = patch
		snapshot.errors[name] = nil
	else
		-- keep last good values; only the error marker moves
		snapshot.errors[name] = err
	end
	publish()
end

-- Reload/restart bridge (issue #1): the money scanner's first pass takes
-- minutes on large session trees; carry the persisted aggregate forward so
-- money pills/cards survive the gap. Age-guarded — stale totals are dropped
-- rather than shown as truth. The first completed pass overwrites the seed.
local MONEY_SEED_MAX_AGE_MS = 6 * 60 * 60 * 1000

local function seedMoney(): any
	local ok, prev = pcall(tern.kv.get, "asl/snapshot")
	if not ok or type(prev) ~= "table" or type(prev.money) ~= "table" then
		return nil
	end
	local m = prev.money
	for _, key in { "repo", "day", "d7", "d30" } do
		local w = m[key]
		if w ~= nil and (type(w) ~= "table" or type(w.usd) ~= "number") then
			return nil -- malformed persisted shape; don't trust it
		end
	end
	local updated = prev.updatedMs
	if type(updated) ~= "number" or epochMs() - updated > MONEY_SEED_MAX_AGE_MS then
		return nil
	end
	return m
end

snapshot = {
	seq = 0,
	updatedMs = epochMs(),
	money = seedMoney(), -- last-good bridge; the first scan pass overwrites it
	zai = nil,
	opencode = nil,
	deen = nil,
	errors = { zai = nil, opencode = nil, deen = nil, money = nil },
}
publish()

zai.start(function(part, err)
	mergeProvider("zai", part, err)
end)
opencode.start(function(part, err)
	mergeProvider("opencode", part, err)
end)
deen.start(function(part, err)
	mergeProvider("deen", part, err)
end)
money.start(function(part, err)
	mergeProvider("money", part, err)
end)

-- Honor manual refresh requests (window "Refresh" widget button / command):
-- a stamp newer than the last handled one forces an immediate cycle on every
-- poller. deen also watches the stamp itself; forcing it here is idempotent.
local lastRefreshHandled = 0
local function pollRefreshRequest()
	local ok, v = pcall(tern.kv.get, "asl/refresh-request")
	if ok and type(v) == "number" and v > lastRefreshHandled then
		lastRefreshHandled = v
		zai.refresh()
		opencode.refresh()
		deen.refresh()
		money.refresh()
	end
end
local function refreshLoop()
	pcall(pollRefreshRequest)
	tern.timer(10000, refreshLoop)
end
refreshLoop()

-- ── panel block (plugin.agent-statusline.panel) ─────────────────────────
-- Freshness = at render (open/focus): view reads tern.kv fresh every call.
-- The compact surfaces (segments + widget) are the live ones.
local PLUGIN_VERSION = "0.2.3" -- keep in sync with plugin.toml
local ternVersion: string? = nil

-- Probe the tern version once for the footer; omit the segment when the
-- runtime doesn't expose TERN_EXE (never a placeholder).
do
	local exe = tern.getenv("TERN_EXE")
	if type(exe) == "string" and exe ~= "" then
		tern.process.run({ exe, "--version" }, { timeout_ms = 3000 }, function(result, _cx)
			if result.status == 0 and type(result.stdout) == "string" then
				ternVersion = (result.stdout :: string):gsub("%s+$", "")
			end
		end)
	end
end

local ui = tern.ui

local function panelInfoHeader(snap: any, now: number): any
	local spans: { any } = { ui.span(format.formatWeekday(now) .. " " .. format.formatClock(now), "strong") }
	local d = snap.deen
	if type(d) == "table" and type(d.hijri) == "string" then
		spans[#spans + 1] = " · "
		spans[#spans + 1] = ui.span(d.hijri, "")
		if type(d.gregorian) == "string" then
			spans[#spans + 1] = ui.span(" (" .. d.gregorian .. ")", "dim")
		end
	end
	if type(d) == "table" and type(d.city) == "string" then
		spans[#spans + 1] = ui.span(" · " .. d.city, "muted")
	end
	return ui.text(spans)
end

local function panelPrayers(snap: any, now: number): any
	local d = snap.deen
	if type(d) ~= "table" or type(d.prayers) ~= "table" then
		return nil
	end
	local items: { any } = {}
	for _, p in d.prayers do
		if type(p) ~= "table" or type(p.name) ~= "string" or type(p.time) ~= "string" then
			return nil
		end
		local value: any
		if p.past == true then
			value = { ui.span(p.time, "dim"), ui.span(" ✓", "dim") }
		elseif type(d.nextPrayer) == "table" and d.nextPrayer.name == p.name then
			local remainingSec = math.max(0, (d.nextPrayer.inSec or 0) - math.floor((now - (snap.updatedMs or now)) / 1000))
			value = { ui.span(p.time, "success"), ui.span(" (" .. format.formatReset(now + remainingSec * 1000, now) .. ")", "success") }
		else
			value = { ui.span(p.time, "") }
		end
		items[#items + 1] = { { ui.span(p.name, if p.past == true then "dim" else "") }, value }
	end
	return ui.card({ ui.span("Prayers", "strong") }, { ui.kv(items) })
end

local function panelMoney(snap: any): any
	local m = snap.money
	if type(m) ~= "table" then
		return nil
	end
	local items: { any } = {}
	local spec: { any } = {
		{ lbl = "REPO", w = m.repo },
		{ lbl = "DAY", w = m.day },
		{ lbl = "7DAY", w = m.d7 },
		{ lbl = "30DAY", w = m.d30 },
	}
	for _, r in spec do
		if type(r.w) == "table" and type(r.w.usd) == "number" then
			local value: { any } = { ui.span("$" .. format.formatMoney(r.w.usd), "success") }
			if type(r.w.tokens) == "number" then
				value[#value + 1] = ui.span(" (" .. format.fmtTokens(r.w.tokens) .. ")", "dim")
			end
			items[#items + 1] = { { ui.span(r.lbl, "") }, value }
		end
	end
	if type(m.sub) == "number" then
		items[#items + 1] = { { ui.span("sub", "muted") }, { ui.span("$" .. format.formatMoney(m.sub), "muted") } }
	end
	if type(m.entries) == "number" then
		items[#items + 1] = { { ui.span("entries", "muted") }, { ui.span(tostring(m.entries), "muted") } }
	end
	if #items == 0 then
		return nil
	end
	local head: { any } = { ui.span("Money", "strong") }
	if type(m.repoName) == "string" then
		head[#head + 1] = ui.span(" · " .. m.repoName, "muted")
	end
	return ui.card(head, { ui.kv(items) })
end

local function panelWindows(snap: any, now: number): any?
	local cols: { any } = tern.json.array({
		{ id = "win", head = "Window" },
		{ id = "usage", head = "Usage" },
		{ id = "pace", head = "Pace" },
		{ id = "resets", head = "Resets" },
	})
	local rows: { any } = tern.json.array({})
	local providers: { any } = { { "zai", snap.zai }, { "opencode", snap.opencode } }
	for _, pr in providers do
		local label, data = pr[1], pr[2]
		if type(data) == "table" and type(data.windows) == "table" then
			for _, w in data.windows do
				if type(w) == "table" and type(w.usagePct) == "number" then
					local len = windows.lenFor(w)
					local pace = windows.paceText(len, w.usagePct, w.elapsedPct or 0)
					local paceTone = if (w.paceOverSec or 0) > 0 then "warning" else "success"
					rows[#rows + 1] = {
						{ ui.span(label .. " " .. w.label, "mono") },
						ui.meter_cell(math.max(0, math.min(1, w.usagePct / 100)), { 0.7, 0.9 }),
						{ ui.span(if pace ~= "" then pace else "—", paceTone) },
						{ ui.span(format.formatResetAbs(w.resetMs, now), "dim") },
					}
				end
			end
		end
	end
	if #rows == 0 then
		return nil
	end
	return ui.card({ ui.span("Quota windows", "strong") }, { ui.table(cols, rows) })
end

local panelDef = {
	init = function(_cx, _args, _saved)
		return {}
	end,
	view = function(_state, _cx)
		local now = os.time() * 1000
		local ok, snap = pcall(tern.kv.get, "asl/snapshot")
		if not ok or type(snap) ~= "table" then
			return { main = ui.col({ ui.text({ ui.span("waiting for first snapshot…", "muted") }) }) }
		end
		local parts: { any } = { panelInfoHeader(snap, now) }
		local prayers = panelPrayers(snap, now)
		if prayers then
			parts[#parts + 1] = prayers
		end
		local moneyCard = panelMoney(snap)
		if moneyCard then
			parts[#parts + 1] = moneyCard
		end
		local winCard = panelWindows(snap, now)
		if winCard then
			parts[#parts + 1] = winCard
		end
		local footer = "asl " .. PLUGIN_VERSION
		if ternVersion then
			footer = footer .. " · tern " .. (ternVersion :: string)
		end
		parts[#parts + 1] = ui.text({ ui.span(footer, "dim") })
		return { main = ui.col(parts) }
	end,
	title = function(_state)
		return "Status Panel"
	end,
}

tern.block.define("panel", panelDef)
