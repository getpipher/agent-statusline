# Agent statusline — finish the pane plan and the open issues

## Context

Implement the remaining work from the repo-per-focused-pane plan and all four open GitHub issues (`#8`, `#5`, `#3`, `#2`) in `~/local-dev/getpipher/agent-statusline`. Discovery showed the pane-scoped REPO feature (`bf6d43f`) and the money-scan hardening for `#2`/`#3` (`fbdf304`) are already shipped in `main`; do not reimplement them. The real code work is issue `#8` (window→host `asl/config` and `asl/refresh-request` writes never land, so Config/Refresh are silent no-ops) and issue `#5` (Debug copies only the snapshot, so per-pane chrome needs screenshots). Intended end state: every documented Config key has a live consumer, Refresh actually forces host polls, Debug emits per-focused-pane chrome text, and the stale issues are closed after verification.

## Approach

### Step 1 — Confirm shipped work; no code edits

Verify in the current tree (read-only checks) and record as the reason for closing `#2`/`#3` later:

- `lib/money.luau:469-512` — empty-pass early return precedes `asl/scan` writes and patch emission; `lib/money.luau:548-558` aborts a failed root listing with throttled `asl/pass` telemetry (`#3`).
- `lib/money.luau:606-616` — `schedule()` re-arms the next tick before `pcall(runChunk)` behind the generation guard (`#2`).
- `lib/money.luau:20-25,326-330,500-512`, `lib/format.luau:99-111`, `window.luau:102-211,336-337,366-369,403-406` — `byRepo` ledger, `lastSegment`, split builders, resolver and both chrome insertions from the pane plan are intact.
- If any of these are missing, stop and restore them from `git show bf6d43f` / `git show fbdf304` before continuing; do not redesign.

### Step 2 — Add the verified file-backed command channel (`lib/bridge.luau`, new)

No equivalent exists: `lib/keys.luau` is secrets-only and stays unchanged. Create `lib/bridge.luau` with exactly four exported functions:

- `function M.storeConfig(cfg: any): boolean` — `pcall(tern.kv.set, "asl/config", cfg)` best-effort first; then ALWAYS write `<tern.plugin.data>/config.json` via `pcall(tern.fs.write, path, tern.json.encode(cfg))`; read back with `pcall(tern.fs.read, path, 16384)`, `pcall(tern.json.decode, raw)`, require a table, compare every member of `cfg`; return `true` only when all comparisons pass, `false` on any failure. Never raise.
- `function M.readConfig(): any` — return a table always: valid `config.json` first (same bounded read/decode), else a valid `asl/config` kv table via `pcall`, else `{}`. File wins over kv deliberately: it is the read-back-verified channel; a stale kv value must not mask a newer file value.
- `function M.requestRefresh(): boolean` — module-local `lastStamp = 0`; compute `stamp = math.max(os.time() * 1000, lastStamp + 1)`, assign `lastStamp = stamp` (prevents two clicks in the same second from producing an ignored equal stamp). Best-effort `pcall(tern.kv.set, "asl/refresh-request", stamp)`, then ALWAYS write `<tern.plugin.data>/refresh.json` as `{ requestMs = stamp }` with the same write/read/decode/compare verification; return boolean.
- `function M.readRefresh(): number?` — read both `refresh.json` (`requestMs`, finite number) and kv `asl/refresh-request` (finite number), return the maximum valid value, else `nil`. Missing/corrupt file or kv must never raise.

Resolve the data dir with the `lib/keys.luau:21-29` pattern: `pcall(function() return tern.plugin.data end)`, non-empty string check, `data .. "/<name>.json"`, else `""` → all file operations skipped and `false`/`nil`/`{}` returned. `tern.fs` is synchronous per `tern.d.luau:2314-2332`; every native call still goes through `pcall`. Preserve the existing Config prompt semantics: arbitrary extra keys remain allowed; only `escalateMinutes`, `zaiPollMs`, `opencodePollMs` are coerced with `tonumber`, with the current "needs a number" error.

### Step 3 — Wire config consumers, including `escalateMinutes`

