# repo-per-focused-pane — REPO money window follows the focused pane

Repo: `~/local-dev/getpipher/agent-statusline` (Tern plugin, host half `host.luau` + window half `window.luau`, shared `lib/*.luau`, no build step).

## Context

The statusline's `REPO` money pill is supposed to show all-time spend for the repo the user is working in, but today it shows the same number in every window: `resolveRepoName()` (lib/money.luau) resolves ONE global repo — basename of the first omp pane's cwd — at scan-pass end, and `rebuild()` bakes a single shared REPO slot/row used by every pane. The user wants REPO scoped to the focused pane: focus left pane (repo A) → repo A's $, focus right pane (repo B) → repo B's $. Agreed semantics: per-focused-pane lookup keyed by basename of the focused pane's cwd; known cwd with no session history shows `$0.00`; unknown/empty cwd falls back to the current global window; the Status Panel card and the omp-renderer package stay global.

## Approach

Behavior steps in dependency order. Steps 1–2 are independent of step 3's file but step 3 consumes both.

### 1. Scan emits the full per-repo ledger — `lib/money.luau` (host half)

In `completePass()` (patch table built ~line 512–526):

- Add a `byRepo` field to the `onPart` patch, transformed from the pass aggregate `a.byRepo` (entries are `{usd: number, tok: number}`): emit each entry as `{ usd = r.usd, tokens = r.tok }` — key renamed `tok` → `tokens` to match the existing window shape (`repo`/`day`/`d7`/`d30` windows all use `usd`/`tokens`). The map is keyed by repo basename and may be an empty table.
- Exact new patch shape field: `byRepo : { [basename]: { usd: number, tokens: number } }`.
- Update the header doc block "Patch shape (exactly):" (~line 14): add the `byRepo` line and one sentence: window.luau scopes the REPO segment per focused pane via this map; global `repo`/`repoName` remain the Status Panel window and the fallback.
- NOTHING else changes in this file: `resolveRepoName()`, the chunked scan, `startPass`, windows math, kv records all stay as-is. The global `repo`/`repoName` fields in the patch are kept (panel + fallback + renderer).

`host.luau` needs NO change: `mergeProvider` stores the whole patch as `snapshot.money`, `publish()` writes it to kv, and `seedMoney()` already returns the entire previous `money` table across reloads (its validation loop only checks the four window keys; `repoName`/`sub`/`entries` already ride along the same way) — so `byRepo` bridges reloads automatically.

### 2. Shared basename helper — `lib/format.luau`

- Add `function M.lastSegment(p: string): string?` — port of the module-private `lastSegment` in lib/money.luau (last non-empty `/` segment via `string.gmatch(p, "[^/]+")`; nil when no segment). Place it with the other pure helpers, matching file style.
- No equivalent export exists today: money.luau's copy is module-local and the window half cannot see it.
- Leave money.luau's private copy untouched (host half does not require format; no refactor mid-feature).

### 3. Per-pane REPO chrome — `window.luau` (window half)

**Split the money builders** (current `moneyRowsFrom` ~line 80 and `moneySlots` ~line 145 both iterate a spec list whose first entry is `{ lbl = "REPO", w = money.repo }`):

