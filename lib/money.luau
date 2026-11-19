--!strict
-- money.luau — omp sessions disk-scan ledger, ported from omp-statusline src/money.ts (source of truth).
-- The sessions tree is a superset of the retired pi ledger: covers subagent spend
-- (<repo-slug>/<session-dir>/<Agent>.jsonl), advisor consults (<session-dir>/__advisor.jsonl and
-- per-agent <session-dir>/<Agent>/__advisor.jsonl), and every file embeds its cwd in the
-- {"type":"session"} line for repo attribution. Windows: repo = all-time for the current repo
-- (basename of the first omp pane's cwd, any pane's cwd as fallback); DAY = since local midnight;
-- 7DAY/30DAY = rolling, hour-aligned (hourFloor(now) − N×24h — RECTOR semantics). Entry ids are
-- uuid7; branched/resumed session copies share ids, so entries dedupe on the bare id (fresh set
-- per pass, exactly like money.ts's per-scan Set) and a re-persisted message is never counted twice.
--
-- Public API:
--   M.start(on_part)  start the self-re-arming chunk loop; on_part(patch, nil) fires ONCE per
--                     completed pass (patch shape below); a cycle that fails outright calls
--                     on_part(nil, reason) once instead. Intermediate chunks are silent.
--   M.refresh()       force one immediate chunk (supersedes the pending tick; the loop stays
--                     single-chain via a generation counter — never multiplies timers).
--
-- Patch shape (exactly):
--   { repo = {usd, tokens}, repoName = string?, day = {usd, tokens}, d7 = {usd, tokens},
--     d30 = {usd, tokens}, sub = number, entries = int }
-- When repoName resolves to nil (no panes / no cwd), repo carries ALL-TIME totals and the
-- renderer decides display (assignment override of money.ts, where an unknown current repo
-- simply leaves repo at 0).
--
-- Chunking: tern.timer(2000) cadence; each chunk processes up to 600 file parses or 1.2 s of
-- wall (tern.now diff), whichever first, then resumes exactly where it stopped (per-directory
-- candidate cursors + per-file line cursors live in the module-local pass state). On pass
-- completion the module writes per-file records to kv "asl/scan" as
-- {[absPath] = {bytes, cost, tokens, entries, lastSeenMs}} and emits the patch.
--
-- Deviations from money.ts, forced by the tern runtime (behavior otherwise identical):
--   • No stat API: asl/scan's bytes = #bytes read and lastSeenMs = os.time()*1000 (wall clock
--     is second-resolution, so window boundaries can differ from Date.now() by under a second).
--   • File-vs-directory classification uses an fs.list probe (tern.fs has no withFileTypes);
--     list raises on non-directories, and unreadable entries are skipped — the same net effect
--     as money.ts's try/catch around readFileSync/readdirSync.
--   • Date.parse is ported as an ISO-8601 subset parser (omp writes toISOString "…Z"; also
--     accepts ±HH:MM / ±HHMM offsets, date-only as UTC and no-zone date-time as LOCAL, all per
--     the ES rules money.ts inherits).
--   • Dedup set scope: fresh per pass (equals money.ts's fresh Set per scanMoney call) and
--     global across files within the pass; a VM reload loses it and the pass restarts cold,
--     which is correct per plan.
local M = {}

local HOUR_MS = 3600000
local DAY_MS = 86400000
local CHUNK_MS = 2000 -- timer cadence between chunks
local CHUNK_WALL_MS = 1200 -- per-chunk wall cap
-- Caps sized so the wall budget binds, not the counts: the live sessions tree
-- measured 37.8k files / 6.3 GB, and a 40-file cap fixed the pass at ~31 min
-- (20 files/s) while each 1.2 s of Lua absorbs hundreds of small JSONL files.
local CHUNK_FILES = 600 -- per-chunk file-parse cap
local CHUNK_LISTS = 600 -- per-chunk directory listing/probe cap (wall cap governs too)
-- tern.fs.read max_bytes: the host Luau VM caps each VM at 256 MiB and this
-- tree OOMed it — both on the largest file (91 MB JSONL) and cumulatively
-- during the walk (tern.runtime docs: "Each VM may allocate at most 256 MiB";
-- `collectgarbage` forces other than "count" are removed, so GC cannot be
-- forced from Lua). Oversize/failed reads skip like any unreadable file
-- (money.ts readFileSync catch). Live impact at 16 MiB: 9 of 37.8k files
-- skipped, all long-retired sessions — rolling windows stay exact; only
-- all-time REPO for those repos is understated.
local MAX_FILE_BYTES = 16 * 1024 * 1024

-- Directory-mode transitions mirror money.ts's three fixed levels: sessions tree holds
-- <repoSlug>/<ts-id>.jsonl (main), <repoSlug>/<session-dir>/*.jsonl (subagent <Agent>.jsonl and
-- main __advisor.jsonl) and <repoSlug>/<session-dir>/<Agent>/__advisor.jsonl (per-agent advisor).
-- omp writes nothing deeper (money.ts, verified 2026-10-12), so agent-level directories are ignored.
local CHILD_MODE = { root = "repo", repo = "session", session = "agent" }
-- money.ts: main session files scan with sub=false; every artifact file (subagent or advisor)
-- scans with sub=true; stray files at the root level are skipped (readdirSync on them throws).
local FILE_SUB = { repo = false, session = true, agent = true }

local seen = {} -- entry-id → true; fresh per pass (money.ts: fresh Set per scanMoney call)
local onPart = nil -- (patch, nil) | (nil, reason); set by M.start
local started = false
local gen = 0 -- schedule-chain generation; guards M.refresh against timer multiplication
local pass = nil -- active pass state (dirs/files cursors, entries, per-file records) or nil

-- Hinnant's days_from_civil, same convention as lib/windows.luau (pure epoch math, no local
-- calendar dependency). Kept module-local because windows.luau does not export it.
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

-- Wall-clock epoch ms. os.time() is integer seconds, so resolution is 1 s (documented deviation
-- from Date.now(); entry timestamps are ISO strings and window boundaries move by under a second).
local function wallMs(): number
	return math.floor(os.time()) * 1000
end

local function isFinite(v: number): boolean
	return v == v and v < math.huge and v > -math.huge
end

-- Last non-empty "/" segment, money.ts's cwd.split("/").filter(Boolean).pop(); nil for roots.
local function lastSegment(p: string): string?
	local last = nil
	for seg in string.gmatch(p, "[^/]+") do
		last = seg
	end
	return last
end

local function endsWith(s: string, suffix: string): boolean
	return string.sub(s, #s - #suffix + 1) == suffix
end

-- ES Date.parse subset (see header). Returns epoch ms or nil for anything it would have been NaN.
local function parseIso(s: string): number?
	if #s < 10 then
		return nil
	end
	local y = tonumber(string.sub(s, 1, 4))
	local mo = tonumber(string.sub(s, 6, 7))
	local d = tonumber(string.sub(s, 9, 10))
	if y == nil or mo == nil or d == nil then
		return nil
	end
	if string.sub(s, 5, 5) ~= "-" or string.sub(s, 8, 8) ~= "-" then
		return nil
	end
	if mo < 1 or mo > 12 or d < 1 or d > 31 then
		return nil
	end
	if #s == 10 then
		return daysFromCivil(y, mo, d) * 86400000 -- ES: date-only forms are UTC midnight
	end
	local sep = string.sub(s, 11, 11)
	if sep ~= "T" and sep ~= "t" and sep ~= " " then
		return nil
	end
	local timePart = string.sub(s, 12)
	local hh = tonumber(string.sub(timePart, 1, 2))
	local mi = tonumber(string.sub(timePart, 4, 5))
	if hh == nil or mi == nil or string.sub(timePart, 3, 3) ~= ":" then
		return nil
	end
	if hh > 23 or mi > 59 then
		return nil
	end
	-- "hh:mm" consumed 5 chars; position 6 is ":" when seconds follow, otherwise the zone starts there
	local rest
	local se = 0
	if string.sub(timePart, 6, 6) == ":" then
		local secStr = string.match(string.sub(timePart, 7), "^(%d%d)")
		if secStr == nil then
			return nil
		end
		se = tonumber(secStr)
		if se > 60 then
			return nil
		end
		rest = string.sub(timePart, 9)
	else
		rest = string.sub(timePart, 6)
	end
	local ms = 0
	local frac = string.match(rest, "^%.(%d+)")
	if frac ~= nil then
		ms = tonumber((frac .. "000"):sub(1, 3))
		rest = string.sub(rest, #frac + 2)
	end
	local offsetMs = 0
	if rest == "Z" or rest == "z" then
		-- UTC, fall through to the pure epoch sum
	elseif rest == "" then
		-- ES: date-time without offset is LOCAL time
		local t = os.time({ year = y, month = mo, day = d, hour = hh, min = mi, sec = se })
		return t * 1000 + ms
	else
		-- Offset zone: `?` is a valid 0-or-1 quantifier in Lua/Luau patterns, so one match
		-- covers ±HH:MM and ±HHMM; trailing junk after the offset rejects via the empty-tail check.
		local sign, oh, om, tail = string.match(rest, "^([+-])(%d%d):?(%d%d?)(.*)$")
		if sign == nil or oh == nil or om == nil or tail ~= "" then
			return nil
		end
		offsetMs = (tonumber(oh) * 60 + tonumber(om)) * 60000
		if sign == "-" then
			offsetMs = -offsetMs
		end
	end
	return daysFromCivil(y, mo, d) * 86400000 + (hh * 3600 + mi * 60 + se) * 1000 + ms - offsetMs
end

-- repoName for the patch: basename of the cwd of the first pane whose program contains "omp"
-- (plain substring, like RECTOR's omp panes), falling back to any pane's cwd basename; nil when
-- nothing resolves. Never returns "unknown" — entry-side unknown repos just won't match it.
local function resolveRepoName(): string?
	local ok, panes = pcall(tern.pane.list)
	if ok and type(panes) == "table" then
		for i = 1, #panes do
			local p = panes[i]
			if type(p) == "table" and type(p.program) == "string" and string.find(p.program, "omp", 1, true) ~= nil
				and type(p.cwd) == "string" and p.cwd ~= "" then
				local b = lastSegment(p.cwd)
				if b ~= nil then
					return b
				end
			end
		end
		for i = 1, #panes do
			local p = panes[i]
			if type(p) == "table" and type(p.cwd) == "string" and p.cwd ~= "" then
				local b = lastSegment(p.cwd)
				if b ~= nil then
					return b
				end
			end
		end
	end
	return nil
end

-- One JSONL line, money.ts parseSessionFile body: session lines set the file-local repo,
-- assistant messages with finite usage.cost.total contribute (id, ts, cost, tokens) once.
local function parseLine(line: string, f)
	if string.sub(line, -1) == "\r" then
		line = string.sub(line, 1, -2) -- JSON.parse tolerates trailing \r whitespace; strip for strict decoders
	end
	if line == "" then
		return
	end
	local ok, e = pcall(tern.json.decode, line)
	if not ok or type(e) ~= "table" then
		return -- malformed line (torn tail of a live writer): skip
	end
	local etype = e.type
	if etype == "session" then
		local cwd = e.cwd
		if type(cwd) == "string" then
			local b = lastSegment(cwd)
			if b ~= nil then
				f.repo = b
			end
		end
		return
	end
	if etype ~= "message" then
		return
	end
	local id = e.id
	if type(id) ~= "string" then
		return
	end
	local m = e.message
	if type(m) ~= "table" then
		return
	end
	if m.role ~= "assistant" then
		return
	end
	local u = m.usage
	if type(u) ~= "table" then
		return
	end
	local c = u.cost
	if type(c) ~= "table" then
		return
	end
	local total = c.total
	if type(total) ~= "number" or not isFinite(total) then
		return
	end
	if seen[id] then
		return
	end
	seen[id] = true
	-- Token volume: usage.totalTokens when positive/finite, else the sum of the finite
	-- components (money.ts's parts.reduce fallback for legacy entries).
	local tok: number
	local raw = u.totalTokens
	if type(raw) == "number" and isFinite(raw) and raw > 0 then
		tok = raw
	else
		tok = 0
		for _, k in ipairs({ "input", "output", "cacheRead", "cacheWrite" }) do
			local v = u[k]
			if type(v) == "number" and isFinite(v) then
				tok += v
			end
		end
	end
	-- money.ts: missing/unparseable timestamp scans as 0, which no money window covers
	-- (but the repo window has no ts check, so it still counts there).
	local ts = 0
	local stamp = e.timestamp
	if type(stamp) == "string" then
		local parsed = parseIso(stamp)
		if parsed ~= nil then
			ts = parsed
		end
	end
	f.cost += total
	f.tok += tok
	f.entries += 1
	f.lastSeenMs = wallMs()
	-- Streaming window aggregation (pass-boundary windows, computed once in
	-- startPass): no per-entry table — 300k entries exceeded the 256 MiB VM cap
	-- under GC pressure. Totals are order- and window-identical to money.ts's
	-- post-scan fold (window membership of an entry is independent of scan end).
	local a = pass.agg
	a.entries += 1
	a.repoUsd += total
	a.repoTok += tok
	local r = a.byRepo[f.repo]
	if r == nil then
		r = { usd = 0, tok = 0 }
		a.byRepo[f.repo] = r
	end
	r.usd += total
	r.tok += tok
	if ts >= pass.midnightMs then
		a.dayUsd += total
		a.dayTok += tok
	end
	if ts >= pass.weekStart then
		a.weekUsd += total
		a.weekTok += tok
	end
	if ts >= pass.monthStart then
		a.monthUsd += total
		a.monthTok += tok
		if f.sub then
			a.subUsd += total
		end
	end
end

-- Parse a file's lines up to the wall cap, then record it and advance the file cursor.
-- Files too big for one chunk resume at f.pos on a later chunk.
local function parseLines(f, t0: number)
	local content = f.content
	local n = #content
	while f.pos <= n do
		if tern.now() - t0 >= CHUNK_WALL_MS then
			return
		end
		local nl = string.find(content, "\n", f.pos, true)
		local line
		if nl == nil then
			line = string.sub(content, f.pos)
			f.pos = n + 1
		else
			line = string.sub(content, f.pos, nl - 1)
			f.pos = nl + 1
		end
		if line ~= "" then
			-- A line whose decode spikes past the 256 MiB VM cap must not reset the
			-- whole pass (pos already advanced): pcall drops it like money.ts drops
			-- unparseable lines.
			pcall(parseLine, line, f)
		end
	end
	-- File fully scanned → per-file record for kv asl/scan (bytes because tern.fs has no stat).
	pass.scan[f.path] = { bytes = f.bytes, cost = f.cost, tokens = f.tok, entries = f.entries, lastSeenMs = wallMs() }
	f.content = nil -- release the raw text: retaining every file until pass end OOMs the host VM on large trees
	pass.fi += 1
end

-- Classify one directory-entry name (fs.list probe: success = directory, raise = file) and
-- enqueue per the mode table. Non-.jsonl files and ignored-level directories drop out here,
-- exactly where money.ts's withFileTypes checks drop them.
local function visit(t, name: string)
	local childPath = t.path .. "/" .. name
	local ok, inner = pcall(tern.fs.list, childPath)
	if ok and type(inner) == "table" then
		local childMode = CHILD_MODE[t.mode]
		if childMode ~= nil then
			-- DFS: children wait on the stack (lazy-listed on pop). The previous
			-- insert-at-cursor scheme drifted with the driver index and
			-- re-enqueued dirs ~4x (16,280 enqueues for a 4,133-dir tree); a
			-- stack structurally cannot revisit. Live set stays O(path depth).
			pass.stack[#pass.stack + 1] = { path = childPath, mode = childMode, names = nil, ni = 1 }
		end
		return
	end
	if type(inner) == "string" and string.find(inner, "enough memory", 1, true) ~= nil then
		-- Allocation failed inside fs.list: NOT a file. Misclassifying it as one
		-- would silently drain the walk to a zero pass (seen live). Pause the
		-- chunk; the idle gap lets GC settle and the next chunk retries.
		pass.oom = true
		return
	end
	if not endsWith(name, ".jsonl") then
		return
	end
	local sub = FILE_SUB[t.mode]
	if sub == nil then
		return
	end
	pass.files[#pass.files + 1] = {
		path = childPath,
		sub = sub,
		content = nil,
		pos = 0,
		bytes = 0,
		repo = "unknown",
		cost = 0,
		tok = 0,
		entries = 0,
		lastSeenMs = 0,
	}
end

local function startPass()
	seen = {} -- fresh dedup set per pass, like money.ts's fresh Set per scanMoney call
	local home = tern.getenv("HOME")
	if home == nil or home == "" then
		local ok, h = pcall(os.getenv, "HOME")
		if ok and type(h) == "string" and h ~= "" then
			home = h
		end
	end
	if home == nil or home == "" then
		error("no HOME environment variable for the sessions scan")
	end
	-- Window boundaries frozen at pass start (money.ts computes them at scan
	-- end; the pass-duration delta is minutes on window edges — immaterial).
	local startMs = wallMs()
	local sd = os.date("*t", math.floor(startMs / 1000))
	local midnightMs = os.time({ year = sd.year, month = sd.month, day = sd.day, hour = 0, min = 0, sec = 0 }) * 1000
	local hourFloor = startMs - (startMs % HOUR_MS)
	pass = {
		stack = { { path = home .. "/.omp/agent/sessions", mode = "root", names = nil, ni = 1 } },
		files = {},
		fi = 1,
		scan = {},
		midnightMs = midnightMs,
		weekStart = hourFloor - 7 * DAY_MS,
		monthStart = hourFloor - 30 * DAY_MS,
		agg = {
			repoUsd = 0,
			repoTok = 0,
			byRepo = {},
			entries = 0,
			dayUsd = 0,
			dayTok = 0,
			weekUsd = 0,
			weekTok = 0,
			monthUsd = 0,
			monthTok = 0,
			subUsd = 0,
		},
	}
end

local function completePass()
	local repoName = resolveRepoName()
	local a = pass.agg
	-- Assignment override of money.ts: nil repoName (no pane cwd) → repo carries all-time.
	local repoUsd, repoTok = a.repoUsd, a.repoTok
	if repoName ~= nil then
		local r = a.byRepo[repoName]
		repoUsd = if r then r.usd else 0
		repoTok = if r then r.tok else 0
	end
	pcall(tern.kv.set, "asl/scan", pass.scan)
	if onPart ~= nil then
		pcall(onPart, {
			repo = { usd = repoUsd, tokens = repoTok },
			repoName = repoName,
			day = { usd = a.dayUsd, tokens = a.dayTok },
			d7 = { usd = a.weekUsd, tokens = a.weekTok },
			d30 = { usd = a.monthUsd, tokens = a.monthTok },
			sub = a.subUsd,
			entries = a.entries,
		}, nil)
	end
	pass = nil
end

-- One chunk: discovery (cheap fs.list probes) interleaved with parsing (fs.read + JSONL decode),
-- capped by wall clock, file parses and listings; always resumes at the exact cursors.
local function runChunk()
	if pass == nil then
		startPass()
	end
	pass.oom = false -- each chunk gets one retry budget; the walk pauses where memory ran out
	local t0 = tern.now()
	local filesStarted = 0
	local lists = 0
	while true do
		if pass.oom or tern.now() - t0 >= CHUNK_WALL_MS then
			return
		end
		local t = pass.stack[#pass.stack]
		if t ~= nil then
			if t.names == nil then
				if lists >= CHUNK_LISTS then
					return
				end
				lists += 1
				local ok, res = pcall(tern.fs.list, t.path)
				if ok and type(res) == "table" then
					t.names = res
					t.ni = 1
				else
					if type(res) == "string" and string.find(res, "enough memory", 1, true) ~= nil then
						pass.oom = true -- allocation failure inside the listing: retry this dir next chunk
						return
					end
					table.remove(pass.stack) -- failed listing (missing root, transient): skipped
				end
			else
				local name = t.names[t.ni]
				if name == nil then
					table.remove(pass.stack) -- directory done
				else
					t.ni += 1
					visit(t, name) -- child dirs push onto the stack: depth-first, exactly once
				end
			end
		else
			local f = pass.files[pass.fi]
			if f == nil then
				if #pass.stack == 0 then
					completePass()
				end
				return
			end
			if f.content == nil then
				if filesStarted >= CHUNK_FILES then
					return
				end
				filesStarted += 1
				local ok, raw = pcall(tern.fs.read, f.path, MAX_FILE_BYTES)
				if not ok or type(raw) ~= "string" then
					if type(raw) == "string" and string.find(raw, "enough memory", 1, true) ~= nil then
						pass.oom = true -- allocation failure: retry this file next chunk
						return
					end
					pass.fi += 1 -- money.ts readFileSync catch → skip silently
				else
					f.content = raw
					f.bytes = #raw
					f.pos = 1
				end
			else
				parseLines(f, t0)
			end
		end
	end
end

-- Self-re-arming chunk loop. All paths re-arm (the loop must never die); pcall keeps failures
-- from raising out of the timer body. One pending timer at all times via the generation guard.
local function schedule(ms: number)
	gen += 1
	local myGen = gen
	tern.timer(ms, function(_cx)
		if myGen ~= gen then
			return -- superseded by a newer schedule (M.refresh); that chain owns the loop
		end
		local ok, err = pcall(runChunk)
		if not ok then
			-- Unexpected crash mid-pass: drop partial state, report once, keep the loop alive.
			pass = nil
			seen = {}
			if onPart ~= nil then
				pcall(onPart, nil, "money scan failed: " .. tostring(err))
			end
		end
		schedule(CHUNK_MS)
	end)
end

-- Starts the loop; idempotent (a second start must not multiply the timer chain).
function M.start(cb: (part: any, err: string?) -> ())
	if started then
		return
	end
	started = true
	onPart = cb
	schedule(0) -- cold pass begins at once
end

-- Forces one immediate chunk (supersedes the pending tick); the normal loop resumes after.
function M.refresh()
	if not started then
		return
	end
	schedule(0)
end

return M
