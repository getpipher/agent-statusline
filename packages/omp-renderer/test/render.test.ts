// test/render.test.ts — snapshot → ANSI rows, pinned to omp-statusline
// v0.8.12's grammar. Deterministic: TZ pinned to Asia/Jakarta (machine-local
// clock/reset rendering is part of the grammar; hardcoded fixture epochs were
// derived by EXECUTING the real formatters, never hand-computed), now injected
// per renderRows call — no global clock monkey-patching.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, mkdtempSync, writeFileSync, unlinkSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { parseSnapshot, snapshotPath, createSnapshotReader } from "../src/read.ts";
import { renderRows, moneyLine, heat, paceFromOverSec, zaiRelevant, opencodeRelevant, type SlTheme } from "../src/render.ts";
import { getSessionAccentHex, nameToHash } from "../src/accent.ts";
import type { AslSnapshot } from "../src/read.ts";

process.env.TZ = "Asia/Jakarta";

// Fixed fake theme: distinct truecolor code per token so tone assertions prove
// which semantic token rendered (accent ≠ dim on purpose).
const CODES: Record<string, string> = {
  dim: "108;112;134",
  accent: "88;166;255",
  success: "126;231;135",
  warning: "223;164;70",
  error: "222;88;92",
  text: "200;200;200",
};
const wrap = (code: string) => (s: string): string => `\x1b[38;2;${code}m${s}\x1b[39m`;
const dim = wrap(CODES.dim);
const acc = wrap(CODES.accent);
const ok = wrap(CODES.success);
const warn = wrap(CODES.warning);
const txt = wrap(CODES.text);
const theme: SlTheme = { fg: (token, s) => wrap(CODES[token] ?? CODES.text)(s) };
const sep = dim(" · ");

const NOW = 1795057200000; // Thu Nov 19 2026 10:00 WIB
const FIXTURE_PATH = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "full-snapshot.json");
const snap = parseSnapshot(readFileSync(FIXTURE_PATH, "utf8")) as AslSnapshot;

function windowRow(glyphLabel: string, seg: string): string {
  return ` ${dim("󰚯")} ${dim(glyphLabel)} ${seg}`;
}

// Row assembly below is the hand-written grammar spec; every text/number
// literal was verified against the ported helpers at the fixture epochs.
const EXPECTED_FULL = [
  // 1 info
  ` ${dim("󰥔")} ${[dim("Thu 10:00"), dim("1 Jumādá al-ūlá 1448 (19 Nov 2026)"), dim("Jakarta")].join(sep)}`,
  // 2 prayers — past dim ✓, next green countdown, upcoming text
  ` ${dim("󰣎")} ${[dim("Fajr 04:15 ✓"), dim("Dhuhr 11:51 ✓"), ok("Asr 15:07 (5h 07m)"), txt("Maghrib 17:52"), txt("Isha 19:01")].join(sep)}`,
  // 3 money — REPO/DAY/7DAY/30DAY success-green + dim token parens
  ` ${dim("󰄬")} ${[
    `${dim("REPO")} ${ok("$68.36")} ${dim("(1.3B)")}`,
    `${dim("DAY")} ${ok("$26.50")} ${dim("(4.0M)")}`,
    `${dim("7DAY")} ${ok("$315.27")} ${dim("(4.0B)")}`,
    `${dim("30DAY")} ${ok("$492.88")} ${dim("(11.3B)")}`,
  ].join(sep)}`,
  // 4 zai windows — heat tone leading seg, pace token, dim countdown + absolute
  windowRow("zai", `${acc("5hrs 16%/26%")}${dim(" (")}${ok("30m under")}${dim(" · ")}${dim("3h 42m")}${dim(" · 13:42")}${dim(")")}`),
  windowRow("zai", `${acc("7DAY 33%/31%")}${dim(" (")}${warn("3h 22m over")}${dim(" · ")}${dim("4d 19h")}${dim(" · Tue Nov 24 05:00")}${dim(")")}`),
  // 5 opencode windows — MONTH is the anniversary window; 74% → warning heat
  windowRow("opencode", `${acc("5hrs 8%/12%")}${dim(" (")}${ok("12m under")}${dim(" · ")}${dim("2h 24m")}${dim(" · 12:24")}${dim(")")}`),
  windowRow("opencode", `${acc("7DAY 21%/19%")}${dim(" (")}${warn("1h 0m over")}${dim(" · ")}${dim("8d 0h")}${dim(" · Fri Nov 27 10:00")}${dim(")")}`),
  windowRow("opencode", `${warn("MONTH 74%/60%")}${dim(" (")}${warn("2d 21h over")}${dim(" · ")}${dim("13d 0h")}${dim(" · Wed Dec 02 10:00")}${dim(")")}`),
  // 6 versions — dim labels (accent null in tests) + dim values
  ` ${dim("󰚦")} ${[`${dim("omp")} ${dim("18.22.1")}`, `${dim("asl")} ${dim("0.1.0")}`, `${dim("tern")} ${dim("0.9.28")}`].join(sep)}`,
];

