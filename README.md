# Agent Statusline

Tern-native statusline plugin: clock, Islamic prayer times, session money
ledger and LLM quota windows as chrome segments, an opt-in quota-meter
widget, and a click-opened status panel block.

Successor to [`@getpipher/omp-statusline`](https://github.com/getpipher/omp-statusline)
(frozen at v0.8.12): the same information set, delivered natively in Tern
chrome. The same snapshot also feeds a thin omp renderer
(`packages/omp-renderer`, npm `@getpipher/agent-statusline`) that keeps the
six-row block rendering inside the omp TUI.

## Install

```sh
tern plugin install github.com/getpipher/agent-statusline
```

## What it shows

| Surface | Content |
| --- | --- |
| Status bar | one rotating segment (5 s cadence): clock · next prayer · `DAY $…` money · active-provider quota — click opens the Status Panel |
| Quota meter widget (opt-in) | rolling-window usage bar, hover card with every quota window, money windows and next prayer |
| Status panel (click a segment / `ctrl+shift+s`) | info header (weekday/clock, Hijri + Gregorian, city), five prayers, money windows (REPO/DAY/7DAY/30DAY), quota windows with pace + reset, versions footer |

Data is read-only side effects of your own machine and accounts:

- **Money** — scanned from omp session JSONL (`~/.omp/agent/sessions`). The
  first pass after a Tern daemon restart runs chunked in the background and
  can take several minutes on large session trees; last-known totals seed
  the fresh snapshot across the gap (age-guarded at 6 h). Quota and deen
  land within seconds.
- **Quota windows** — z.ai quota API and OpenCode Go usage API, polled on a
  3 min default cadence (fail-soft; last good values are kept).
- **Deen** — prayer times + Hijri date from Aladhan for your city,
  cached per city-day.

## API keys

Quota rows render only for providers with a resolvable key — missing keys
shorten the row, they never render placeholders.

1. **Palette:** `Set Keys` (both providers) or `Set OpenCode Go Key` (one prompt,
   no z.ai needed). Keys are written to tern.kv `asl/keys` **and** a verified
   keys file at `<tern.plugin.data>/keys.json` (read back before success is
   reported). The file is plaintext in the user-scoped Tern state dir — same
   at-rest model as `~/.pi/agent/auth.json`.
2. Environment variables `ZAI_API_KEY` / `OPENCODE_API_KEY` (read from the
   Tern daemon's environment).
3. z.ai only: `$HOME/.pi/agent/auth.json` → `{"zai": {"key": …}}` (the same
   fallback file omp-statusline used).

Resolution ladder: kv → keys file → environment → z.ai auth.json. The keys
file exists because tern.kv writes from the window half have not been observed
reaching the host's persisted store; the host re-resolves keys every poll cycle.

## Commands

| Command | Keys | Action |
| --- | --- | --- |
| Status Panel | `ctrl+shift+s` | Open the panel block over the focused pane |
| Refresh | — | Force quota/deen polls on the next host tick |
| Set Keys / Set OpenCode Go Key | — | Store quota keys (one or both prompts; keys file verified before success) |
| Config | — | Set config values (city, country, method, escalateMinutes, zaiPollMs, opencodePollMs) |
| Debug | — | Copy the snapshot JSON (incl. agent model strings) to the clipboard |

## The omp renderer

`packages/omp-renderer` (npm `@getpipher/agent-statusline`) is an omp
extension with zero data logic: it reads this plugin's snapshot file
(`<state>/plugin-data/agent-statusline/kv.json`) and renders the classic
six-row block below the omp composer. Install it in omp with:

```sh
omp plugin install @getpipher/agent-statusline
```

It needs Tern to have produced a snapshot at least once; outside a running
Tern it renders the last snapshot with a `· stale Xm` chip (nothing at all
before the first snapshot).

## License

MIT — see [LICENSE](LICENSE).
