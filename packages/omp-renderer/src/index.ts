// agent-statusline — omp in-pane renderer (npm @getpipher/agent-statusline).
// The Tern plugin does ALL data work and writes one snapshot file; this
// extension is a zero-logic consumer: read a JSON file, render the classic
// six-row block below the composer in omp-statusline v0.8.12's exact grammar.
//
//   󰥔 info · 󰣎 prayers · 󰄬 money · 󰚯 zai/opencode windows · 󰚦 versions
//
// Staleness: updatedMs older than 5 min appends a dim `· stale Xm` chip to the
// info row. Snapshot file absent → ZERO rows (no error output). Provider rows
// gate on ctx.models.current().provider exactly like omp-statusline v0.8.12.
import { createSnapshotReader } from "./read.ts";
import { basename } from "node:path";
import { renderRows, type SlTheme, type VersionStamp } from "./render.ts";
import { resolveAccent, type AccentFn } from "./accent.ts";
import { deriveAccentInputs } from "./theme-inputs.ts";
import { aslVersion, ompVersion, ternVersion } from "./versions.ts";

// --- omp extension API (structural; no host import — copied from omp-statusline v0.8.12) ---
interface SlWidgetComponent {
  render(options?: unknown): string[];
}
interface SlUi {
  setWidget(
    name: string,
    factory: (tui: unknown, theme: SlTheme) => SlWidgetComponent,
    options?: { placement?: "aboveEditor" | "belowEditor" },
  ): void;
  notify(message: string, type?: "info" | "warning" | "error"): void;
}
interface SlModel {
  provider?: string;
}
interface SlCtx {
  ui: SlUi;
  // omp-native model facade; absent → provider reads as undefined and BOTH
  // providers' rows show (inert-adapter: visible beats vanishing).
  models?: { current(): SlModel | null };
  // omp-native session facade — the session NAME feeds the accent hash, and
  // getCwd() is the session's cwd (the process cwd is only the fallback).
  // Optional: unnamed sessions render tokens-only (accent degrades, nothing crashes).
  sessionManager?: { getSessionName?(): string | undefined; getCwd?(): string };
  // Managed timers (omp ExtensionContext): throw/rejection routes through the
  // extension error channel instead of uncaughtException session teardown;
  // unref'd + auto-cleared on session_shutdown. Optional → raw unref'd global
  // timer is the fallback on hosts without them.
  setInterval?(fn: () => void, ms: number): unknown;
  clearTimer?(timer: unknown): void;
}
interface SlApi {
  on(event: "session_start" | "model_select", handler: (event: unknown, ctx: SlCtx) => void): void;
}

export function currentRepoName(ctx: Pick<SlCtx, "sessionManager"> | null, fallbackCwd: string): string {
  return basename(ctx?.sessionManager?.getCwd?.() ?? fallbackCwd);
}

const WIDGET_NAME = "asl";
const POLL_MS = 30_000;

export default function agentStatusline(pi: SlApi): void {
  const reader = createSnapshotReader();
  let ctx: SlCtx | null = null;
  let started = false;
  // Clock-line stamp: asl resolves synchronously (package.json next to the
  // source) and tern synchronously from the environment (TERM_PROGRAM/
  // TERM_PROGRAM_VERSION, fixed before omp launches); omp resolves async (one
  // `--version` spawn of the RUNNING binary) and re-renders.
  let stamp: VersionStamp = { omp: null, asl: aslVersion(), tern: ternVersion() };

  function widgetLines(theme: SlTheme): string[] {
    const snap = reader.current();
    if (!snap) return []; // absent/unreadable snapshot → zero rows, no error output
    const provider = ctx?.models?.current()?.provider;
    // Option A accent, resolved fresh per render (omp re-hands the theme on
    // factory calls, so /theme switches re-dress on the next tick). Session
    // renames re-roll the hue at the next tick — no rename event.
    const accent: AccentFn | null = resolveAccent(true, ctx?.sessionManager?.getSessionName?.(), theme.sessionAccentInputs ?? deriveAccentInputs(theme));
    return renderRows(snap, { theme, now: Date.now(), provider, stamp, accent, repo: currentRepoName(ctx, process.cwd()) });
  }

  function renderWidget(): void {
    if (!ctx) return;
    try {
      ctx.ui.setWidget(
        WIDGET_NAME,
        (_tui: unknown, theme: SlTheme) => ({ render: () => widgetLines(theme) }),
        { placement: "belowEditor" },
      );
    } catch {
      // Widget surface unavailable → no fallback surface by contract (the
      // six-row block is the only surface; absent snapshot already means zero rows).
    }
  }

  pi.on("session_start", (_event: unknown, slCtx: SlCtx) => {
    ctx = slCtx;
    if (started) return;
    started = true;
    reader.poll();
    renderWidget(); // first paint NOW — the reader is sync; the tick only refreshes countdowns
    void ompVersion().then((omp) => {
      if (omp && omp !== stamp.omp) {
        stamp = { ...stamp, omp };
        renderWidget(); // tick would cover it; render immediately so the stamp never flickers in late
      }
    });
    // Countdowns (prayer + quota resets) move without new data; the same tick
    // polls the snapshot file's mtime for host-side updates (30 s cadence).
    const tick = (): void => {
      reader.poll();
      renderWidget();
    };
    if (typeof slCtx.setInterval === "function") slCtx.setInterval(tick, POLL_MS);
    else {
      const t = setInterval(tick, POLL_MS);
      t.unref?.();
    }
  });

  // Provider gate re-reads per render — /model switches take effect on this event.
  pi.on("model_select", () => renderWidget());
}