test("full snapshot → all six row kinds, exact ANSI strings", () => {
  const lines = renderRows(snap, { theme, now: NOW, stamp: { omp: "18.22.1", asl: "0.1.0", tern: "0.9.28" } });
  assert.deepEqual(lines, EXPECTED_FULL);
});

test("stale snapshot → dim `· stale Xm` chip appended to the info row only", () => {
  const now = snap.updatedMs + 450_000; // 7.5 min → "stale 7m"
  const lines = renderRows(snap, { theme, now, stamp: { omp: "18.22.1", asl: "0.1.0", tern: "0.9.28" } });
  assert.equal(lines.length, EXPECTED_FULL.length);
  // Same rows, later clock: updatedMs is 09:58:00, +7m30s → the info row re-renders at 10:05.
  const fresh = ` ${dim("󰥔")} ${[dim("Thu 10:05"), dim("1 Jumādá al-ūlá 1448 (19 Nov 2026)"), dim("Jakarta")].join(sep)}`;
  assert.equal(lines[0], `${fresh}${sep}${dim("stale 7m")}`);
  // now-dependent rows: the prayers countdown subtracts elapsed since computedAtMs
  // (09:58:00) — at 10:05:30 the Asr countdown shrank from 5h 07m to 5h 01m; money and
  // versions are byte-identical to the fresh render; window rows keep grammar with moved
  // countdowns — and no stale chip leaks onto any row but info.
  assert.match(lines[1], /Asr 15:07 \(5h 01m\)/);
  assert.equal(lines[2], EXPECTED_FULL[2]);
  assert.equal(lines[lines.length - 1], EXPECTED_FULL[EXPECTED_FULL.length - 1]);
  assert.match(lines[3], /30m under.*3h 36m/); // 13:42 from 10:05:30
  assert.equal(lines.slice(1).some((l) => l.includes("stale")), false);
  // 5-min boundary: exactly at the threshold → fresh; a second over → chip.
  const atThreshold = renderRows(snap, { theme, now: snap.updatedMs + 300_000 });
  assert.match(atThreshold[0], /Thu 10:03/);
  assert.doesNotMatch(atThreshold[0], /stale/);
  assert.match(renderRows(snap, { theme, now: snap.updatedMs + 300_001 })[0], /stale 5m/);
});

