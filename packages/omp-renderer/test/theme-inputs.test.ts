// test/theme-inputs.test.ts — deriveAccentInputs: rebuilds SessionAccentInputs
// from the omp ≥ 19.2 widget-theme facade (issue #10). Stub style mirrors
// render.test.ts: wrap(code) fakes fg() with real 38;2 SGR frames. The
// facadeStub mirrors probe-verified live 19.2.1 behavior: accent/success/
// warning/error/dim truecolor, "info" throws, "text" not colorized.
import { test } from "node:test";
import assert from "node:assert/strict";
import { deriveAccentInputs } from "../src/theme-inputs.ts";
import { resolveAccent } from "../src/accent.ts";
import type { SlTheme } from "../src/render.ts";

const wrap = (code: string) => (s: string): string => `\x1b[38;2;${code}m${s}\x1b[39m`;
const dimmed = wrap("108;112;134");

// Catppuccin-flavored dark theme: distinct hues per collision token.
// accent 136;8;8 is the plan's pinned probe vector.
const DARK_CODES: Record<string, string> = {
  accent: "136;8;8",
  success: "126;231;135",
  warning: "223;164;70",
  error: "222;88;92",
  info: "137;220;235",
  text: "205;214;244",
};
const colorized = (token: string, s: string): string => (DARK_CODES[token] ? wrap(DARK_CODES[token])(s) : dimmed(s));
const darkStub: SlTheme = { dark: true, fg: colorized };

// Live-19.2.1-faithful: "info" throws, "text" returns plain text.
const facadeStub: SlTheme = {
  dark: true,
  fg: (token, s) => {
    if (token === "info") throw new Error("Unknown theme color: info");
    if (token === "text") return s;
    return colorized(token, s);
  },
};

test("truecolor dark stub → full inputs, padded lowercase hexes", () => {
  const inputs = deriveAccentInputs(darkStub);
  assert.ok(inputs, "dark truecolor theme must yield inputs");
  assert.deepStrictEqual(inputs, {
    accentHex: "#880808",
    colorHexes: ["#7ee787", "#dfa446", "#de585c", "#89dceb", "#cdd6f4"],
    surfaceLuminance: undefined,
  });
  for (const hex of inputs.colorHexes) assert.match(hex, /^#[0-9a-f]{6}$/);
});

test("facade-faithful stub (info throws, text uncolorized) → collisions drop both", () => {
  const inputs = deriveAccentInputs(facadeStub);
  assert.ok(inputs, "the live facade shape must still yield inputs");
  assert.deepStrictEqual(inputs.colorHexes, ["#7ee787", "#dfa446", "#de585c"]);
});

test("plain-text token drops out of colorHexes, never poisons the inputs", () => {
  const stub: SlTheme = { dark: true, fg: (token, s) => (token === "success" ? s : colorized(token, s)) };
  const inputs = deriveAccentInputs(stub);
  assert.ok(inputs, "one plain-text collision token must not kill the inputs");
  assert.strictEqual(inputs.colorHexes.length, 4);
  assert.ok(!inputs.colorHexes.includes("#7ee787"));
});

test("missing accent token → undefined (nothing to adopt)", () => {
  const stub: SlTheme = { dark: true, fg: (token, s) => (token === "accent" ? s : colorized(token, s)) };
  assert.strictEqual(deriveAccentInputs(stub), undefined);
});

test("256-color SGR → undefined (truecolor-only by design)", () => {
  const stub: SlTheme = { dark: true, fg: (_token, s) => `\x1b[38;5;61m${s}\x1b[39m` };
  assert.strictEqual(deriveAccentInputs(stub), undefined);
});

test("light theme (dark flag false) → undefined (dark-only scope)", () => {
  const stub: SlTheme = { dark: false, fg: colorized };
  assert.strictEqual(deriveAccentInputs(stub), undefined);
});

test("dark flag absent → undefined (conservative degrade)", () => {
  const stub: SlTheme = { fg: colorized };
  assert.strictEqual(deriveAccentInputs(stub), undefined);
});

test("fg that throws → undefined; theme without fg → undefined", () => {
  const throwing: SlTheme = {
    dark: true,
    fg: () => {
      throw new Error("boom");
    },
  };
  assert.strictEqual(deriveAccentInputs(throwing), undefined);
  assert.strictEqual(deriveAccentInputs({} as unknown as SlTheme), undefined);
});

test("round-trip: derived inputs feed a working accent colorizer", () => {
  const acc = resolveAccent(true, "probe-session", deriveAccentInputs(darkStub));
  assert.ok(acc, "resolveAccent should produce a colorizer from derived inputs");
  assert.ok(acc("x").includes("\x1b[38;2;"));
});
