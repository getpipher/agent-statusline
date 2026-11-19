// src/render.ts — snapshot → ANSI rows. The LOOK is omp-statusline v0.8.12's,
// exactly: same glyphs, tones, separators, spacing. Ported from its
// src/index.ts renderers (infoLine/prayerLine/moneyLine/windowSeg/versionLine)
// against the Tern plugin's snapshot shape instead of live omp state.
//
// Six rows, in order, each omitted when its data is absent — never placeholders:
//   1 info     󰥔 Thu 10:00 · 1 Jumādá al-ūlá 1448 (19 Nov 2026) · Jakarta [· stale Xm]
//   2 prayers  󰣎 Fajr 04:15 ✓ · … · Asr 15:07 (1h 20m) …   next green; escalateMinutes band → warning
//   3 money    󰄬 REPO $68.36 (1.3B) · DAY $26.50 (4.0M) · 7DAY · 30DAY [· sub $… · N entries]
//   4 zai      󰚯 zai 5hrs 16%/26% (30m under · 3h 42m · 13:42)      provider-gated
//   5 opencode 󰚯 opencode 5hrs/7DAY/MONTH …                        provider-gated
//   6 versions 󰚦 omp 18.22.1 · asl 0.1.0 · tern 0.9.28             omitted when all unknown
import { formatReset, formatResetAbs, formatWeekday } from "./format.ts";
import type { AccentFn, SessionAccentInputs } from "./accent.ts";
import type { AslDeen, AslMoney, AslMoneyWindow, AslProvider, AslSnapshot, AslWindow } from "./read.ts";

// v0.3.0 token volumes per window — RECTOR's `(138.2M)` dim parens after each $.
// (Copied from omp-statusline src/index.ts fmtTokens.)
export function fmtTokens(t: number): string {
  if (t >= 1e9) return `${(t / 1e9).toFixed(1)}B`;
  if (t >= 1e6) return `${(t / 1e6).toFixed(1)}M`;
  if (t >= 1e3) return `${(t / 1e3).toFixed(1)}K`;
  return `${Math.round(t)}`;
}

// --- omp extension API (structural; no host import — copied from omp-statusline) ---
export interface SlTheme {
  // omp theme instance handed to widget factories (probe-verified): fg(token, text)
  // returns theme-colored ANSI — success/warning/error/accent/dim/text…
  fg(token: string, text: string): string;
  // Theme-derived accent inputs (mirrors omp's Theme.sessionAccentInputs getter).
  // Real omp theme instances carry it; stubs may omit → resolveAccent returns null.
  sessionAccentInputs?: SessionAccentInputs;
}

// Heat bands (omp-statusline heat): quota windows tint accent → warning (≥70) → error (≥90).
export function heat(pct: number): string {
  if (pct >= 90) return "error";
  if (pct >= 70) return "warning";
  return "accent";
}

// Provider gates (omp-statusline semantics, verbatim): plan rows are only
// relevant while the active provider matches (or is unreadable → show).
// `opencode-zen` deliberately excluded: the endpoint reports the Go plan.
export function zaiRelevant(provider: string | undefined): boolean {
  return provider === undefined || provider === "zai";
}

export function opencodeRelevant(provider: string | undefined): boolean {
  return provider === undefined || provider === "opencode-go";
}

// Pace gap, snapshot-carried: the host stores window × (usage% − elapsed%)/100
// as seconds. over = burning faster than the clock → warning; under → success.
// (omp-statusline paceText, fed paceOverSec instead of lengthMs + percentages.)
export function paceFromOverSec(paceOverSec: number): { text: string; token: string } {
  const gapMs = paceOverSec * 1000;
  const m = Math.round(Math.abs(gapMs) / 60_000);
  const d = Math.floor(m / 1440);
  const h = Math.floor((m % 1440) / 60);
  const mm = m % 60;
  const t = d > 0 ? `${d}d ${h}h` : h > 0 ? `${h}h ${mm}m` : `${mm}m`;
  return gapMs > 0 ? { text: `${t} over`, token: "warning" } : { text: `${t} under`, token: "success" };
}

