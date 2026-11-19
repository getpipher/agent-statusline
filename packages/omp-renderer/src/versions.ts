// src/versions.ts — version-row stamp sources, copied from omp-statusline
// v0.8.12 (src/versions.ts; slVersion → aslVersion). All resolved once per
// process and cached: the stamp describes the RUNNING omp, the INSTALLED
// renderer, and the HOSTING tern terminal, none of which changes while the
// session lives.
import { readFileSync } from "node:fs";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileP = promisify(execFile);

const SEMVER_RE = /\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.+-]+)?/;

// Pure extraction: "18.3.4\n" → "18.3.4"; "omp version 18.3.4 (bun)" → "18.3.4";
// anything without a bare x.y.z token → null.
export function extractSemver(text: string): string | null {
  return SEMVER_RE.exec(text.trim())?.[0] ?? null;
}

// Guard over `--version` output: omp prints "omp/18.4.8" (legacy: "omp version …").
// A bare "22.11.0" — what `node --version`/`bun --version` print when execPath
// points at a plain runtime instead of omp (source/dev runs) — must NOT become
// the omp stamp, so anything without the omp prefix is rejected.
export function parseOmpVersionOutput(text: string): string | null {
  const t = text.trim();
  return /^omp[/ ]/.test(t) ? extractSemver(t) : null;
}

// Spawn THE RUNNING BINARY: process.execPath is whatever binary actually launched
// omp, so the answer is install-agnostic and stays correct for sessions resumed
// across an upgrade. Spawn failure → null: the stamp segment is omitted upstream,
// never rendered as a placeholder lie.
export async function spawnOmpVersion(bin: string): Promise<string | null> {
  try {
    const { stdout } = await execFileP(bin, ["--version"], { timeout: 5_000 });
    return parseOmpVersionOutput(stdout);
  } catch {
    return null;
  }
}

let ompCache: Promise<string | null> | undefined;

// Running-binary spawn, cached process-long so it fires at most once per process.
export function ompVersion(bin: string = process.execPath): Promise<string | null> {
  ompCache ??= spawnOmpVersion(bin);
  return ompCache;
}

// Tern (stencil.so terminal) sets TERM_PROGRAM=tern + TERM_PROGRAM_VERSION for the
// sessions it hosts — a synchronous, install-agnostic source needing no spawn.
// Strict, case-sensitive gate: a lookalike ("Tern") or any other terminal
// (Ghostty, tmux — even with a version set) must not borrow the segment, and
// TERN_* side-channel vars don't count. Unknown version → null: the segment is
// omitted upstream, never rendered as a placeholder lie.
export function ternVersionSource(env: NodeJS.ProcessEnv): string | null {
  if (env.TERM_PROGRAM !== "tern") return null;
  return extractSemver(env.TERM_PROGRAM_VERSION ?? "");
}

let ternCache: string | null | undefined;

// Env read, cached process-long: Tern's version cannot change while the process
// lives. The explicit undefined check caches null misses too — `??=` would
// re-run the gate on every call in the common non-Tern case.
export function ternVersion(env: NodeJS.ProcessEnv = process.env): string | null {
  if (ternCache !== undefined) return ternCache;
  ternCache = ternVersionSource(env);
  return ternCache;
}

let aslCache: string | null | undefined;

// This package's own package.json, resolved relative to this module — works both
// in the repo and under ~/.omp/plugins/node_modules/@getpipher/agent-statusline/.
export function aslVersion(): string | null {
  if (aslCache !== undefined) return aslCache;
  try {
    const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")) as { version?: unknown };
    aslCache = typeof pkg.version === "string" && pkg.version.length > 0 ? pkg.version : null;
  } catch {
    aslCache = null;
  }
  return aslCache;
}
