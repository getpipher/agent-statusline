// src/read.ts — the Tern plugin's snapshot file reader. Zero data logic:
// resolve the kv.json path (platform ladder), 30 s mtime poll, one boundary
// parse with per-field typeof checks (pi-statusline config contract), typed
// AslSnapshot out. Absent file → null (renderer shows ZERO rows); parse
// failure keeps last-good (fail-soft, like every omp-statusline poller).
//
// Path ladder for <state>: $TERN_CONFIG_DIR if set, else darwin
// ~/Library/Application Support/Tern, else linux $XDG_STATE_HOME/tern ||
// ~/.local/state/tern, else win32 %LOCALAPPDATA%/Tern — then
// /plugin-data/agent-statusline/kv.json.
import { homedir } from "node:os";
import { join } from "node:path";
import { readFileSync, statSync } from "node:fs";

export interface AslWindow {
  label: string;
  usagePct: number;
  elapsedPct: number;
  paceOverSec: number;
  resetMs: number;
}

export interface AslMoneyWindow {
  usd: number;
  tokens?: number;
}

export interface AslMoney {
  repo?: AslMoneyWindow;
  repoName?: string;
  day?: AslMoneyWindow;
  d7?: AslMoneyWindow;
  d30?: AslMoneyWindow;
}

export interface AslProvider {
  fetchedMs?: number;
  windows: AslWindow[];
}

export interface AslPrayer {
  name: string;
  time: string;
  past: boolean;
}

export interface AslNextPrayer {
  name: string;
  inSec: number;
}

export interface AslDeen {
  city?: string;
  hijri?: string;
  gregorian?: string;
  prayers: AslPrayer[];
  nextPrayer?: AslNextPrayer;
  /** When nextPrayer.inSec was computed; countdowns subtract elapsed time since. */
  computedAtMs?: number;
}

export interface AslSnapshot {
  seq: number;
  updatedMs: number;
  money?: AslMoney;
  zai?: AslProvider;
  opencode?: AslProvider;
  deen?: AslDeen;
  errors?: { zai?: string | null; opencode?: string | null; deen?: string | null; money?: string | null };
}

const SNAPSHOT_KEY = "asl/snapshot";

function num(v: unknown): number | undefined {
  return typeof v === "number" && Number.isFinite(v) ? v : undefined;
}

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

function moneyWindow(v: unknown): AslMoneyWindow | undefined {
  if (typeof v !== "object" || v === null) return undefined;
  const usd = num((v as Record<string, unknown>).usd);
  if (usd === undefined) return undefined;
  const tokens = num((v as Record<string, unknown>).tokens);
  return tokens === undefined ? { usd } : { usd, tokens };
}

function window_(v: unknown): AslWindow | undefined {
  if (typeof v !== "object" || v === null) return undefined;
  const w = v as Record<string, unknown>;
  const label = str(w.label);
  const usagePct = num(w.usagePct);
  const resetMs = num(w.resetMs);
  if (label === undefined || usagePct === undefined || resetMs === undefined) return undefined;
  return { label, usagePct, resetMs, elapsedPct: num(w.elapsedPct) ?? 0, paceOverSec: num(w.paceOverSec) ?? 0 };
}

function provider(v: unknown): AslProvider | undefined {
  if (typeof v !== "object" || v === null) return undefined;
  const raw = v as Record<string, unknown>;
  const windows = Array.isArray(raw.windows)
    ? raw.windows.map(window_).filter((w): w is AslWindow => w !== undefined)
    : [];
  return { fetchedMs: num(raw.fetchedMs), windows };
}

