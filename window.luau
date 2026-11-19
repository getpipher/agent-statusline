--!strict
-- Agent Statusline — window half.
-- ZERO-WORK chrome formatters (4 ms budget): the status bar and the quota
-- widget are COMPOSED FROM PREBUILT UPVALUES per focused pane — no tern.kv,
-- no agents:list inside a formatter. A 5 s tern.timer watches tern.kv
-- "asl/snapshot".seq, refreshes chrome on every tick, and rotates the status
-- bar one notch per tick (5 s cadence) through prayer · every money window
-- (REPO/DAY/7DAY/30DAY) · every quota window of the pane's providers.
-- Provider gating via cx.agents:list() runs ONLY in timer/event callbacks
-- (60 s tick + focus/agent_state/window_start); the gate maps
-- AgentBlock.model per pane, and a pane with no recognized agent shows all
-- key-bearing providers.
local format = require("./lib/format")
local windows = require("./lib/windows")

type AslWindow = { label: string, usagePct: number, elapsedPct: number, paceOverSec: number, resetMs: number }

-- ── prebuilt chrome pieces (written by timer callbacks, read by formatters)
local segPrayer: any? = nil
local segMoneySlots: { any } = tern.json.array({})
local segZaiSlots: { any } = tern.json.array({})
local segOpenSlots: { any } = tern.json.array({})
local widgetMoneyRows: { any } = tern.json.array({})
local widgetZaiRows: { any } = tern.json.array({})
local widgetOpenRows: { any } = tern.json.array({})
local widgetPrayerRow: any? = nil
local widgetZaiBar: any? = nil -- { value, text }
local widgetOpenBar: any? = nil
local widgetDigest: string? = nil
local snapshot: any = nil
-- pane id → provider gate ("zai" | "opencode"); missing = show all key-bearing
local providerByPane: { [number]: string } = {}