function windowSeg(theme: SlTheme, w: AslWindow, now: number): string {
  const usage = w.usagePct > 100 ? "100%+" : `${w.usagePct}%`;
  const pace = paceFromOverSec(w.paceOverSec);
  return [
    theme.fg(heat(w.usagePct), `${w.label} ${usage}/${w.elapsedPct}%`),
    theme.fg("dim", " ("),
    theme.fg(pace.token, pace.text),
    theme.fg("dim", " · "),
    theme.fg("dim", formatReset(w.resetMs, now)),
    theme.fg("dim", ` · ${formatResetAbs(w.resetMs, now)}`),
    theme.fg("dim", ")"),
  ].join("");
}

function providerLines(theme: SlTheme, providerLabel: string, data: AslProvider, now: number, accent: AccentFn | null): string[] {
  // Option A: accent carries the row glyph + provider label only — segments
  // keep heat semantics. Windows empty/absent → no rows (contract: degraded =
  // shorter block, never placeholders).
  const glyph = accent ?? ((t: string) => theme.fg("dim", t));
  return data.windows.map((w) => ` ${glyph("󰚯")} ${glyph(providerLabel)} ${windowSeg(theme, w, now)}`);
}

const STALE_AFTER_MS = 5 * 60_000;

// `updatedMs` older than 5 min → minutes count for the info-row chip; null = fresh.
export function staleMinutes(snap: AslSnapshot, now: number): number | null {
  const age = now - snap.updatedMs;
  return age > STALE_AFTER_MS ? Math.floor(age / 60_000) : null;
}