- `repoMoneySlot(w: any): any?` — builds the single REPO status slot from one window table: `{ icon = "stack", text = "REPO " .. fmtMoney(w.usd) .. tokensSuffix, tone = "ok", command = EXPAND }` where `tokensSuffix = " " .. format.fmtTokens(w.tokens)` when `w.tokens` is a number (same composition as today's slot). Return nil unless `w` is a table with numeric `usd`.
- `otherMoneySlots(m: any): { any }` — exact current `moneySlots` body minus the REPO spec entry (DAY/7DAY/30DAY only).
- `repoMoneyRow(w: any): any?` — the REPO widget row (`{ label = "REPO", text = fmtMoney(w.usd) .. tokensParens, tone = "ok" }`, same composition as today's row). Return nil unless valid.
- `otherMoneyRows(m: any): { any }` — exact current `moneyRowsFrom` body minus the REPO spec entry (DAY/7DAY/30DAY + the `sub` row stay here).
- Delete `moneySlots` and `moneyRowsFrom`; their only callers are updated in this step (`rebuild()` and nothing else — verified by grep).

**Add the pane-scoped window resolver** (module-local, near the other rebuild helpers):

```lua
-- REPO window for the focused pane: bucket keyed by basename(pane.cwd).
-- Known cwd, missing/invalid bucket → $0.00 (honest empty bucket). Unknown
-- cwd (nil/"") → global repo window; nil when that is missing too, so the
-- slot/row is omitted exactly like a missing window today.
local function repoWindowFor(money: any, pane: any): any?
	local global = if type(money) == "table" then money.repo else nil
	if pane ~= nil and type(pane.cwd) == "string" and pane.cwd ~= "" then
		local b = format.lastSegment(pane.cwd)
		if b ~= nil and type(money) == "table" and type(money.byRepo) == "table" then
			local r = money.byRepo[b]
			if type(r) == "table" and type(r.usd) == "number" then
				return { usd = r.usd, tokens = if type(r.tokens) == "number" then r.tokens else 0 }
			end
			return { usd = 0, tokens = 0 }
		end
	end
	return global
end
```

**Rebuild** (~line 247): replace `segMoneySlots = moneySlots(m)` with `segMoneyRest = otherMoneySlots(m)` and `widgetMoneyRows = moneyRowsFrom(m)` with `widgetMoneyRest = otherMoneyRows(m)`; rename the two module-local upvalue declarations (lines ~26–27) to match. No other references exist.

**Status formatter** (`tern.chrome.status(function(pane)` ~line 285): insert the per-pane REPO slot between the `segPrayer` candidate and the `segMoneyRest` loop:

```lua
local rs = repoMoneySlot(repoWindowFor(snapshot.money, pane))
if rs then
	candidates[#candidates + 1] = rs
end
```

Candidate order/count stays prayer · REPO · DAY · 7DAY · 30DAY · gated quotas, so the `rotIdx` rotation still visits REPO once per cycle. `snapshot` is the existing module upvalue; `snapshot.money` may be nil early — `repoWindowFor` handles it. Focus switches already re-render: existing `tern.on("focus")` handler calls `tern.chrome.refresh()`, and formatters are cached per input pane.

**Quota widget render** (`tern.chrome.widget "quota"`, ~line 303): replace the `for _, r in widgetMoneyRows do` loop with:

```lua
local rr = repoMoneyRow(repoWindowFor(snapshot.money, pane))
if rr then
	rows[#rows + 1] = rr
end
for _, r in widgetMoneyRest do
	rows[#rows + 1] = r
end
```

(The widget render's `pane` is the focused pane, nil when none — the resolver's fallback covers nil.)

**Comments to update in the same file** (they document the changed behavior): the file header block ("every money window (REPO/DAY/7DAY/30DAY)") — REPO is pane-scoped, the rest global; the `moneySlots` doc comment above the old function ("One status slot per money window that has data") moves onto the split builders with the pane-scoping note.

**Unchanged by design** (scope boundary): Status Panel card (`host.luau` `panelMoney` — global REPO + `repoName` header), widget digest (`widgetDigest`, uses `m.day`), `packages/omp-renderer` (its `AslMoney` interface consumes only the optional windows; the extra `byRepo` snapshot field is additive and invisible to it).

> **Follow-up (2026-11-22):** the `packages/omp-renderer` half of this boundary is now superseded. The renderer parses `snapshot.money.byRepo` and scopes its REPO segment by `basename(process.cwd())`, falling back to the global `money.repo` window. See `packages/omp-renderer/src/{read,render,index}.ts` and the regressions in `test/render.test.ts`. Do not restore "global-only" renderer behavior based on the scope above — the note in "Critical files & anchors" that the renderer is "NOT edited" was true for this plan's implementation only.

Wire shape after the change: `snapshot.money = { repo, repoName, day, d7, d30, sub, entries, byRepo }` — everything pre-existing identical, `byRepo` new.

## Critical files & anchors

- `lib/money.luau` — `completePass()` patch table (~line 512); header "Patch shape (exactly)" comment (~line 14).
- `window.luau` — builder functions (~lines 80, 145), upvalue decls (~26–27), `rebuild()` (~247), status formatter (~285), quota widget render (~303).
- `lib/format.luau` — new `M.lastSegment` export anywhere before `return M`.
- `packages/omp-renderer/` — NOT edited in this plan; later scoped to `byRepo` (see follow-up above).

## Verification

1. Renderer regression (proves the snapshot change is additive; no TS edits expected): from repo root, `cd packages/omp-renderer && pnpm test:run && pnpm typecheck` — both green. This is the only automated suite in the repo (node:test via tsx; no Luau test infra exists).
2. Live per-pane proof (prereq: Tern running this plugin; plugin halves are plain `.luau` files with no build step — reload via Tern's plugin mechanism or restart Tern; reload command unverified — confirm first):
   - Palette › **Debug** copies the snapshot: pasted JSON must show `"byRepo"` under `money`, keyed by repo basenames with `{usd, tokens}` entries.
   - Prereq for the next check: two omp sessions in two different repos that both have session history under `~/.omp/agent/sessions` (e.g. this repo + any other). Focus pane A → within one rotation cycle (≤25 s, 5 s ticks) the status segment reads `REPO $<A's all-time>`; focus pane B → `REPO $<B's all-time>`. The quota widget's REPO row shows the focused pane's bucket likewise.
   - DAY / 7DAY / 30DAY pills must be identical in both panes (global windows unchanged).

## Assumptions & contingencies

- Bucket latency: `byRepo` updates only when a scan pass completes (minutes on large trees) — a brand-new session's spend appears then; same latency every money window already has. Do not add faster refresh paths.
- If Tern has no hot reload: restarting Tern is the accepted fallback (no build artifact to rebuild).
- If `pnpm test:run` fails on untouched renderer tests: the failure predates this change — report it, do not fix renderer code inside this change.
