# Color Search (hex in the search bar) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the existing search field match by hex color (single or multiple), matched perceptually against each analyzed file's stored `palette`, with zero new UI.

**Architecture:** Three pure, unit-tested value types — `ColorQuery` (pull hex tokens out of the query), `LabColor`/`ColorDistance` (perceptual ΔE in LAB), `PaletteMatch` (does a file's palette satisfy all query colors, and how close) — plus one integration point in `SearchService.search`, where color-matched file IDs flow through the same path-resolution + scope filter the text pipeline already uses.

**Tech Stack:** Swift, GRDB (SQLite), XCTest. macOS app (SwiftUI). No new dependencies, no schema change.

## Global Constraints

- **No schema change.** `files.palette` (a JSON `[String]` of `#rrggbb`, ≤6, share-descending) already exists and is populated by the analyze pass. Do not add columns.
- **No new UI, no new persisted state.** Text bar only; a color query is transient like any other search.
- **No change to color-*name* search.** `red`/`blue`/… already match as tags via `ColorTagger`; this path is untouched.
- **Storage stays canonical-English; nothing new to localize.** Hex tokens are language-neutral; no user-facing strings are added.
- **Pure logic is unit-tested; the search-field wiring is view/integration code (no unit test), verified by build + real-app run.**
- **Preserve today's search byte-for-byte when the query carries no hex** — the color path must be inert for `red`, `red blue`, plain filename queries, etc.
- **Palette decode is CIE76 v1** — plain Euclidean ΔE in LAB; `nearThreshold ≈ 25`, a single internal constant, tuned during implementation. CIEDE2000 is a future drop-in behind the same `deltaE` seam; not built now (YAGNI).
- **Test target is `MuseTests`, scheme is `Muse`.** New files under `Muse/Muse/…` and `Muse/MuseTests/` auto-join their target (file-system-synchronized groups) — no `project.pbxproj` edits.

**Build/test command (macOS destination required):**
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' \
  test -only-testing:MuseTests/<TestClass> 2>&1 | tail -25
```

---

### Task 1: `LabColor` + `ColorDistance` — perceptual distance (pure)

Creates the shared `ColorSearch.swift` file with the `RGB` value type, the sRGB→LAB conversion, and the ΔE metric. Tasks 2 and 3 append to this same file.

**Files:**
- Create: `Muse/Muse/Intelligence/Core/ColorSearch.swift`
- Test: `Muse/MuseTests/ColorDistanceTests.swift`

**Interfaces:**
- Produces:
  - `struct RGB: Equatable { let r, g, b: Double }` — components in 0…1.
  - `struct LabColor: Equatable { let L, a, b: Double; init(L:a:b:); init(rgb: RGB) }`
  - `enum ColorDistance { static func deltaE(_:_:) -> Double; static let nearThreshold: Double }`
- Consumes: nothing.

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/ColorDistanceTests.swift`:

```swift
import XCTest
@testable import Muse

final class ColorDistanceTests: XCTestCase {

    func testWhiteIsL100() {
        let lab = LabColor(rgb: RGB(r: 1, g: 1, b: 1))
        XCTAssertEqual(lab.L, 100, accuracy: 0.5)
        XCTAssertEqual(lab.a, 0, accuracy: 0.5)
        XCTAssertEqual(lab.b, 0, accuracy: 0.5)
    }

    func testBlackIsL0() {
        let lab = LabColor(rgb: RGB(r: 0, g: 0, b: 0))
        XCTAssertEqual(lab.L, 0, accuracy: 0.5)
        XCTAssertEqual(lab.a, 0, accuracy: 0.5)
        XCTAssertEqual(lab.b, 0, accuracy: 0.5)
    }

    func testMidGreyIsNeutralMidL() {
        let lab = LabColor(rgb: RGB(r: 0.5, g: 0.5, b: 0.5))
        XCTAssertEqual(lab.a, 0, accuracy: 0.5)   // grey has no chroma
        XCTAssertEqual(lab.b, 0, accuracy: 0.5)
        XCTAssertTrue(lab.L > 45 && lab.L < 60, "mid grey L≈53, got \(lab.L)")
    }

    func testSelfDistanceIsZero() {
        let red = LabColor(rgb: RGB(r: 1, g: 0, b: 0))
        XCTAssertEqual(ColorDistance.deltaE(red, red), 0, accuracy: 0.0001)
    }

    func testDistanceIsSymmetric() {
        let red = LabColor(rgb: RGB(r: 1, g: 0, b: 0))
        let green = LabColor(rgb: RGB(r: 0, g: 1, b: 0))
        XCTAssertEqual(ColorDistance.deltaE(red, green),
                       ColorDistance.deltaE(green, red), accuracy: 0.0001)
    }

    func testPrimariesAreFarApart() {
        let red = LabColor(rgb: RGB(r: 1, g: 0, b: 0))
        let blue = LabColor(rgb: RGB(r: 0, g: 0, b: 1))
        // Distinct primaries are well past the "near" threshold.
        XCTAssertGreaterThan(ColorDistance.deltaE(red, blue), ColorDistance.nearThreshold)
    }

    func testNearThresholdIsPositive() {
        XCTAssertGreaterThan(ColorDistance.nearThreshold, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' \
  test -only-testing:MuseTests/ColorDistanceTests 2>&1 | tail -25
```
Expected: FAIL — `Cannot find 'LabColor'/'RGB'/'ColorDistance' in scope` (compile error).

- [ ] **Step 3: Write minimal implementation**

Create `Muse/Muse/Intelligence/Core/ColorSearch.swift`:

```swift
//
//  ColorSearch.swift
//  Muse
//
//  Pure logic for matching search queries by color. A hex token in the
//  search bar (`#3a7bd5`, or a pasted `#3a7bd5, #f0e0c0, #202020` from the
//  hero COLORS card) is matched perceptually — LAB distance, "near" not
//  "exact" — against each analyzed file's stored `palette`.
//
//  Three units, all pure + unit-tested:
//    • ColorQuery   — pull hex tokens out of the query string.
//    • LabColor / ColorDistance — sRGB → LAB + CIE76 ΔE.
//    • PaletteMatch — does a file's palette satisfy every query color (AND)?
//
//  SearchService.search is the single integration point.
//

import Foundation

/// An sRGB color, components in 0…1.
struct RGB: Equatable {
    let r, g, b: Double
}

/// A color in CIE L*a*b* (D65). Perceptually near-uniform, so Euclidean
/// distance here is a reasonable "how different do these look" metric.
struct LabColor: Equatable {
    let L, a, b: Double

    init(L: Double, a: Double, b: Double) {
        self.L = L; self.a = a; self.b = b
    }

    init(rgb: RGB) {
        // sRGB companding → linear light.
        func lin(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = lin(rgb.r), g = lin(rgb.g), b = lin(rgb.b)

        // linear sRGB → XYZ (D65).
        let x = r * 0.4124564 + g * 0.3575761 + b * 0.1804375
        let y = r * 0.2126729 + g * 0.7151522 + b * 0.0721750
        let z = r * 0.0193339 + g * 0.1191920 + b * 0.9503041

        // Normalize by the D65 reference white.
        let xn = x / 0.95047, yn = y / 1.00000, zn = z / 1.08883
        func f(_ t: Double) -> Double {
            t > 0.008856 ? pow(t, 1.0 / 3.0) : (7.787 * t) + (16.0 / 116.0)
        }
        let fx = f(xn), fy = f(yn), fz = f(zn)

        self.L = (116.0 * fy) - 16.0
        self.a = 500.0 * (fx - fy)
        self.b = 200.0 * (fy - fz)
    }
}

enum ColorDistance {
    /// CIE76 — plain Euclidean distance in LAB. Correct-enough for v1;
    /// CIEDE2000 is a drop-in upgrade behind this same signature later.
    static func deltaE(_ x: LabColor, _ y: LabColor) -> Double {
        let dL = x.L - y.L, da = x.a - y.a, db = x.b - y.b
        return (dL * dL + da * da + db * db).squareRoot()
    }

    /// "Near" cutoff (ΔE76). A single internal constant, NOT a user setting.
    /// ≈25 is a first guess, tuned against real images during implementation.
    static let nearThreshold: Double = 25
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' \
  test -only-testing:MuseTests/ColorDistanceTests 2>&1 | tail -25
```
Expected: PASS — `** TEST SUCCEEDED **`, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Intelligence/Core/ColorSearch.swift" "Muse/MuseTests/ColorDistanceTests.swift"
git commit -m "feat: LAB color distance for color search (pure)"
```

---

### Task 2: `ColorQuery` — token classification (pure)

Splits the raw query on whitespace/commas, pulls out hex tokens (decoded to `RGB`), and re-joins the rest as `textRemainder`.

**Files:**
- Modify: `Muse/Muse/Intelligence/Core/ColorSearch.swift` (append `ColorQuery`)
- Test: `Muse/MuseTests/ColorQueryTests.swift`

**Interfaces:**
- Consumes: `RGB` (Task 1), `NamedColor.parse(_:) -> (Double, Double, Double)?` (existing, `NamedColor.swift:66` — decodes **6-digit** hex only; 3-digit expansion is done here first).
- Produces:
  - `enum ColorQuery { struct Parsed: Equatable { let hexes: [RGB]; let textRemainder: String }; static func parse(_ raw: String) -> Parsed }`

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/ColorQueryTests.swift`:

```swift
import XCTest
@testable import Muse

final class ColorQueryTests: XCTestCase {

    func testHashPrefixedHexIsColor() {
        let p = ColorQuery.parse("#3a7bd5")
        XCTAssertEqual(p.hexes.count, 1)
        XCTAssertEqual(p.textRemainder, "")
        // #3a7bd5 → (58, 123, 213)/255
        XCTAssertEqual(p.hexes[0].r, 58.0 / 255, accuracy: 0.001)
        XCTAssertEqual(p.hexes[0].g, 123.0 / 255, accuracy: 0.001)
        XCTAssertEqual(p.hexes[0].b, 213.0 / 255, accuracy: 0.001)
    }

    func testBareSixDigitHexIsColor() {
        let p = ColorQuery.parse("3a7bd5")
        XCTAssertEqual(p.hexes.count, 1)
        XCTAssertEqual(p.textRemainder, "")
    }

    func testThreeDigitShorthandExpands() {
        // #f0c → #ff00cc
        let p = ColorQuery.parse("#f0c")
        XCTAssertEqual(p.hexes.count, 1)
        XCTAssertEqual(p.hexes[0].r, 1.0, accuracy: 0.001)
        XCTAssertEqual(p.hexes[0].g, 0.0, accuracy: 0.001)
        XCTAssertEqual(p.hexes[0].b, 0xcc / 255.0, accuracy: 0.001)
    }

    func testInvalidHexFallsThroughToText() {
        // Too short, and a non-hex char — both stay text.
        let p = ColorQuery.parse("#12 #gggggg")
        XCTAssertTrue(p.hexes.isEmpty)
        XCTAssertEqual(p.textRemainder, "#12 #gggggg")
    }

    func testCommaSpaceSplittingMultiHex() {
        // The exact string the COLORS card writes to the clipboard.
        let p = ColorQuery.parse("#3a7bd5, #f0e0c0, #202020")
        XCTAssertEqual(p.hexes.count, 3)
        XCTAssertEqual(p.textRemainder, "")
    }

    func testMixedHexAndTextSplits() {
        let p = ColorQuery.parse("red #f0e0c0")
        XCTAssertEqual(p.hexes.count, 1)
        XCTAssertEqual(p.textRemainder, "red")
    }

    func testTextRemainderPreservesOrder() {
        let p = ColorQuery.parse("white #202020 wedding dress")
        XCTAssertEqual(p.hexes.count, 1)
        XCTAssertEqual(p.textRemainder, "white wedding dress")
    }

    func testPlainTextHasNoHexes() {
        let p = ColorQuery.parse("red blue")
        XCTAssertTrue(p.hexes.isEmpty)
        XCTAssertEqual(p.textRemainder, "red blue")
    }

    func testCaseInsensitiveHex() {
        let p = ColorQuery.parse("#3A7BD5")
        XCTAssertEqual(p.hexes.count, 1)
        XCTAssertEqual(p.textRemainder, "")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' \
  test -only-testing:MuseTests/ColorQueryTests 2>&1 | tail -25
```
Expected: FAIL — `Cannot find 'ColorQuery' in scope`.

- [ ] **Step 3: Write minimal implementation**

Append to `Muse/Muse/Intelligence/Core/ColorSearch.swift`:

```swift

/// Classifies a raw search string into color tokens + a text remainder.
/// A hex token is `#?` followed by exactly 3 or 6 hex digits (3-digit
/// shorthand expands to 6). Everything else is re-joined, in order, as text
/// and flows through the existing search pipeline verbatim.
///
/// Bare-hex guard: a `#`-less token is treated as a color only when it is
/// *exactly* 6 (or 3) hex digits. This is the one accepted false-positive
/// (a literal all-hex-digit word like `c0ffee`, or a 3-letter word like
/// `bad`, reads as a color) — accepted because the copy path from the COLORS
/// card always includes `#`, so the common case is unambiguous, and the
/// worst case is a wrong axis, never a crash.
enum ColorQuery {
    struct Parsed: Equatable {
        let hexes: [RGB]
        let textRemainder: String
    }

    static func parse(_ raw: String) -> Parsed {
        // Split on whitespace AND commas (the card copies ", "-separated).
        let tokens = raw
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
            .filter { !$0.isEmpty }

        var hexes: [RGB] = []
        var textTokens: [String] = []
        for token in tokens {
            if let rgb = hexRGB(token) {
                hexes.append(rgb)
            } else {
                textTokens.append(token)
            }
        }
        return Parsed(hexes: hexes, textRemainder: textTokens.joined(separator: " "))
    }

    private static let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

    private static func hexRGB(_ token: String) -> RGB? {
        var s = token
        if s.hasPrefix("#") { s.removeFirst() }
        guard !s.isEmpty,
              s.unicodeScalars.allSatisfy({ hexDigits.contains($0) }) else { return nil }
        // 3-digit shorthand → 6 (NamedColor.parse decodes 6 only).
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6, let (r, g, b) = NamedColor.parse(s) else { return nil }
        return RGB(r: r, g: g, b: b)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' \
  test -only-testing:MuseTests/ColorQueryTests 2>&1 | tail -25
```
Expected: PASS — 9 tests.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Intelligence/Core/ColorSearch.swift" "Muse/MuseTests/ColorQueryTests.swift"
git commit -m "feat: ColorQuery hex-token parser for color search (pure)"
```

---

### Task 3: `PaletteMatch` — palette satisfaction + ranking (pure)

Does a file's palette contain a near-match for *every* query color (AND), and how close overall (for color-only ranking).

**Files:**
- Modify: `Muse/Muse/Intelligence/Core/ColorSearch.swift` (append `PaletteMatch`)
- Test: `Muse/MuseTests/PaletteMatchTests.swift`

**Interfaces:**
- Consumes: `LabColor`, `ColorDistance` (Task 1).
- Produces:
  - `enum PaletteMatch { static func matches(query: [LabColor], palette: [LabColor], threshold: Double) -> Bool; static func score(query: [LabColor], palette: [LabColor]) -> Double }`

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/PaletteMatchTests.swift`:

```swift
import XCTest
@testable import Muse

final class PaletteMatchTests: XCTestCase {

    private let red   = LabColor(rgb: RGB(r: 1, g: 0, b: 0))
    private let green = LabColor(rgb: RGB(r: 0, g: 1, b: 0))
    private let blue  = LabColor(rgb: RGB(r: 0, g: 0, b: 1))
    private let threshold = ColorDistance.nearThreshold

    func testSingleColorPresentMatches() {
        XCTAssertTrue(PaletteMatch.matches(query: [red],
                                           palette: [red, green], threshold: threshold))
    }

    func testSingleColorAbsentFails() {
        XCTAssertFalse(PaletteMatch.matches(query: [blue],
                                            palette: [red, green], threshold: threshold))
    }

    func testAllColorsPresentMatches() {
        XCTAssertTrue(PaletteMatch.matches(query: [red, blue],
                                           palette: [red, green, blue], threshold: threshold))
    }

    func testOneColorMissingFailsAND() {
        // red present, blue absent → AND fails.
        XCTAssertFalse(PaletteMatch.matches(query: [red, blue],
                                            palette: [red, green], threshold: threshold))
    }

    func testEmptyPaletteNeverMatches() {
        XCTAssertFalse(PaletteMatch.matches(query: [red],
                                            palette: [], threshold: threshold))
    }

    func testNearButNotExactStillMatches() {
        // A slightly-off red is within threshold.
        let nearRed = LabColor(rgb: RGB(r: 0.95, g: 0.05, b: 0.05))
        XCTAssertTrue(PaletteMatch.matches(query: [red],
                                           palette: [nearRed], threshold: threshold))
    }

    func testScoreRanksCloserPaletteFirst() {
        let exact = PaletteMatch.score(query: [red], palette: [red, green])
        let off = PaletteMatch.score(
            query: [red],
            palette: [LabColor(rgb: RGB(r: 0.8, g: 0.1, b: 0.1)), green])
        XCTAssertLessThan(exact, off)
    }

    func testScoreEmptyPaletteIsInfinite() {
        XCTAssertEqual(PaletteMatch.score(query: [red], palette: []), .infinity)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' \
  test -only-testing:MuseTests/PaletteMatchTests 2>&1 | tail -25
```
Expected: FAIL — `Cannot find 'PaletteMatch' in scope`.

- [ ] **Step 3: Write minimal implementation**

Append to `Muse/Muse/Intelligence/Core/ColorSearch.swift`:

```swift

/// Decides whether a file's palette satisfies a color query, and scores how
/// closely — the matching + ranking core for the color search path.
enum PaletteMatch {
    /// AND semantics: a file matches iff EACH query color has some palette
    /// color within `threshold`. Mirrors the multi-tag filter's AND, and is
    /// what "find images with this palette" means. An empty palette never
    /// matches (a not-yet-analyzed / non-image file has no color to match).
    static func matches(query: [LabColor], palette: [LabColor], threshold: Double) -> Bool {
        guard !palette.isEmpty else { return false }
        return query.allSatisfy { q in
            palette.contains { ColorDistance.deltaE(q, $0) <= threshold }
        }
    }

    /// Aggregate closeness for ranking a color-only query (lower = closer):
    /// the sum over query colors of the nearest palette ΔE. Empty palette
    /// scores `.infinity` so it sorts last.
    static func score(query: [LabColor], palette: [LabColor]) -> Double {
        guard !palette.isEmpty else { return .infinity }
        return query.reduce(0.0) { acc, q in
            let nearest = palette.map { ColorDistance.deltaE(q, $0) }.min() ?? .infinity
            return acc + nearest
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' \
  test -only-testing:MuseTests/PaletteMatchTests 2>&1 | tail -25
```
Expected: PASS — 8 tests.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Intelligence/Core/ColorSearch.swift" "Muse/MuseTests/PaletteMatchTests.swift"
git commit -m "feat: PaletteMatch AND-semantics + ranking for color search (pure)"
```

---

### Task 4: Integrate color matching into `SearchService.search`

Wire the three pure units into the one search entry point. Color-matched IDs flow through the existing path-resolution + scope filter. Extract path-resolution into a helper to keep it DRY (used by both the color-only branch and the text branch).

**Files:**
- Modify: `Muse/Muse/Database/SearchService.swift` (rewrite `search(query:scope:)`, add `aliveePaths` helper)

**Interfaces:**
- Consumes: `ColorQuery.parse` (Task 2), `LabColor(rgb:)` / `ColorDistance.nearThreshold` (Task 1), `PaletteMatch.matches`/`.score` (Task 3), `NamedColor.parse` (existing), `RGB` (Task 1).
- Produces: no new public API — `SearchService.search` keeps its signature and behavior for non-color queries.

- [ ] **Step 1: Replace `search(query:scope:)`**

In `Muse/Muse/Database/SearchService.swift`, replace the entire `search(query:scope:)` method (currently lines 21–134) with:

```swift
    static func search(query: String, scope: SearchScope) async -> [FileNode] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let queue = Database.shared.dbQueue else { return [] }

        // Pull any hex color tokens out of the query. Non-hex tokens (incl.
        // color *names* like "red", which are already tags) stay as text and
        // flow through the pipeline unchanged. A query with no hex is inert
        // on the color path — identical to today's behavior.
        let cq = ColorQuery.parse(trimmed)
        let colorQuery: [LabColor] = cq.hexes.map { LabColor(rgb: $0) }
        let textQuery = colorQuery.isEmpty ? trimmed : cq.textRemainder
        let hasText = !textQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let escaped = ftsEscape(textQuery)
        // Embed the query here on the main actor (the registry is @MainActor);
        // the off-main DB scan below only does cosine scoring on this vector.
        let queryVector = hasText ? IntelligenceRegistry.shared.embedder?.embed(textQuery) : nil

        let absPaths: [String] = (try? await queue.read { db -> [String] in
            // Color filter: IDs whose palette matches EVERY query color (AND),
            // plus a closeness score for color-only ranking. Only when the
            // query actually carries a hex token.
            var colorIDs: Set<String>? = nil
            var colorScore: [String: Double] = [:]
            if !colorQuery.isEmpty {
                var ids = Set<String>()
                let rows = try Row.fetchAll(
                    db, sql: "SELECT id, palette FROM files WHERE palette IS NOT NULL")
                for row in rows {
                    guard let id = row["id"] as String?,
                          let json = row["palette"] as String?,
                          let data = json.data(using: .utf8),
                          let hexes = try? JSONDecoder().decode([String].self, from: data)
                    else { continue }
                    let palette: [LabColor] = hexes.compactMap { hex in
                        NamedColor.parse(hex).map { LabColor(rgb: RGB(r: $0.0, g: $0.1, b: $0.2)) }
                    }
                    guard !palette.isEmpty else { continue }
                    if PaletteMatch.matches(query: colorQuery, palette: palette,
                                            threshold: ColorDistance.nearThreshold) {
                        ids.insert(id)
                        colorScore[id] = PaletteMatch.score(query: colorQuery, palette: palette)
                    }
                }
                colorIDs = ids
            }

            // Color-only query (no text remainder) → rank by palette closeness
            // (closest first), resolve, return.
            if !colorQuery.isEmpty && !hasText {
                let ranked = (colorIDs ?? []).sorted {
                    (colorScore[$0] ?? .infinity) < (colorScore[$1] ?? .infinity)
                }
                return try aliveePaths(for: ranked, db: db)
            }

            // --- Existing text pipeline, now driven by textQuery ---
            // 1) FTS5 hits
            let ftsRows = try Row.fetchAll(
                db,
                sql: "SELECT file_id FROM files_fts WHERE files_fts MATCH ?",
                arguments: [escaped]
            )
            let ftsIDs = ftsRows.compactMap { $0["file_id"] as String? }

            // 2) Tag label matches (for indexed content). Bridge a localized
            //    query to its canonical vision term so e.g. "plage" finds files
            //    tagged canonical "beach"; the raw query is always included so
            //    French filenames/OCR/manual tags still match.
            let tagTerms = SearchBridge.tagSearchTerms(for: textQuery) {
                VocabularyLocalizer.shared.canonicalize($0)
            }
            let tagFilter = tagTerms
                .map { TagRow.Columns.label.like("%" + $0 + "%") }
                .joined(operator: .or)
            let tagIDs = try TagRow
                .filter(tagFilter)
                .fetchAll(db)
                .map { $0.file_id }

            // 2b) Note substring matches (per (file_id, parent_dir), LIKE — notes
            //     are not in FTS). Uses the raw text query, same as basename/OCR.
            let noteIDs = try NoteStore.searchIDs(term: textQuery, db: db)

            // Exact hits, ordered: FTS5 result order first, then tag matches
            // not already included, in their query order.
            var exactSeen = Set<String>()
            var exactIDs: [String] = []
            for id in ftsIDs + tagIDs + noteIDs where !exactSeen.contains(id) {
                exactIDs.append(id); exactSeen.insert(id)
            }

            // 3) Semantic hits (embedding cosine similarity), merged after
            // exact hits — exact first, semantic by descending similarity.
            let semantic = (queryVector.flatMap {
                try? SemanticSearch.semanticIDs(queryVector: $0, db: db)
            }) ?? []
            var orderedIDs = SemanticSearch.merge(
                exactIDs: exactIDs, semantic: semantic, threshold: 0.45)

            // Color, when present alongside text, is an additional AND filter
            // over the text results (text ranking preserved).
            if let colorIDs {
                orderedIDs = orderedIDs.filter { colorIDs.contains($0) }
            }
            guard !orderedIDs.isEmpty else { return [] }

            return try aliveePaths(for: orderedIDs, db: db)
        }) ?? []

        // Filter by scope
        let scopedPaths: [String]
        switch scope {
        case .currentFolder(let url):
            // Match the folder itself or its descendants — guard with a trailing
            // separator so a sibling like "/a/Inspo Extra" doesn't match
            // "/a/Inspo" (the rest of the codebase uses this same `+ "/"` rule).
            let prefix = url.standardizedFileURL.path
            scopedPaths = absPaths.filter { $0 == prefix || $0.hasPrefix(prefix + "/") }
        case .everywhere:
            scopedPaths = absPaths
        }

        // Ranked results (exact-then-semantic, or color-closeness) keep order.
        let ranked: [FileNode] = scopedPaths.map { FileNode(url: URL(fileURLWithPath: $0)) }

        // Also do a basename substring match on enumerated files (so search
        // works even when files aren't indexed yet, scoped to current folder).
        // Skipped for color queries: an unindexed file has no palette, so it
        // can never satisfy a color filter — color search only surfaces
        // analyzed images.
        var extras: [FileNode] = []
        if case .currentFolder(let url) = scope, colorQuery.isEmpty {
            let lower = trimmed.lowercased()
            let rankedPaths = Set(ranked.map { $0.url.standardizedFileURL })
            extras = await Task.detached(priority: .userInitiated) { () -> [FileNode] in
                var out: [FileNode] = []
                var seen = Set<URL>()
                for f in FolderReader.files(in: url, showHidden: false) {
                    let std = f.url.standardizedFileURL
                    if f.basename.lowercased().contains(lower),
                       !rankedPaths.contains(std), !seen.contains(std) {
                        out.append(f)
                        seen.insert(std)
                    }
                }
                return out
            }.value
        }

        return ranked + extras.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    /// Resolve ranked file IDs to their alive absolute paths, preserving the
    /// input order. Shared by the color-only and text search branches.
    private static func aliveePaths(for orderedIDs: [String], db: GRDB.Database) throws -> [String] {
        guard !orderedIDs.isEmpty else { return [] }
        let placeholders = orderedIDs.map { _ in "?" }.joined(separator: ",")
        let pathRows = try PathRow.fetchAll(
            db,
            sql: "SELECT * FROM paths WHERE file_id IN (\(placeholders)) AND is_alive = 1",
            arguments: StatementArguments(orderedIDs)
        )
        var pathsByID: [String: [String]] = [:]
        for row in pathRows {
            guard let fid = row.file_id else { continue }
            pathsByID[fid, default: []].append(row.absolute_path)
        }
        return orderedIDs.flatMap { pathsByID[$0] ?? [] }
    }
```

- [ ] **Step 2: Build the whole app to verify it compiles**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' \
  build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`. (SourceKit "cannot find type" errors in-editor are noise per CLAUDE.md — only the build verdict counts.)

- [ ] **Step 3: Run the full pure-unit suite to confirm no regression**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' \
  test -only-testing:MuseTests/ColorDistanceTests \
       -only-testing:MuseTests/ColorQueryTests \
       -only-testing:MuseTests/PaletteMatchTests \
       -only-testing:MuseTests/SearchMergeTests 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **` (color units + the existing search-merge test still green).

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Database/SearchService.swift"
git commit -m "feat: match search by hex color against file palettes"
```

---

### Task 5: Runtime verification + threshold tuning

Pure tests and a green build don't prove the feature works in the running app (per the "verify runtime, not just tests" rule). Drive the real gesture and tune `nearThreshold` against real images.

**Files:**
- Possibly modify: `Muse/Muse/Intelligence/Core/ColorSearch.swift` (`ColorDistance.nearThreshold` value only)

- [ ] **Step 1: Launch the app on a folder with analyzed images**

Use the `run` skill (or Xcode Cmd+R) to build & launch Muse. Point it at a folder that has already been analyzed (palettes populated). Confirm the app launches without crash.

- [ ] **Step 2: Verify the single-hex path**

Open a colorful image in the hero viewer, note a dominant color, type its hex (e.g. `#c0392b`) into the search field. Confirm the grid returns images that visibly contain that color, scoped correctly by the All / This-Folder toggle.

- [ ] **Step 3: Verify the paste-from-card gesture (the headline case)**

In the hero viewer's COLORS card, press "Copy all colors" (writes e.g. `#3a7bd5, #f0e0c0, #202020`). Paste into the search field. Confirm results are images whose palette contains a near-match for ALL three colors, ranked closest-first, and that clearing the search restores the normal grid.

- [ ] **Step 4: Verify non-color search is unchanged**

Search `red`, then `red blue`, then a filename fragment. Confirm each behaves exactly as before (color names still match as tags; filename substring still finds unindexed files).

- [ ] **Step 5: Tune `nearThreshold` if needed**

If Step 2/3 return too few results (over-strict) or too many unrelated ones (over-loose), adjust `ColorDistance.nearThreshold` in `ColorSearch.swift` (try 20 for stricter, 30–35 for looser), rebuild, and re-check Steps 2–3. Land on a value where the paste-from-card gesture returns the visually-right set.

- [ ] **Step 6: Commit any tuning change**

```bash
git add "Muse/Muse/Intelligence/Core/ColorSearch.swift"
git commit -m "chore: tune color-search near threshold against real images"
```

(Skip this commit if the threshold was left at 25.)

---

## Notes / accepted risks

- **Bare 3-digit false positive.** Per spec §2.1, a bare (no-`#`) token of exactly 3 hex digits (`abc`, `bad`, `fad`, …) parses as a color. This is more collision-prone than the bare-6 case. Implemented per the approved spec; if it proves annoying in real use, the one-line fix is to require `#` for 3-digit shorthand in `ColorQuery.hexRGB` (bare tokens then need 6 digits). Not changing it now — flag to owner during Task 5 verification.
- **Performance.** The color filter is an O(analyzed-files) scan (`SELECT id, palette … WHERE palette IS NOT NULL`) inside the existing off-main `queue.read`; cheap per row (≤6 short JSON strings + ≤6×queryCount ΔE). No pre-filter/bucketing in v1 (YAGNI) — measure first if a very large library ever janks.

## Self-Review

- **Spec coverage:** §2.1 ColorQuery → Task 2; §2.2 LabColor/ColorDistance → Task 1; §2.3 PaletteMatch → Task 3; §2.4 integration → Task 4; §3 performance (no pre-filter, measure first) → honored in Task 4 + Notes; §4 edge cases (3-digit, invalid, mixed, empty-remainder color-only, no-palette excluded, case) → covered by ColorQueryTests + the `WHERE palette IS NOT NULL` filter + the color-only branch; §5 localization (nothing new) → Global Constraints; §6 testing (three pure test classes) → Tasks 1–3; §7 threshold tuning → Task 5.
- **Placeholder scan:** none — every code step shows complete code, every command shows its expected verdict.
- **Type consistency:** `RGB`, `LabColor(rgb:)`, `ColorDistance.deltaE`/`.nearThreshold`, `ColorQuery.parse`/`Parsed{hexes,textRemainder}`, `PaletteMatch.matches`/`.score`, `aliveePaths(for:db:)` are used with identical signatures across Tasks 1–4. `NamedColor.parse` returns a `(Double,Double,Double)?` tuple (verified) and is adapted to `RGB` at both call sites (ColorQuery and SearchService).
