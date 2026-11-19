// src/format.ts — pure time/number helpers copied from @getpipher/omp-statusline
// v0.8.12 (src/format.ts + compactK from src/index.ts). The row GRAMMAR is
// omp-statusline's, exactly; these helpers are the grammar's vocabulary.
// No imports from the omp-statusline repo — self-contained by contract.

// Dashboard-style compact credits (omp-statusline compactK): 7664 → "7.7K",
// 28000 → "28K", 37160 → "37.2K", 140000 → "140K".
export function compactK(v: number): string {
  if (v < 1000) return `${Math.round(v)}`;
  const s = v / 1000 < 100 ? (v / 1000).toFixed(1) : `${Math.round(v / 1000)}`;
  return `${s.endsWith(".0") ? s.slice(0, -2) : s}K`;
}

// Countdown to a ms-epoch reset. Unit spaces (`3h 57m`, `6d 6h`) — RECTOR's
// pomodoro style for the quota-row parenthetical.
export function formatReset(targetMs: number, now: number): string {
  const remaining = targetMs - now;
  if (remaining <= 0) return "now";
  const hours = Math.floor(remaining / 3_600_000);
  const minutes = Math.floor((remaining % 3_600_000) / 60_000);
  if (hours > 24) {
    const days = Math.floor(hours / 24);
    return `${days}d ${hours % 24}h`;
  }
  return `${hours}h ${minutes}m`;
}

// Absolute reset wall-clock (reset-time feature): same-day resets read as clock
// time (`23:30`); anything further out carries an EN weekday + month-day
// (`Sat Sep 12 04:09`). Machine-local like the clock; hardcoded EN tables keep
// rendering deterministic (no Intl comma/platform variance).
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"] as const;

export function formatClock(ts: number): string {
  const d = new Date(ts);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

export function formatResetAbs(targetMs: number, now: number): string {
  if (targetMs <= now) return "now";
  const t = new Date(targetMs);
  const n = new Date(now);
  const sameDay =
    t.getFullYear() === n.getFullYear() &&
    t.getMonth() === n.getMonth() &&
    t.getDate() === n.getDate();
  return sameDay
    ? formatClock(targetMs)
    : `${WEEKDAYS[t.getDay()]} ${MONTHS[t.getMonth()]} ${String(t.getDate()).padStart(2, "0")} ${formatClock(targetMs)}`;
}

// Gregorian gloss beside the Hijri date — `09 Sep 2026`. Machine-local like the
// clock; reuses MONTHS for deterministic EN rendering (no Intl/platform variance).
export function formatGregorian(ts: number): string {
  const d = new Date(ts);
  return `${String(d.getDate()).padStart(2, "0")} ${MONTHS[d.getMonth()]} ${d.getFullYear()}`;
}

// 3-letter EN weekday abbreviations, machine-local like MONTHS above.
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;

export function formatWeekday(ts: number): string {
  return WEEKDAYS[new Date(ts).getDay()];
}