- `window.luau`: add `local bridge = require("./lib/bridge")` near the existing requires at `:14-16`. In the Config command (`:540-571`), read existing values with `bridge.readConfig()` instead of `pcall(tern.kv.get, "asl/config")`, replace the bare `tern.kv.set("asl/config", cfg)` at `:566` with `local landed = bridge.storeConfig(cfg)`, keep `bridge.requestRefresh()`, and gate the toast at `:568` on `landed` (success text unchanged, error text `"Config storage failed — no channel landed"`).
- `lib/quota_zai.luau:26-35` and `lib/quota_opencode.luau:28-39`: add the require; replace the `pcall(tern.kv.get, "asl/config")` in `pollMs()` with `bridge.readConfig()`; keep the existing finite-number check, floor, `30000` floor and `180000` default verbatim.
- `lib/deen.luau`: add the require; in `readConfig()` (`:267-282`) replace the kv read with `bridge.readConfig()` and keep the non-empty-string checks and `"Jakarta"`/`"Indonesia"`/`"auto"` defaults.
- `host.luau`: add the require; in `publish()` (`:26-31`) set `snapshot.config` on every publish from `bridge.readConfig().escalateMinutes` only when it is a finite number `> 0`, otherwise set it to `nil`; keep `seq`/`updatedMs`/kv write unchanged. This is the only path by which the Config key reaches the omp renderer.
- `packages/omp-renderer/src/read.ts`: add `config?: { escalateMinutes?: number }` to `AslSnapshot`; in `parseSnapshot()` (`:168-191`) parse `s.config.escalateMinutes` with the existing `num()` helper, accept only finite `> 0`, assign `snap.config` only when valid. Unknown/malformed config degrades to absent, never throws.
- `packages/omp-renderer/src/render.ts`: replace the comment at `:111-113` that claims the snapshot carries no config; in `renderRows()` (`:193-199`) compute `const escalateMinutes = snap.config?.escalateMinutes ?? env.escalateMinutes;` and pass that to `prayerLine()`. Keep `RenderEnv.escalateMinutes` as the fallback for direct API callers and tests.
- `packages/omp-renderer/test/render.test.ts`: add two cases beside the existing escalation case (`:189-200`): (1) `parseSnapshot` of a snapshot with `config.escalateMinutes = 12` returns `12`, and `"x"` returns undefined; (2) a `soon` snapshot with `config.escalateMinutes = 12` and no `env.escalateMinutes` renders Asr (13m left) with the success color, while default 30 renders it warning. No new fixture file.

### Step 4 — Make Refresh actually reach the host (issue #8, remaining half)

- `window.luau`: replace all five `pcall(tern.kv.set, "asl/refresh-request", epochMs())` calls at `:443,469,498,530,567` with `bridge.requestRefresh()`. Keep the keys toasts at `:497-504,529-535` gated on `keysStore.store()` as today. In the Refresh command (`:466-472`) gate the toast on the boolean: success `"Refresh requested"`, error `"Refresh request failed — no channel landed"`. In `tern.on("widget_action", …)` (`:441-447`) rename `_cx` to `cx`, show the same error toast on failure, and still `return true` so the click is consumed.
- `host.luau:pollRefreshRequest()` (`:100-109`): use `bridge.readRefresh()` as the stamp, keep `lastRefreshHandled` and the strict `v > lastRefreshHandled` gate and the four `.refresh()` calls. Leave `lastRefreshHandled = 0` at startup: one harmless forced cycle after a plugin reload is preferable to swallowing a request written just before it.
- `lib/deen.luau`: in `refreshPending()` (`:284-288`) and `cycleBody()` (`:533-538`) use `bridge.readRefresh()`, keeping `lastHandledRefresh`, `force`, and the existing `REFRESH_WAIT_MS` cap at `:581-583`.

### Step 5 — Debug chrome digest (issue #5)

- `window.luau`: insert three pure helpers immediately after `rebuild()` ends (`:354`), before `tern.chrome.status`:
  - `local function statusCandidates(pane: any?): { any }` — the current status formatter body at `:361-380` verbatim (prayer · REPO · DAY/7DAY/30DAY · gated quotas); returns the candidate array.
  - `local function quotaWidgetRows(pane: any?): { any }` — the current widget rows body at `:402-428` verbatim (REPO · DAY/7DAY/30DAY/sub · gated quotas · prayer · refresh row); returns the rows array.
  - `local function quotaWidgetBar(pane: any?): any?` — mirror the current zai-then-opencode gate at `:397-401`: return `widgetZaiBar` when `gateAllowed(pid, "zai")` and it exists, else `widgetOpenBar` when `gateAllowed(pid, "opencode")` and it exists, else `nil`. Do not read `widgetZaiBar.text` unconditionally; that misreports opencode-gated panes.
  These helpers read only upvalues and existing pure functions; no kv, no `agents:list`, no toasts, no `rotIdx` mutation.