-- Which candidate the status bar shows: advanced one notch per 5 s watcher
-- tick; the formatter indexes candidates[(rotIdx % #candidates) + 1].
local rotIdx = 0

local EXPAND = "plugin.agent-statusline.expand"

local function epochMs(): number
	return os.time() * 1000
end

-- Window length for a stored quota window (shared helper in lib/windows).
local function windowLen(w: AslWindow): number
	return windows.lenFor(w)
end

local function fmtMoney(usd: number): string
	return "$" .. format.formatMoney(usd)
end

-- ── gating (timer/event callbacks only) ─────────────────────────────────
local function gateFromAgents(cx: any)
	local ok, agents = pcall(function()
		return cx.agents:list()
	end)
	if not ok or type(agents) ~= "table" then
		return
	end
	local map: { [number]: string } = {}
	for _, a in agents do
		if type(a) == "table" and type(a.pane) == "number" and type(a.model) == "string" then
			local m = (a.model :: string):lower()
			if m:find("zai", 1, true) ~= nil or m:find("glm", 1, true) ~= nil then
				map[a.pane] = "zai"
			elseif m:find("opencode", 1, true) ~= nil then
				map[a.pane] = "opencode"
			end
		end
	end
	providerByPane = map
end

local function gateAllowed(paneId: number?, provider: string): boolean
	local gate = if paneId ~= nil then providerByPane[paneId] else nil
	return gate == nil or gate == provider
end

-- ── rebuild (timer callbacks only) ──────────────────────────────────────
local function moneyRowsFrom(money: any): { any }
	local rows: { any } = tern.json.array({})
	if type(money) ~= "table" then
		return rows
	end
	local spec: { any } = {
		{ lbl = "REPO", w = money.repo },
		{ lbl = "DAY", w = money.day },
		{ lbl = "7DAY", w = money.d7 },
		{ lbl = "30DAY", w = money.d30 },
	}
	for _, r in spec do
		if type(r.w) == "table" and type(r.w.usd) == "number" then
			rows[#rows + 1] = {
				label = r.lbl,
				text = fmtMoney(r.w.usd)
					.. (if type(r.w.tokens) == "number" then " (" .. format.fmtTokens(r.w.tokens) .. ")" else ""),
				tone = "ok",
			}
		end
	end
	if type(money.sub) == "number" then
		rows[#rows + 1] = { label = "sub", text = fmtMoney(money.sub), tone = "muted" }
	end
	return rows
end

local function windowRowsFrom(providerLabel: string, data: any, now: number): { any }
	local rows: { any } = tern.json.array({})
	if type(data) ~= "table" or type(data.windows) ~= "table" then
		return rows
	end
	for _, w in data.windows do
		if type(w) == "table" and type(w.usagePct) == "number" then
			local len = windowLen(w)
			rows[#rows + 1] = {
				label = providerLabel .. " " .. w.label,
				text = math.floor(w.usagePct + 0.5) .. "%/" .. math.floor((w.elapsedPct or 0) + 0.5) .. "%"
					.. " ("
					.. windows.paceText(len, w.usagePct, w.elapsedPct or 0)
					.. " · "
					.. format.formatReset(w.resetMs, now)
					.. " · "
					.. format.formatResetAbs(w.resetMs, now)
					.. ")",
				tone = windows.heat(w.usagePct, (w.paceOverSec or 0) > 0),
			}
		end
	end
	return rows
end

local function barFrom(data: any): any?
	if type(data) ~= "table" or type(data.windows) ~= "table" then
		return nil
	end
	local w = data.windows[1]
	if type(w) ~= "table" or type(w.usagePct) ~= "number" then
		return nil
	end
	return {
		value = math.max(0, math.min(1, w.usagePct / 100)),
		text = w.label .. " " .. math.floor(w.usagePct + 0.5) .. "%",
	}
end

-- One status slot per money window that has data — REPO/DAY/7DAY/30DAY
-- rotate individually. Widget-bar pills ellipsize past ~21 chars, so tokens
-- render bare (no parens) and labels stay full.
local function moneySlots(m: any): { any }
	local slots: { any } = tern.json.array({})
	if type(m) ~= "table" then
		return slots
	end
	local spec: { any } = {
		{ lbl = "REPO", w = m.repo },
		{ lbl = "DAY", w = m.day },
		{ lbl = "7DAY", w = m.d7 },
		{ lbl = "30DAY", w = m.d30 },
	}
	for _, r in spec do
		if type(r.w) == "table" and type(r.w.usd) == "number" then
			local tokens = if type(r.w.tokens) == "number" then " " .. format.fmtTokens(r.w.tokens) else ""
			slots[#slots + 1] = {
				icon = "stack",
				text = r.lbl .. " " .. fmtMoney(r.w.usd) .. tokens,
				tone = "ok",
				command = EXPAND,
			}
		end
	end
	return slots
end

-- `3h 22m over` → `3h over`; `30m under` stays one unit; `0m under` (on
-- pace) → "". Keeps quota pills inside the ~21-char ellipsis cap. Lua
-- patterns have no alternation, so the direction word is matched separately.
local function compactPace(pace: string): string
	local dir = pace:match(" (under)$") or pace:match(" (over)$")
	local major = if dir ~= nil then pace:match("^(%S+) %S+ ") else nil
	if dir ~= nil and major ~= nil then
		return major .. " " .. dir
	end
	if pace:match("^0m ") then
		return ""
	end
	return pace
end

-- `3h 42m` → `3h`; `13m` stays. One duration unit keeps prayer pills ≤ cap.
local function compactDur(dur: string): string
	return (dur:match("^%S+")) or dur
end

-- One status slot per quota window of a provider — 5hrs/7DAY(/MONTH) rotate
-- individually with their own pace + heat tone. Space separator (not ` · `)
-- and the `oc` provider alias keep the longest pill at the 21-char cap.
local function quotaSlots(providerLabel: string, data: any): { any }
	local slots: { any } = tern.json.array({})
	if type(data) ~= "table" or type(data.windows) ~= "table" then
		return slots
	end
	for _, w in data.windows do
		if type(w) == "table" and type(w.usagePct) == "number" then
			local len = windowLen(w)
			local pace = compactPace(windows.paceText(len, w.usagePct, w.elapsedPct or 0))
			slots[#slots + 1] = {
				icon = "gauge",
				text = providerLabel .. " " .. w.label .. " " .. math.floor(w.usagePct + 0.5) .. "%"
					.. (if pace ~= "" then " " .. pace else ""),
				tone = windows.heat(w.usagePct, (w.paceOverSec or 0) > 0),
				command = EXPAND,
			}
		end
	end
	return slots
end

local function rebuild()
	local now = epochMs()
	if snapshot == nil then
		return
	end
	local d = snapshot.deen
	local m = snapshot.money

	segPrayer = nil
	if type(d) == "table" and type(d.nextPrayer) == "table" then
		local np = d.nextPrayer
		local timeStr = ""
		if type(d.prayers) == "table" then
			for _, p in d.prayers do
				if p.name == np.name then
					timeStr = p.time
					break
				end
			end
		end
		local remainingSec = math.max(0, (np.inSec or 0) - math.floor((now - (snapshot.updatedMs or now)) / 1000))
		segPrayer = {
			icon = "clock",
			text = np.name
				.. (if timeStr ~= "" then " " .. timeStr else "")
				.. " ("
				.. compactDur(format.formatReset(now + remainingSec * 1000, now))
				.. ")",
			tone = "ok",
			command = EXPAND,
		}
		widgetPrayerRow = {
			label = "next",
			text = np.name .. " (" .. format.formatReset(now + remainingSec * 1000, now) .. ")",
			tone = "ok",
		}
	else
		widgetPrayerRow = nil
	end

	segMoneySlots = moneySlots(m)
	widgetMoneyRows = moneyRowsFrom(m)

	segZaiSlots = quotaSlots("zai", snapshot.zai)
	segOpenSlots = quotaSlots("oc", snapshot.opencode)
	widgetZaiRows = windowRowsFrom("zai", snapshot.zai, now)
	widgetOpenRows = windowRowsFrom("opencode", snapshot.opencode, now)
	widgetZaiBar = barFrom(snapshot.zai)
	widgetOpenBar = barFrom(snapshot.opencode)

	local digest: { string } = {}
	if type(m) == "table" and type(m.day) == "table" and type(m.day.usd) == "number" then
		digest[#digest + 1] = "DAY " .. fmtMoney(m.day.usd)
	end
	if widgetPrayerRow then
		digest[#digest + 1] = (widgetPrayerRow :: any).text
	end
	widgetDigest = if #digest > 0 then table.concat(digest, " · ") else nil
end

-- ── formatters: compose per focused pane from upvalues (4 ms budget) ────
-- ONE segment: candidates in fixed order (prayer · every money window ·
-- every quota window of the pane's providers), showing the rotIdx-th —
-- a 5 s rotating bar, one slot at a time, so nothing truncates.
tern.chrome.status(function(pane)
	local pid = if pane ~= nil then pane.pane else nil
	local candidates: { any } = {}
	if segPrayer then
		candidates[#candidates + 1] = segPrayer
	end
	for _, s in segMoneySlots do
		candidates[#candidates + 1] = s
	end
	if gateAllowed(pid, "zai") then
		for _, s in segZaiSlots do
			candidates[#candidates + 1] = s
		end
	end
	if gateAllowed(pid, "opencode") then
		for _, s in segOpenSlots do
			candidates[#candidates + 1] = s
		end
	end
	if #candidates == 0 then
		return nil
	end
	return { candidates[(rotIdx % #candidates) + 1] }
end)

tern.chrome.widget("quota", {
	name = "Agent quota meter",
	description = "Rolling quota window usage, money windows and next prayer.",
	icon = "gauge",
	styles = { "bar", "text" },
	render = function(pane)
		local pid = if pane ~= nil then pane.pane else nil
		local bar = nil
		if gateAllowed(pid, "zai") and widgetZaiBar then
			bar = widgetZaiBar
		elseif gateAllowed(pid, "opencode") and widgetOpenBar then
			bar = widgetOpenBar
		end
		local rows: { any } = tern.json.array({})
		for _, r in widgetMoneyRows do
			rows[#rows + 1] = r
		end
		if gateAllowed(pid, "zai") then
			for _, r in widgetZaiRows do
				rows[#rows + 1] = r
			end
		end
		if gateAllowed(pid, "opencode") then
			for _, r in widgetOpenRows do
				rows[#rows + 1] = r
			end
		end
		if widgetPrayerRow then
			rows[#rows + 1] = widgetPrayerRow
		end
		rows[#rows + 1] = {
			id = "refresh",
			text = "Force quota/deen/money polls",
			tone = "muted",
			actions = tern.json.array({ { id = "refresh", label = "Refresh" } }),
		}
		return {
			text = if bar then bar.text else "no quota data",
			tone = if bar then windows.heat(bar.value * 100, false) else "muted",
			title = widgetDigest,
			value = if bar then bar.value else nil,
			card = rows,
		}
	end,
})

-- Refresh button on the widget's hover card (this half offers the widget, so
-- widget_action lands here). Truthy return consumes the click.
tern.on("widget_action", function(ev, _cx)
	if type(ev) == "table" and ev.widget == "quota" and ev.act == "refresh" then
		pcall(tern.kv.set, "asl/refresh-request", epochMs())
		return true
	end
	return false
end)

-- ── palette commands ─────────────────────────────────────────────────────
tern.command({
	id = "expand",
	title = "Status Panel",
	keys = { "ctrl+shift+s" },
	run = function(cx)
		-- Block kind is the bare "<plugin>.<block>" form (SDK examples:
		-- longrun.slow, jsonx.explorer); the literal "plugin." prefix belongs to
		-- command ACTIONS only (plugin.<id>.<cmd>). nil here means the host half
		-- isn't loaded on this host (longrun's phrasing) — surface it.
		if cx:new_block("agent-statusline.panel", {}, "over") == nil then
			cx:toast("error", "Status Panel unavailable", "The agent-statusline host half isn't loaded on this host.")
		end
	end,
})

tern.command({
	id = "refresh",
	title = "Refresh",
	run = function(cx)
		pcall(tern.kv.set, "asl/refresh-request", epochMs())
		cx:toast("info", "Refresh requested")
	end,
})

tern.command({
	id = "set-keys",
	title = "Set Keys",
	run = function(cx)
		cx:prompt({ placeholder = "z.ai API key" }):next(function(zaiKey, _err1, cx1)
			if type(zaiKey) ~= "string" or zaiKey == "" then
				cx1:toast("info", "Cancelled — z.ai key unchanged")
				return
			end
			cx1:prompt({ placeholder = "OpenCode Go key (empty to skip)" }):next(function(ocKey, _err2, cx2)
				local keys: any = {}
				local okK, existing = pcall(tern.kv.get, "asl/keys")
				if okK and type(existing) == "table" then
					keys = existing
				end
				keys.zai = zaiKey
				if type(ocKey) == "string" and ocKey ~= "" then
					keys.opencode = ocKey
				end
				tern.kv.set("asl/keys", keys)
				pcall(tern.kv.set, "asl/refresh-request", epochMs())
				cx2:toast("success", "Keys stored — quota polls forced")
			end)
		end)
	end,
})

tern.command({
	id = "config",
	title = "Config",
	run = function(cx)
		cx:prompt({ placeholder = "key (city, country, method, escalateMinutes, zaiPollMs, opencodePollMs)" }):next(function(key, _e1, cx1)
			if type(key) ~= "string" or key == "" then
				return
			end
			cx1:prompt({ placeholder = "value for " .. key }):next(function(value, _e2, cx2)
				if type(value) ~= "string" or value == "" then
					return
				end
				local cfg: any = {}
				local okC, existing = pcall(tern.kv.get, "asl/config")
				if okC and type(existing) == "table" then
					cfg = existing
				end
				if key == "escalateMinutes" or key == "zaiPollMs" or key == "opencodePollMs" then
					cfg[key] = tonumber(value)
					if cfg[key] == nil then
						cx2:toast("error", key .. " needs a number")
						return
					end
				else
					cfg[key] = value
				end
				tern.kv.set("asl/config", cfg)
				pcall(tern.kv.set, "asl/refresh-request", epochMs())
				cx2:toast("success", key .. " = " .. value)
			end)
		end)
	end,
})

tern.command({
	id = "debug",
	title = "Debug",
	run = function(cx)
		local ok, snap = pcall(tern.kv.get, "asl/snapshot")
		local agents: { any } = tern.json.array({})
		local okA, list = pcall(function()
			return cx.agents:list()
		end)
		if okA and type(list) == "table" then
			for _, a in list do
				if type(a) == "table" then
					agents[#agents + 1] = { pane = a.pane, model = a.model, state = a.state }
				end
			end
		end
		local payload = tern.json.encode({
			snapshot = if ok then snap else nil,
			agents = agents,
		}, true)
		cx:copy(payload)
		cx:toast("success", "Snapshot copied (" .. #payload .. " bytes)")
	end,
})

-- ── watcher + gating timers (timer callbacks: roomy budgets) ────────────
local function watcher(_cx: any?)
	local ok, s = pcall(tern.kv.get, "asl/snapshot")
	if ok and type(s) == "table" then
		snapshot = s
		rebuild()
	end
	-- Rotate one notch per tick and re-render unconditionally: the bar shows
	-- its next candidate every 5 s even when no snapshot data moved.
	rotIdx += 1
	tern.chrome.refresh()
	tern.timer(5000, watcher)
end

local function gateTick(cx: any?)
	if cx ~= nil then
		gateFromAgents(cx)
	end
	tern.timer(60000, gateTick)
end

-- Re-gate on the events that change which agent is focused/relevant.
tern.on("window_start", function(cx)
	gateFromAgents(cx)
	tern.chrome.refresh()
end)
tern.on("focus", function(_ev, cx)
	gateFromAgents(cx)
	tern.chrome.refresh()
end)
tern.on("agent_state", function(_ev, cx)
	gateFromAgents(cx)
	tern.chrome.refresh()
end)

-- Reload replaces the VM; timers die with it. Nothing to stop, nothing to
-- save — pollers own no persistent children. Documented no-op by design.
tern.on("unload", function(_cx) end)

watcher(nil)
gateTick(nil)