test("prayer countdown subtracts elapsed since computedAtMs and crosses the escalate band", () => {
  // computedAtMs is 09:58:00; at 14:43 (4h 45m later) the raw inSec (18540 s) has 17100 s
  // elapsed → 24 min remain, inside the 30-minute escalation band → warning.
  const now = 1795057080000 + 4 * 3600_000 + 45 * 60_000;
  const lines = renderRows(snap, { theme, now, stamp: { omp: "18.22.1", asl: "0.1.2", tern: "0.9.28" } });
  assert.match(lines[1], /Asr 15:07 \(24m\)/);
  assert.equal(lines[1], ` ${dim("󰣎")} ${[dim("Fajr 04:15 ✓"), dim("Dhuhr 11:51 ✓"), warn("Asr 15:07 (24m)"), txt("Maghrib 17:52"), txt("Isha 19:01")].join(sep)}`);
});

test("absent file → reader returns null → zero rows; parse failures keep last-good", () => {
  const dir = mkdtempSync(join(tmpdir(), "asl-test-"));
  const path = join(dir, "kv.json");
  const reader = createSnapshotReader({ path });
  reader.poll();
  assert.equal(reader.current(), null); // missing file → ZERO rows

  writeFileSync(path, readFileSync(FIXTURE_PATH, "utf8"));
  reader.poll();
  assert.equal(reader.current()?.seq, 42);

  // Torn/garbled write (mtime changes, JSON broken) → keep last-good.
  writeFileSync(path, "{not json");
  reader.poll();
  assert.equal(reader.current()?.seq, 42);

  // Valid JSON without the snapshot member → null.
  writeFileSync(path, JSON.stringify({ "asl/config": {} }));
  reader.poll();
  assert.equal(reader.current()?.seq, 42); // parse "failure" (member absent) → still last-good

  // File deleted → ZERO rows again.
  unlinkSync(path);
  reader.poll();
  assert.equal(reader.current(), null);
  rmSync(dir, { recursive: true, force: true });
});

test("parseSnapshot: malformed members degrade to absent, never throw", () => {
  assert.equal(parseSnapshot("nope"), null);
  assert.equal(parseSnapshot("5"), null);
  assert.equal(parseSnapshot(JSON.stringify({ other: 1 })), null);
  const noSeq = parseSnapshot(JSON.stringify({ "asl/snapshot": { updatedMs: 1 } }));
  assert.equal(noSeq, null);
  // nil money windows / prayer rows / malformed windows drop out gracefully.
  // sub/entries ride along in the raw snapshot but are not AslMoney fields —
  // unknown keys are ignored, never surfaced or fatal.
  const s = parseSnapshot(JSON.stringify({
    "asl/snapshot": {
      seq: 1,
      updatedMs: NOW,
      money: { repo: { usd: "x" }, day: { usd: 2 }, sub: null, entries: "7" },
      zai: { windows: [{ label: "5hrs", usagePct: 10, resetMs: NOW + 1 }, "junk", null] },
      deen: { prayers: [{ name: "Fajr", time: "04:15" }, "junk"], city: "", hijri: "1 M 1448" },
    },
  }));
  assert.ok(s);
  assert.equal(s.money?.repo, undefined);
  assert.deepEqual(s.money?.day, { usd: 2 });
  assert.equal(s.zai?.windows.length, 1);
  assert.deepEqual(s.deen?.prayers, [{ name: "Fajr", time: "04:15", past: false }]);
  assert.equal(s.deen?.city, undefined);
});

test("provider with no windows → its rows omitted (no placeholder row)", () => {
  const noZai = { ...snap, zai: { fetchedMs: 1, windows: [] } };
  const lines = renderRows(noZai, { theme, now: NOW });
  assert.equal(lines.filter((l) => l.includes(dim("zai"))).length, 0);
  assert.equal(lines.filter((l) => l.includes(dim("opencode"))).length, 3);
  const noBoth = { ...snap, zai: { windows: [] }, opencode: undefined };
  const lines2 = renderRows(noBoth, { theme, now: NOW });
  assert.equal(lines2.some((l) => l.includes("5hrs")), false);
  // Degraded block: info + prayers + money only.
  assert.equal(lines2.length, 3);
});

