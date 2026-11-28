// src/theme-inputs.ts — rebuilds omp's `Theme.sessionAccentInputs` from the
// widget-theme facade omp ≥ 19.2 still hands widget factories (issue #10: the
// getter itself was dropped). Probe-verified live 19.2.1 facade: keys are
// name/dark/depth/symbols/json; fg() emits truecolor 38;2 per token, unknown
// tokens (e.g. "info") throw, "text" is not colorized — every probe below is
// defensive against both. Scope: dark surfaces only — `dark !== true`
// degrades to undefined inputs → dim, the pre-bridge look (never guessed
// colors). No caching — a handful of cheap string probes per render.
import type { SessionAccentInputs } from "./accent.ts";
import type { SlTheme } from "./render.ts";

const TRUECOLOR = /\x1b\[38;2;(\d{1,3});(\d{1,3});(\d{1,3})m/;
const COLLISION_TOKENS = ["success", "warning", "error", "info", "text"] as const;

export function deriveAccentInputs(theme: SlTheme): SessionAccentInputs | undefined {
  if (typeof theme.fg !== "function" || theme.dark !== true) return undefined;
  const probe = (token: string): string | null => {
    let out: string;
    try {
      out = theme.fg(token, "■");
    } catch {
      return null; // omp throws on unknown theme colors (probe-verified: "info")
    }
    const m = TRUECOLOR.exec(out); // first match only
    if (!m) return null; // uncolorized tokens emit no SGR (probe-verified: "text")
    const [r, g, b] = [Number(m[1]), Number(m[2]), Number(m[3])];
    if (r > 255 || g > 255 || b > 255) return null;
    return "#" + [r, g, b].map((v) => v.toString(16).padStart(2, "0")).join("");
  };
  const accentHex = probe("accent");
  if (!accentHex) return undefined;
  // Collision hues only; neutral/unavailable tokens drop out here and inside
  // getSessionAccentHex (MIN_CHROMA_FOR_HUE filter in hexToHue).
  const colorHexes = COLLISION_TOKENS.map(probe).filter((h): h is string => h !== null);
  return { accentHex, colorHexes, surfaceLuminance: undefined }; // undefined = dark (accent.ts isDark)
}
