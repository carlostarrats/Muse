# Color search — hex + color names in the search bar

**Date:** 2026-07-07
**Status:** Design approved, pending spec review
**Scope:** Let the existing search bar match by color. Color *names* already work (they're tags); this adds **hex codes** (single or multiple) matched perceptually against each file's stored palette. Text-only — no color picker, no new UI.

## Summary

The search field gains a color axis with **zero new UI**. The query string is parsed into tokens; any token that looks like a hex color (`#3a7bd5`, or the `#`-less `3a7bd5`) is pulled out and matched **perceptually** (LAB distance, "near" not "exact") against the `palette` each analyzed file already stores. Every other token flows through today's search unchanged.

This makes one gesture Just Work: the hero viewer's COLORS card "Copy all colors" button already writes the palette to the clipboard as `#3a7bd5, #f0e0c0, #202020`. Paste that string into search → three hex tokens → files whose palette contains a near-match for **all three** colors.

The four user-facing cases, all from one parser:

| Query | Handled by |
|---|---|
| `red` | today's search (color names are already tags via `ColorTagger`) |
| `#3a7bd5` | **new** — single-hex perceptual match |
| `red blue` | today's search |
| `#3a7bd5, #f0e0c0, #202020` (pasted from the card) | **new** — multi-hex AND match |

## Non-goals

- **No color picker / swatch UI.** Text bar only.
- **No "find similar to this image" button.** That gesture is just pasting the copied colors — no dedicated affordance.
- **No schema change.** The `palette` column already exists and is already populated by the analyze pass.
- **No change to color-name search.** Names are already tags and already match; this spec does not touch that path.
- **No new persisted state.** A color query is transient, exactly like any other search.

---

## 1. What already exists (verified)

- **`files.palette`** (`Records.swift:29`) — a JSON array of `#rrggbb` strings, ≤6, sorted by share descending. Written by the analyze pass (`AnalyzePipeline.swift:370–403`) from `PaletteExtractor`.
- **`files.dominant_color`** (`Records.swift:27`) — a single color value per file (used by smart-sort).
- **`NamedColor.parse(_ hex:) -> (Double, Double, Double)?`** (`NamedColor.swift:66`) — parses a hex string to RGB components. Returns `nil` for non-hex input. **This is the seam** the parser uses to both detect and decode hex tokens.
- **`ColorTagger`** (`Intelligence/Core/ColorTagger.swift`) — turns a palette into named color tags (`red`, `blue`, …). This is why `red` already searches today; **untouched by this spec.**
- **`SearchService.search(query:scope:)`** (`SearchService.swift:21`) — the single search entry point. Builds `exactIDs` (FTS5 + tag `LIKE` + note `LIKE`) then merges semantic hits, all inside one off-main `queue.read`, then scope-filters. Color matching slots into this same `queue.read`.
- **No LAB anywhere.** RGB→LAB + a distance metric is new pure code.

---

## 2. Architecture — three pure units + one integration point

Three pure, unit-tested value types do the work; `SearchService` calls them.

### 2.1 `ColorQuery` — token classification (pure)

```
enum ColorQuery {
    struct Parsed { let hexes: [RGB]; let textRemainder: String }
    static func parse(_ raw: String) -> Parsed
}
```

- Splits `raw` on whitespace and commas (the copy format is comma+space separated).
- A token is a **hex token** when it matches `#?[0-9a-fA-F]{6}` or the 3-digit shorthand `#?[0-9a-fA-F]{3}` (expanded to 6). Case-insensitive. Decoded via `NamedColor.parse`.
- **Bare-hex guard:** a `#`-less token is only treated as hex if it is *exactly* 6 (or 3) hex digits. This is the one false-positive risk (e.g. a literal filename token `c0ffee` would read as a color) — accepted because (a) the copy path always includes `#`, so the common case is unambiguous, and (b) worst case a rare all-hex-digit word matches on color instead of text, never a crash. Tokens with a leading `#` are unambiguous.
- Non-hex tokens are re-joined (in original order) into `textRemainder`, which is fed to the existing pipeline verbatim. A pure-hex query yields an empty `textRemainder`.

### 2.2 `LabColor` / `ColorDistance` — perceptual distance (pure)

```
struct LabColor { let L, a, b: Double
    init(rgb: RGB)                       // sRGB → linear → XYZ (D65) → LAB
}
enum ColorDistance {
    static func deltaE(_ x: LabColor, _ y: LabColor) -> Double   // CIE76 (Euclidean in LAB)
    static let nearThreshold: Double = 25   // TUNE during implementation
}
```

- **CIE76** (plain Euclidean distance in LAB) for v1 — simplest correct-enough metric. CIEDE2000 is a drop-in future upgrade behind the same `deltaE` seam; not needed for v1.
- `nearThreshold` is a single internal constant, **not** a user setting. The starting value (≈25 ΔE76) is a first guess to be tuned against real images during implementation.

### 2.3 `PaletteMatch` — does a file's palette satisfy the query? (pure)

```
enum PaletteMatch {
    /// A file matches iff EACH query color has a palette color within threshold (AND).
    static func matches(query: [LabColor], palette: [LabColor], threshold: Double) -> Bool
    /// Aggregate closeness for ranking a color-only query (lower = closer):
    /// sum over query colors of the nearest palette ΔE.
    static func score(query: [LabColor], palette: [LabColor]) -> Double
}
```

- **AND semantics:** every queried color must have a near-match in the file's palette. This mirrors how the multi-tag filter already ANDs, and it is what "find images with this palette" means. (If AND proves too strict against real libraries, loosening to "most colors" is a threshold change here, not an architecture change — but ship AND first.)

### 2.4 Integration in `SearchService.search`

At the top of `search`, before building `escaped`:

```
let cq = ColorQuery.parse(trimmed)
```

Then two cases, both inside the existing `queue.read`:

- **`cq.hexes` empty** → unchanged. Existing behavior, byte for byte.
- **`cq.hexes` non-empty** → compute the set of file IDs whose palette matches all query colors:
  - `SELECT id, palette FROM files WHERE palette IS NOT NULL` → decode each JSON palette → `[LabColor]` → `PaletteMatch.matches`. Collect matching IDs.
  - **If `cq.textRemainder` is non-empty:** run the existing text/tag/note/semantic pipeline on `textRemainder`, then **intersect** its `exactIDs`/semantic results with the color-matched IDs (color acts as an additional filter; text ranking preserved).
  - **If `cq.textRemainder` is empty (color-only query):** the result *is* the color-matched IDs, **ranked by `PaletteMatch.score` ascending** (closest palette first).
- Resolve IDs → alive paths exactly as today (`paths … is_alive = 1`), then apply the existing scope filter (`.currentFolder` prefix guard / `.everywhere`) unchanged.

**Scope note:** the color path respects the same All / This-Folder scope as the rest of search, for free, because it produces IDs that flow through the same path-resolution + scope filter.

---

## 3. Performance

- Palette matching is an **O(analyzed-files)** scan: one `SELECT` of `(id, palette)`, then per row a JSON decode of ≤6 short strings + ≤6×(query-count) `deltaE` calls. This is cheap per row; a few thousand files is well within the existing debounced-search budget (the scan runs in the same off-main `queue.read` that already does FTS + semantic cosine scoring).
- If a very large library ever makes this scan too slow, the future optimization is to **pre-filter by `dominant_color`** (already indexed by smart-sort) or bucket palettes by hue before the ΔE pass — a change isolated to §2.4, no UX impact. **Not built in v1** (YAGNI); measure first.
- LAB conversion of the (≤ a handful of) query colors happens once per search, not per row.

---

## 4. Edge cases

- **3-digit hex** (`#f0c`) → expanded to `#ff00cc` before parse.
- **Invalid hex** (`#12`, `#gggggg`) → not a hex token → falls through to `textRemainder` as ordinary text.
- **Mixed query** (`red #f0e0c0`) → `red` stays text (matches the color *tag*), `#f0e0c0` is a color filter; results are the intersection.
- **Only stopwords + a hex** → `textRemainder` may be empty after the existing stopword handling, but the hex still drives a color-only ranked result.
- **File with no palette** (not yet analyzed, or a non-image kind) → excluded from color matches (its `palette` is `NULL`). Color search only surfaces analyzed images, by definition.
- **Case** — hex parsing is case-insensitive; the stored palette is lowercase `#rrggbb`.

---

## 5. Localization

Nothing new to localize. Hex tokens are language-neutral; color *names* already localize through the existing tag/vocabulary path (`ColorTagger` + `VocabularyLocalizer`). No user-facing strings are added.

---

## 6. Testing (pure units)

- **`ColorQueryTests`** — token classification: `#`-prefixed, bare-6, 3-digit expand, invalid→text, comma+space splitting, mixed hex/text, order preservation of `textRemainder`, empty remainder for pure-hex.
- **`ColorDistanceTests`** — RGB→LAB known values (white/black/mid-grey/primaries), ΔE symmetry, self-distance 0, threshold boundary.
- **`PaletteMatchTests`** — AND semantics (all-present matches, one-missing fails), `score` ordering (closer palette ranks first), empty palette never matches, single vs multi query color.

No UI test (search-field wiring is view code); the parse→match→rank logic is fully covered by the pure units.

---

## 7. Open items

None blocking. The `nearThreshold` value is the only tuning knob and is settled during implementation against real images.