- Rewire consumers without changing rendered output: `tern.chrome.status` (`window.luau:360-387`) calls `statusCandidates(pane)`, keeps the `#candidates == 0` guard and the exact `candidates[(rotIdx % #candidates) + 1]` selection; the quota widget `render` (`:394-437`) uses `quotaWidgetBar(pane)` for `bar` and `quotaWidgetRows(pane)` for `rows`, keeping the returned `text`/`tone`/`title`/`value` block unchanged.
- Extend the Debug command (`window.luau:574-597`): resolve the focused pane with `pcall(function() return cx.session:focused() end)` then `pcall(function() return cx.session:pane(id) end)` (`tern.d.luau:1922-1940,2046-2104`; `cx:copy` already used at `:594`). If `focused()` raises/returns nil, fall back to `cx.session:panes()` and take the entry with `focused == true`; if still none, pass `nil` to the helpers and encode `focusedPane`/`cwd` as `tern.json.null`. `gateAllowed(nil, …)` is true and `repoWindowFor(..., nil)` uses the global window, so nil panes cannot crash.
- Add `chrome` to the copied payload alongside unchanged `snapshot` and `agents`, using `tern.json.array({})` for arrays:
  `focusedPane` (number or null), `cwd` (string or null), `candidates` (`s.text` for every candidate), `showing` (the current rotated candidate's text, or null), `widget = { text = <bar.text or "no quota data">, title = widgetDigest, rows = <(label .. " " or "") .. text for every row> }`. Update the toast to `"Snapshot + chrome copied (" .. #payload .. " bytes)"`. Keep the Debug payload clipboard-only; do not alter the `asl/snapshot` wire shape.

### Step 6 — Verify and close the issues

Run the automated suite from the repo root after Step 3 and again at the end:

```sh
pnpm -C packages/omp-renderer test:run
pnpm -C packages/omp-renderer typecheck
```

Live verification (Tern running this plugin; reload with `tern plugin reload agent-statusline` — no build step):

1. `#8` Config: palette Config → `city=Bandung`, `zaiPollMs=45000`, `escalateMinutes=12`; `jq . "$HOME/Library/Application Support/Tern/plugin-data/agent-statusline/config.json"` must show those exact values. Palette Refresh → `jq .requestMs "$HOME/Library/Application Support/Tern/plugin-data/agent-statusline/refresh.json"` must be a number greater than before; within 10 s `jq '.["asl/snapshot"].seq' <data>/kv.json` must advance, and within two poll cycles `jq '.["asl/snapshot"].config.escalateMinutes, .["asl/snapshot"].deen.city' <data>/kv.json` must show `12` and `Bandung`. Click the widget's Refresh row once and confirm `requestMs` increments again. A missing `asl/config`/`asl/refresh-request` key in `kv.json` is expected and harmless.
2. `#5`: palette Debug, then `pbpaste | jq '.chrome'`; expect the focused pane id/cwd, `candidates` containing a `REPO $…` entry, and `widget.rows` containing a `REPO $…` entry. Focus a second pane in a different repo with session history and repeat: REPO text changes, DAY/7DAY/30DAY texts stay identical, `widget.text` matches that pane's provider gate (including `"no quota data"` when no bar).
3. `#2`/`#3` and the pane plan: `jq '.["asl/snapshot"].seq' <data>/kv.json` twice ≥30 s apart must increase (scan chain alive); `jq '.["asl/scan"] | length' <data>/kv.json` must not drop to zero; `pbpaste | jq '.snapshot.money.byRepo'` (from Debug) must show repo basenames with `{usd, tokens}`.

Close only after the matching checks pass:

```sh
gh issue close 8 --repo getpipher/agent-statusline --comment "Verified: config.json/refresh.json verified file rung; Config values and forced Refresh reach the host."
gh issue close 5 --repo getpipher/agent-statusline --comment "Verified: Debug now copies per-focused-pane status candidates and widget rows as text."
gh issue close 3 --repo getpipher/agent-statusline --comment "Fix shipped in fbdf304; re-verified empty-pass guard and scan-record persistence."
gh issue close 2 --repo getpipher/agent-statusline --comment "Fix shipped in fbdf304; re-verified timer re-arm before runChunk and advancing snapshot seq."
```

## Critical files & anchors

- `lib/bridge.luau` (new) — whole module; file-backed config/refresh pattern copied from `lib/keys.luau:21-58,85-99`.
- `window.luau` — `rebuild()` end at `:354` (new pure helpers), formatter/widget at `:360-437`, widget action/Refresh at `:441-472`, five refresh writes at `:443,469,498,530,567`, Config at `:540-571`, Debug at `:574-597`.
- `lib/deen.luau` — `readConfig()` at `:267-282`, `refreshPending()` at `:284-288`, `cycleBody()` refresh consumption at `:533-540`.
- `packages/omp-renderer/src/read.ts` — `AslSnapshot` at `:62-70`, `parseSnapshot()` at `:168-191`.
- `packages/omp-renderer/src/render.ts` — `prayerLine` comment at `:111-114`, `renderRows()` at `:193-200`.

## Assumptions & contingencies

- The pane feature and `#2`/`#3` fixes stay as shipped; Step 1 is verification only. If a check fails, restore from the named commit before proceeding.
- Config accepts arbitrary extra keys as today; consumers ignore unknown keys. If RECTOR wants a strict six-key whitelist, add it to the Config command only — no other step changes.
- `cx.session:focused()` / `cx.session:pane()` are documented but not previously used in this plugin. If both they and the `panes()` fallback fail at runtime, keep the digest with null pane fields rather than failing the Debug command; report the runtime limitation when closing `#5`.
- The file dir is the same `<tern.plugin.data>` already proven by `keys.json`. If `tern.plugin.data` is unavailable in a context, all bridge reads/writes fall back to kv/defaults and `storeConfig`/`requestRefresh` return `false`; toasts must say so rather than claim success.