test("provider gate: active provider hides the other provider's rows", () => {
  const zaiOnly = renderRows(snap, { theme, now: NOW, provider: "zai" });
  assert.equal(zaiOnly.filter((l) => l.includes(dim("zai"))).length, 2);
  assert.equal(zaiOnly.filter((l) => l.includes(dim("opencode"))).length, 0);
  const ocOnly = renderRows(snap, { theme, now: NOW, provider: "opencode-go" });
  assert.equal(ocOnly.filter((l) => l.includes(dim("zai"))).length, 0);
  assert.equal(ocOnly.filter((l) => l.includes(dim("opencode"))).length, 3);
  // opencode-zen deliberately excluded; unreadable provider (undefined) shows all.
  const zen = renderRows(snap, { theme, now: NOW, provider: "opencode-zen" });
  assert.equal(zen.filter((l) => l.includes(dim("zai"))).length, 0);
  assert.equal(zen.filter((l) => l.includes(dim("opencode"))).length, 0);
  assert.equal(zaiRelevant(undefined) && zaiRelevant("zai") && !zaiRelevant("opencode-go"), true);
  assert.equal(opencodeRelevant(undefined) && opencodeRelevant("opencode-go") && !opencodeRelevant("zai") && !opencodeRelevant("opencode-zen"), true);
});