function deen(v: unknown): AslDeen | undefined {
  if (typeof v !== "object" || v === null) return undefined;
  const raw = v as Record<string, unknown>;
  const prayers = Array.isArray(raw.prayers)
    ? raw.prayers
      .map((p): AslPrayer | undefined => {
        if (typeof p !== "object" || p === null) return undefined;
        const name = str((p as Record<string, unknown>).name);
        const time = str((p as Record<string, unknown>).time);
        if (name === undefined || time === undefined) return undefined;
        return { name, time, past: (p as Record<string, unknown>).past === true };
      })
      .filter((p): p is AslPrayer => p !== undefined)
    : [];
  let nextPrayer: AslNextPrayer | undefined;
  const np = raw.nextPrayer;
  if (typeof np === "object" && np !== null) {
    const name = str((np as Record<string, unknown>).name);
    const inSec = num((np as Record<string, unknown>).inSec);
    if (name !== undefined && inSec !== undefined) nextPrayer = { name, inSec };
  }
  return {
    city: str(raw.city),
    hijri: str(raw.hijri),
    gregorian: str(raw.gregorian),
    prayers,
    nextPrayer,
    computedAtMs: num(raw.computedAtMs),
  };
}

function money(v: unknown): AslMoney | undefined {
  if (typeof v !== "object" || v === null) return undefined;
  const raw = v as Record<string, unknown>;
  const out: AslMoney = {
    repo: moneyWindow(raw.repo),
    repoName: str(raw.repoName),
    day: moneyWindow(raw.day),
    d7: moneyWindow(raw.d7),
    d30: moneyWindow(raw.d30),
  };
  return out.repo || out.day || out.d7 || out.d30 ? out : undefined;
}

export function snapshotPath(env: NodeJS.ProcessEnv = process.env, platform: NodeJS.Platform = process.platform, home: string = homedir()): string {
  const base = env.TERN_CONFIG_DIR
    ? env.TERN_CONFIG_DIR
    : platform === "darwin"
      ? join(home, "Library", "Application Support", "Tern")
      : platform === "linux"
        ? (env.XDG_STATE_HOME ? join(env.XDG_STATE_HOME, "tern") : join(home, ".local", "state", "tern"))
        : platform === "win32"
          ? join(env.LOCALAPPDATA ?? join(home, "AppData", "Local"), "Tern")
          : join(home, ".local", "state", "tern"); // exotic platforms → linux-style state dir
  return join(base, "plugin-data", "agent-statusline", "kv.json");
}

// One boundary parse of the tern.kv JSON (object key → value), then per-field
// typeof checks on the "asl/snapshot" member. Anything malformed → null.
export function parseSnapshot(raw: string): AslSnapshot | null {
  let kv: unknown;
  try {
    kv = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof kv !== "object" || kv === null) return null;
  const s = (kv as Record<string, unknown>)[SNAPSHOT_KEY];
  if (typeof s !== "object" || s === null) return null;
  const seq = num((s as Record<string, unknown>).seq);
  const updatedMs = num((s as Record<string, unknown>).updatedMs);
  if (seq === undefined || updatedMs === undefined) return null;
  const snap: AslSnapshot = { seq, updatedMs };
  const m = money((s as Record<string, unknown>).money);
  if (m) snap.money = m;
  const zai = provider((s as Record<string, unknown>).zai);
  if (zai) snap.zai = zai;
  const oc = provider((s as Record<string, unknown>).opencode);
  if (oc) snap.opencode = oc;
  const d = deen((s as Record<string, unknown>).deen);
  if (d) snap.deen = d;
  return snap;
}

export function readSnapshotFile(path: string): AslSnapshot | null {
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return null;
  }
  return parseSnapshot(raw);
}

export interface SnapshotReader {
  /** Re-check the file mtime; re-read + re-parse on change. Tolerate errors. */
  poll(): void;
  /** Last-good snapshot, or null (absent file / never parsed). */
  current(): AslSnapshot | null;
  path(): string;
}

export function createSnapshotReader(opts: { path?: string } = {}): SnapshotReader {
  const path = opts.path ?? snapshotPath();
  let lastMtimeMs: number | null = null;
  let snap: AslSnapshot | null = null;
  return {
    path: () => path,
    current: () => snap,
    poll: () => {
      let mtimeMs: number;
      try {
        mtimeMs = statSync(path).mtimeMs;
      } catch {
        lastMtimeMs = null;
        snap = null; // absent file → ZERO rows by contract
        return;
      }
      if (lastMtimeMs !== null && mtimeMs === lastMtimeMs) return;
      lastMtimeMs = mtimeMs;
      const next = readSnapshotFile(path);
      if (next) snap = next; // unreadable/torn → keep last-good
    },
  };
}