export function infoLine(theme: SlTheme, snap: AslSnapshot, sep: string, accent: AccentFn | null, now: number): string {
  const glyph = accent ?? ((t: string) => theme.fg("dim", t));
  const d = new Date(now);
  const clock = `${formatWeekday(now)} ${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  const parts = [clock];
  const deen = snap.deen;
  if (deen?.hijri) parts.push(deen.gregorian ? `${deen.hijri} (${deen.gregorian})` : deen.hijri);
  if (deen?.city) parts.push(deen.city);
  let out = ` ${glyph("󰥔")} ${parts.map((part) => theme.fg("dim", part)).join(sep)}`;
  const stale = staleMinutes(snap, now);
  if (stale !== null) out += `${sep}${theme.fg("dim", `stale ${stale}m`)}`;
  return out;
}

// Escalation band: when the next prayer is within escalateMinutes, its
// countdown cell tints warning instead of success (renderer-local default 30 —
// the Tern plugin's asl/config default; the snapshot carries no config).
const DEFAULT_ESCALATE_MINUTES = 30;

export function prayerLine(theme: SlTheme, deen: AslDeen, sep: string, accent: AccentFn | null, escalateMinutes: number = DEFAULT_ESCALATE_MINUTES): string {
  // Option A: accent on the 󰣎 glyph only — prayer names keep their state tokens
  // (past dim ✓, next success/warning, upcoming text).
  const glyph = accent ?? ((t: string) => theme.fg("dim", t));
  const cells = deen.prayers.map((p) => {
    if (deen.nextPrayer && p.name === deen.nextPrayer.name) {
      // Next wins over `past` (post-Isha the next prayer is tomorrow's Fajr,
      // which still carries past=true in the snapshot).
      const m = Math.max(0, Math.floor(deen.nextPrayer.inSec / 60));
      const cd = m < 60 ? `${m}m` : `${Math.floor(m / 60)}h ${String(m % 60).padStart(2, "0")}m`;
      const token = m <= escalateMinutes ? "warning" : "success";
      return theme.fg(token, `${p.name} ${p.time} (${cd})`);
    }
    if (p.past) return theme.fg("dim", `${p.name} ${p.time} ✓`);
    return theme.fg("text", `${p.name} ${p.time}`);
  });
  return ` ${glyph("󰣎")} ${cells.join(sep)}`;
}

export function moneyLine(theme: SlTheme, m: AslMoney, sep: string, accent: AccentFn | null): string | null {
  // Option A: accent on the 󰄬 glyph + window labels; dollar values stay
  // success-green. omp labels the all-time window REPO (basename of its cwd) —
  // the snapshot's repoName is informational only, the label stays REPO.
  const glyph = accent ?? ((t: string) => theme.fg("dim", t));
  const seg = (label: string, w: AslMoneyWindow | undefined): string | null => {
    if (!w) return null;
    const parens = w.tokens !== undefined ? ` ${theme.fg("dim", `(${fmtTokens(w.tokens)})`)}` : "";
    return `${glyph(label)} ${theme.fg("success", `$${w.usd.toFixed(2)}`)}${parens}`;
  };
  const parts = [seg("REPO", m.repo), seg("DAY", m.day), seg("7DAY", m.d7), seg("30DAY", m.d30)].filter((s) => s !== null);
  // Dim sub/entries tail (omp's /sl money digest, demoted to a row tail).
  if (m.sub !== undefined) parts.push(theme.fg("dim", `sub $${m.sub.toFixed(2)}`));
  if (m.entries !== undefined) parts.push(theme.fg("dim", `${m.entries} entries`));
  if (parts.length === 0) return null;
  return ` ${glyph("󰄬")} ${parts.join(sep)}`;
}

export interface VersionStamp {
  omp?: string | null;
  asl?: string | null;
  tern?: string | null;
}

// Segments whose version is unavailable are omitted — never rendered as a
// placeholder lie. Returns null when NO version is known (same contract as
// omp-statusline versionLine).
export function versionLine(theme: SlTheme, stamp: VersionStamp, accent: AccentFn | null): string | null {
  const glyph = accent ?? ((t: string) => theme.fg("dim", t));
  const parts: string[] = [];
  if (stamp.omp) parts.push(`${glyph("omp")} ${theme.fg("dim", stamp.omp)}`);
  if (stamp.asl) parts.push(`${glyph("asl")} ${theme.fg("dim", stamp.asl)}`);
  if (stamp.tern) parts.push(`${glyph("tern")} ${theme.fg("dim", stamp.tern)}`);
  if (parts.length === 0) return null;
  return ` ${glyph("󰚦")} ${parts.join(theme.fg("dim", " · "))}`;
}

export interface RenderEnv {
  theme: SlTheme;
  now: number;
  // ctx.models.current()?.provider — undefined (no model facade) shows all
  // key-bearing providers, omp-statusline inert-adapter semantics.
  provider?: string;
  stamp?: VersionStamp;
  accent?: AccentFn | null;
  escalateMinutes?: number;
}

export function renderRows(snap: AslSnapshot, env: RenderEnv): string[] {
  const { theme, now } = env;
  const sep = theme.fg("dim", " · ");
  const accent = env.accent ?? null;
  const lines: string[] = [];
  lines.push(infoLine(theme, snap, sep, accent, now));
  if (snap.deen?.prayers.length) lines.push(prayerLine(theme, snap.deen, sep, accent, env.escalateMinutes));
  if (snap.money) {
    const money = moneyLine(theme, snap.money, sep, accent);
    if (money) lines.push(money);
  }
  if (snap.zai && snap.zai.windows.length > 0 && zaiRelevant(env.provider)) {
    lines.push(...providerLines(theme, "zai", snap.zai, now, accent));
  }
  if (snap.opencode && snap.opencode.windows.length > 0 && opencodeRelevant(env.provider)) {
    lines.push(...providerLines(theme, "opencode", snap.opencode, now, accent));
  }
  if (env.stamp) {
    const version = versionLine(theme, env.stamp, accent);
    if (version) lines.push(version);
  }
  return lines;
}