test("escalation band: next prayer inside escalateMinutes tints warning", () => {
  const soon = {
    ...snap,
    deen: { ...snap.deen!, nextPrayer: { name: "Asr", inSec: 900 } },
  };
  const lines = renderRows(soon, { theme, now: NOW });
  // inSec 900 computed at computedAtMs (09:58:00) → at NOW (10:00:00) 120 s elapsed → 13m left.
  assert.equal(lines[1], ` ${dim("󰣎")} ${[dim("Fajr 04:15 ✓"), dim("Dhuhr 11:51 ✓"), warn("Asr 15:07 (13m)"), txt("Maghrib 17:52"), txt("Isha 19:01")].join(sep)}`);
  // Out of the band → success (covered by the full case at 5h 07m); custom band width honored.
  const wide = renderRows(soon, { theme, now: NOW, escalateMinutes: 10 });
  assert.match(wide[1], /\x1b\[38;2;126;231;135mAsr 15:07 \(13m\)/);
});

test("parseSnapshot: config.escalateMinutes accepts finite positive numbers only", () => {
  const raw = JSON.parse(readFileSync(FIXTURE_PATH, "utf8"));
  raw["asl/snapshot"].config = { escalateMinutes: 12 };
  assert.equal(parseSnapshot(JSON.stringify(raw))?.config?.escalateMinutes, 12);
  raw["asl/snapshot"].config = { escalateMinutes: "x" };
  assert.equal(parseSnapshot(JSON.stringify(raw))?.config?.escalateMinutes, undefined);
  raw["asl/snapshot"].config = { escalateMinutes: -5 };
  assert.equal(parseSnapshot(JSON.stringify(raw))?.config?.escalateMinutes, undefined);
  raw["asl/snapshot"].config = "garbage";
  assert.equal(parseSnapshot(JSON.stringify(raw))?.config, undefined);
});

test("escalation band: snapshot config narrows the band without env override", () => {
  const soon = {
    ...snap,
    deen: { ...snap.deen!, nextPrayer: { name: "Asr", inSec: 900 } },
  };
  const withConfig = Object.assign({}, soon, { config: { escalateMinutes: 12 } });
  // 13m left: outside a 12m band → success; inside the 30m default → warning.
  assert.match(renderRows(withConfig, { theme, now: NOW })[1], /\x1b\[38;2;126;231;135mAsr 15:07 \(13m\)/);
  assert.match(renderRows(soon, { theme, now: NOW })[1], /\x1b\[38;2;223;164;70mAsr 15:07 \(13m\)/);
});

test("parseSnapshot: byRepo keeps valid money windows, skips invalid ones", () => {
  const raw = JSON.parse(readFileSync(FIXTURE_PATH, "utf8"));
  raw["asl/snapshot"].money.byRepo = {
    "agent-statusline": { usd: 6.78587754, tokens: 63823195 },
    "other-repo": { usd: 12.5 },
    "bad-usd": { usd: "x", tokens: 10 },
    "null-window": null,
    "string-window": "junk",
  };
  const parsed = parseSnapshot(JSON.stringify(raw));
  assert.ok(parsed);
  assert.deepEqual(parsed.money?.byRepo, {
    "agent-statusline": { usd: 6.78587754, tokens: 63823195 },
    "other-repo": { usd: 12.5 },
  });
  // Every pre-existing money field survives the byRepo parse unchanged.
  assert.deepEqual(parsed.money?.repo, { usd: 68.36, tokens: 1300000000 });
  assert.equal(parsed.money?.repoName, "agent-statusline");
  assert.deepEqual(parsed.money?.day, { usd: 26.5, tokens: 4000000 });
  assert.deepEqual(parsed.money?.d7, { usd: 315.27, tokens: 4000000000 });
  assert.deepEqual(parsed.money?.d30, { usd: 492.88, tokens: 11300000000 });
});

const scopedMoney = {
  ...snap.money!,
  byRepo: { "agent-statusline": { usd: 6.78587754, tokens: 63823195 } },
};
const EXPECTED_SCOPED = ` ${dim("󰄬")} ${[
  `${dim("REPO")} ${ok("$6.79")} ${dim("(63.8M)")}`,
  `${dim("DAY")} ${ok("$26.50")} ${dim("(4.0M)")}`,
  `${dim("7DAY")} ${ok("$315.27")} ${dim("(4.0B)")}`,
  `${dim("30DAY")} ${ok("$492.88")} ${dim("(11.3B)")}`,
].join(sep)}`;

test("renderRows/moneyLine: matching repo renders that bucket's $/tokens", () => {
  const scoped = { ...snap, money: scopedMoney };
  assert.equal(renderRows(scoped, { theme, now: NOW, repo: "agent-statusline" })[2], EXPECTED_SCOPED);
  assert.equal(moneyLine(theme, scopedMoney, sep, null, "agent-statusline"), EXPECTED_SCOPED);
});

test("renderRows: unknown/missing repo falls back to the global REPO window", () => {
  const scoped = { ...snap, money: scopedMoney };
  assert.equal(renderRows(scoped, { theme, now: NOW, repo: "not-a-known-repo" })[2], EXPECTED_FULL[2]);
  assert.equal(renderRows(scoped, { theme, now: NOW })[2], EXPECTED_FULL[2]);
  assert.equal(renderRows(snap, { theme, now: NOW, repo: "agent-statusline" })[2], EXPECTED_FULL[2]);
  // A bucket with a non-finite usd is not a valid window → global wins.
  const invalid = { ...scoped, money: { ...scopedMoney, byRepo: { "agent-statusline": { usd: Number.NaN } } } };
  assert.equal(renderRows(invalid, { theme, now: NOW, repo: "agent-statusline" })[2], EXPECTED_FULL[2]);
});

test("renderRows: no repo passed preserves today's exact full output", () => {
  const lines = renderRows(snap, { theme, now: NOW, stamp: { omp: "18.22.1", asl: "0.1.0", tern: "0.9.28" } });
  assert.deepEqual(lines, EXPECTED_FULL);
});

test("accent wraps glyphs + labels only; values keep semantic tokens", () => {
  const A = (t: string): string => `[A:${t}:A]`;
  const lines = renderRows(snap, { theme, now: NOW, accent: A, stamp: {} });
  assert.match(lines[0], /^ \[A:󰥔:A\] /);
  assert.match(lines[2], /\[A:REPO:A\] \x1b\[38;2;126;231;135m\$68\.36/);
  assert.match(lines[3], /^ \[A:󰚯:A\] \[A:zai:A\] /);
  // No stamp segments known → version row omitted entirely (no placeholder lie).
  assert.equal(lines.some((l) => l.includes("asl 0.1.0")), false);
});

test("window edges: >100% reads 100%+, zero pace reads `0m under`, heat bands", () => {
  const over = { ...snap, zai: { windows: [{ label: "7DAY", usagePct: 105, elapsedPct: 45, paceOverSec: 0, resetMs: NOW + 60_000 }] }, opencode: undefined };
  const lines = renderRows(over, { theme, now: NOW });
  assert.match(lines[3], /\x1b\[38;2;222;88;92m7DAY 100%\+\/45%/);
  assert.match(lines[3], /\x1b\[38;2;126;231;135m0m under/);
  assert.equal(heat(69), "accent");
  assert.equal(heat(70), "warning");
  assert.equal(heat(89), "warning");
  assert.equal(heat(90), "error");
  assert.deepEqual(paceFromOverSec(90 * 60), { text: "1h 30m over", token: "warning" });
  assert.deepEqual(paceFromOverSec(-90 * 60), { text: "1h 30m under", token: "success" });
  assert.deepEqual(paceFromOverSec(0), { text: "0m under", token: "success" });
  assert.deepEqual(paceFromOverSec(3 * 86400 + 7200), { text: "3d 2h over", token: "warning" });
});

test("accent port: golden vectors pin the oh-my-pi/catppuccin drift guard", () => {
  // Pinned against dark-catppuccin inputs (same vectors as omp-statusline
  // test/accent.test.ts). accent.ts is a verbatim port — if these fail, either
  // the port drifted or upstream tuned the algorithm → re-verify and re-pin.
  const INPUTS = {
    accentHex: "#fab387",
    colorHexes: ["#f5e0dc", "#f5c2e7", "#cba6f7", "#f38ba8", "#fab387", "#f9e2af", "#a6e3a1", "#94e2d5", "#89dceb", "#74c7ec", "#89b4fa", "#b4befe", "#cdd6f4"],
  };
  assert.equal(getSessionAccentHex("omp-statusline", INPUTS), "#5eddf5");
  assert.equal(getSessionAccentHex("gmtrade-hunt", INPUTS), "#6bda2b");
  assert.equal(getSessionAccentHex("getlumos", INPUTS), "#95cef2");
  assert.equal(getSessionAccentHex("omp-statusline", INPUTS), getSessionAccentHex("omp-statusline", { ...INPUTS }));
  assert.equal(nameToHash("a"), 177604); // 5381<<5 +5381 ^ 97, 32-bit
});

test("snapshotPath ladder: TERN_CONFIG_DIR → darwin → linux XDG → win32", () => {
  const K = "plugin-data/agent-statusline/kv.json";
  assert.equal(snapshotPath({ TERN_CONFIG_DIR: "/cfg" }, "darwin", "/h"), `/cfg/${K}`);
  assert.equal(snapshotPath({}, "darwin", "/h"), `/h/Library/Application Support/Tern/${K}`);
  assert.equal(snapshotPath({ XDG_STATE_HOME: "/s" }, "linux", "/h"), `/s/tern/${K}`);
  assert.equal(snapshotPath({}, "linux", "/h"), `/h/.local/state/tern/${K}`);
  assert.equal(snapshotPath({ LOCALAPPDATA: "/l" }, "win32", "/h"), `/l/Tern/${K}`);
  assert.equal(snapshotPath({}, "win32", "/h"), `/h/AppData/Local/Tern/${K}`);
  assert.equal(snapshotPath({}, "freebsd", "/h"), `/h/.local/state/tern/${K}`);
  // Defaults read the real process env.
  const real = snapshotPath();
  assert.equal(typeof real, "string");
  assert.match(real, /plugin-data\/agent-statusline\/kv\.json$/);
});
