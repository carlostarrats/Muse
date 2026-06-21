# Localization (French v1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Muse display in the user's macOS language (French in v1), localizing both the app's UI chrome and the AI-generated tags, with no stored-data changes and clean removability.

**Architecture:** Localization is a *display-time* layer. Stored data (DB tags, FTS, collection rows) stays canonical-English. UI chrome localizes via a String Catalog (inline English literals stay as keys). AI-tag labels localize through one isolated `VocabularyLocalizer` seam (forward `display` for rendering, reverse `canonicalize` for search), fed by a bundled `VisionVocabulary.json` generated from Vision's known taxonomy.

**Tech Stack:** Swift 5/SwiftUI, GRDB (SQLite), Apple Vision (`VNClassifyImageRequest`), Xcode String Catalog (`.xcstrings`), XCTest.

## Global Constraints

- **Min macOS 14.6.** String Catalogs compile back cleanly; `String(localized:)` is macOS 12+. OK. Copy these values verbatim into any new `@available` reasoning.
- **No network in the shipped app** (update-only/Sparkle). All translation is generated at build/authoring time and bundled. No runtime translation API.
- **No DB schema change / no migration.** Tag storage stays canonical-English. `TagRow.label` remains the canonical identity; `UNIQUE(file_id, parent_dir, label)` unchanged.
- **Internals stay canonical.** `AppState.activeTagLabels`, chip-count dictionaries, the multi-tag intersection, grid `.id`/`gridSignature`, all DB queries, and all tag *actions* (set/toggle/rename/delete/tap) operate on canonical labels. Localization changes ONLY rendered strings.
- **Identity fallback.** `VocabularyLocalizer.display`/`canonicalize` are identity for English and for any unknown term, so manual/user tags and untranslated vision terms pass through unchanged.
- **Tests:** pure logic is unit-tested (`Muse/MuseTests`); SwiftUI views are NOT unit-tested (repo convention). New value types that are read from nonisolated tests must be declared `nonisolated` (module default actor isolation is MainActor).
- **Build/test commands** (run from repo root):
  - Build: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
  - Full tests: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test`
  - One test class: append `-only-testing:MuseTests/<ClassName>`
- **Commit cadence:** one commit per task (TDD: failing test → impl → passing → commit). Use the repo's commit trailer convention.

---

## File structure (created / modified)

- **Create** `Muse/Muse/Localization/VocabularyLocalizer.swift` — the AI-tag localization seam (forward + reverse + bundled loader). One responsibility.
- **Create** `Muse/Muse/Localization/VisionVocabulary.json` — bundled data: `{ canonical: { "fr": term } }`.
- **Create** `Muse/Muse/Database/SearchBridge.swift` — pure helper expanding a query into canonical+raw tag-search terms.
- **Create** `Muse/Muse/Resources/Localizable.xcstrings` — UI-chrome String Catalog (path may be the target root; see Task 1).
- **Create** tests: `Muse/MuseTests/VocabularyLocalizerTests.swift`, `Muse/MuseTests/SearchBridgeTests.swift`, `Muse/MuseTests/TagFallbackNamerLocalizationTests.swift`.
- **Modify** `Muse/Muse.xcodeproj/project.pbxproj` — add `fr` to `knownRegions`; add the catalog + JSON to the target/resources.
- **Modify** `Muse/Muse/Views/TagChipsRow.swift` — localize chip labels, "All", banner pills + VoiceOver banner.
- **Modify** `Muse/Muse/Models/TagSelection.swift` — parameterize banner connective words (back-compatible defaults).
- **Modify** `Muse/Muse/Views/Viewer/ViewerInfoColumn.swift` (+ the shared pill label render in `Views/Viewer/`) — localize displayed tag labels + toasts; keep `PillItem.label` canonical.
- **Modify** `Muse/Muse/Database/SearchService.swift` — OR the tag `LIKE` over `SearchBridge` terms.
- **Modify** `Muse/Muse/Intelligence/Core/CollectionNaming.swift` — FM prompt in-language; fallback namer via `VocabularyLocalizer`.
- **Modify** formatter sites flagged in Task 7 (audit-driven).
- **Modify** ~56 UI files for the chrome sweep (Task 8) — mostly no-ops (literals already auto-localize); explicit `String(localized:)` only where a chrome string flows through a `String` variable.

---

### Task 1: Project config — add French + an empty String Catalog

Enables the `fr` language so `Bundle.main.preferredLocalizations` can resolve to French and the catalog can hold UI translations. No behavior change yet (empty catalog → everything still English).

**Files:**
- Modify: `Muse/Muse.xcodeproj/project.pbxproj` (`knownRegions`, file ref + resources build phase)
- Create: `Muse/Muse/Resources/Localizable.xcstrings`

**Interfaces:**
- Produces: a `fr` known region + an empty `Localizable.xcstrings` in the Muse target's resources. Later tasks rely on `fr` existing for `preferredLocalizations`.

- [ ] **Step 1: Create the empty String Catalog file**

Create `Muse/Muse/Resources/Localizable.xcstrings` with exactly:

```json
{
  "sourceLanguage" : "en",
  "strings" : {
  },
  "version" : "1.0"
}
```

- [ ] **Step 2: Register `fr` and the catalog in the project**

Preferred: open `Muse/Muse.xcodeproj` in Xcode → select the project → Info → Localizations → **+ French**; then File → Add Files → add `Localizable.xcstrings` to the **Muse** target. This edits `project.pbxproj` correctly.

If editing `project.pbxproj` by hand instead: in the `knownRegions` array (currently `( en, Base, )`) add `fr,` so it reads `( en, fr, Base, )`; add a `PBXFileReference` for `Localizable.xcstrings` (lastKnownFileType `text.json.xcstrings`), add it to the Muse group's `children`, and add a `PBXBuildFile` entry into the Muse target's **Resources** `PBXResourcesBuildPhase`.

- [ ] **Step 3: Build**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: build succeeds; the catalog compiles (no strings yet).

- [ ] **Step 4: Verify `fr` is a known localization**

Run: `plutil -p "$(find ~/Library/Developer/Xcode/DerivedData -name Muse.app -path '*Debug*' -print -quit)/Contents/Info.plist" 2>/dev/null | grep -A6 CFBundleLocalizations || echo "check knownRegions in pbxproj"`
Expected: `fr` appears among localizations (or confirm `fr` is in `knownRegions` via `grep -n "knownRegions" -A4 Muse/Muse.xcodeproj/project.pbxproj`).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse.xcodeproj/project.pbxproj Muse/Muse/Resources/Localizable.xcstrings
git commit -m "build(l10n): add French region + empty String Catalog"
```

---

### Task 2: `VocabularyLocalizer` core (pure, fixture-tested)

The isolated AI-tag localization seam. Pure forward/reverse maps; an injectable initializer for tests and an `identity` instance. The bundle loader comes in Task 3.

**Files:**
- Create: `Muse/Muse/Localization/VocabularyLocalizer.swift`
- Test: `Muse/MuseTests/VocabularyLocalizerTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated struct VocabularyLocalizer`
  - `init(forward: [String: String])` — `forward` is canonical→localized (any casing; matched case-insensitively)
  - `static let identity: VocabularyLocalizer`
  - `func display(_ canonical: String) -> String`
  - `func canonicalize(_ token: String) -> String?`

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/VocabularyLocalizerTests.swift`:

```swift
import XCTest
@testable import Muse

final class VocabularyLocalizerTests: XCTestCase {
    private let loc = VocabularyLocalizer(forward: ["beach": "plage", "dog": "chien"])

    func testForwardDisplaysLocalizedTerm() {
        XCTAssertEqual(loc.display("beach"), "plage")
    }
    func testForwardIsCaseInsensitiveOnCanonical() {
        XCTAssertEqual(loc.display("Beach"), "plage")
    }
    func testUnknownTermPassesThroughUnchanged() {
        XCTAssertEqual(loc.display("Q3 Budget"), "Q3 Budget")
    }
    func testIdentityLocalizerReturnsEnglish() {
        XCTAssertEqual(VocabularyLocalizer.identity.display("beach"), "beach")
    }
    func testReverseMapsLocalizedToCanonical() {
        XCTAssertEqual(loc.canonicalize("plage"), "beach")
    }
    func testReverseIsCaseInsensitive() {
        XCTAssertEqual(loc.canonicalize("PLAGE"), "beach")
    }
    func testReverseUnknownReturnsNil() {
        XCTAssertNil(loc.canonicalize("foobar"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/VocabularyLocalizerTests`
Expected: FAIL — `cannot find 'VocabularyLocalizer' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Muse/Muse/Localization/VocabularyLocalizer.swift`:

```swift
//
//  VocabularyLocalizer.swift
//  Muse
//
//  Display-time localization for AI (Vision) tag labels. Tag STORAGE stays
//  canonical-English; this maps canonical -> localized for rendering and
//  localized -> canonical for search. English (or any unknown term) is the
//  identity, so manual/user tags and untranslated vision terms pass through
//  unchanged. Pure value type; `nonisolated` so it's usable from any context
//  (the module's default actor isolation is MainActor).
//

import Foundation

nonisolated struct VocabularyLocalizer {

    /// canonical(lowercased) -> localized term, for ONE language.
    private let forward: [String: String]
    /// localized(lowercased) -> canonical term, built from `forward`.
    private let reverse: [String: String]

    init(forward: [String: String]) {
        var fwd: [String: String] = [:]
        var rev: [String: String] = [:]
        for (canon, local) in forward {
            fwd[canon.lowercased()] = local
            rev[local.lowercased()] = canon
        }
        self.forward = fwd
        self.reverse = rev
    }

    /// English/identity localizer (no translations).
    static let identity = VocabularyLocalizer(forward: [:])

    /// Forward: canonical label -> localized term for display. Identity if the
    /// term is unknown (manual tags, untranslated vision terms).
    func display(_ canonical: String) -> String {
        forward[canonical.lowercased()] ?? canonical
    }

    /// Reverse: a localized token -> its canonical term, or nil if the token is
    /// not a known localized vision term. Case-insensitive.
    func canonicalize(_ token: String) -> String? {
        reverse[token.lowercased()]
    }
}
```

- [ ] **Step 4: Add the file to the Muse target**

In Xcode, ensure `VocabularyLocalizer.swift` is a member of the **Muse** target (File Inspector → Target Membership), or add its `PBXBuildFile`/`PBXFileReference` to `project.pbxproj` under the Muse `Sources` phase and the `Localization` group.

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/VocabularyLocalizerTests`
Expected: PASS (7 tests).

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Localization/VocabularyLocalizer.swift Muse/MuseTests/VocabularyLocalizerTests.swift Muse/Muse.xcodeproj/project.pbxproj
git commit -m "feat(l10n): VocabularyLocalizer forward/reverse seam (pure)"
```

---

### Task 3: Vocabulary data + bundle loader

Generate the canonical taxonomy list, author the French column, bundle `VisionVocabulary.json`, and wire `VocabularyLocalizer.shared` to load it for the effective language.

**Files:**
- Create: `Muse/Muse/Localization/VisionVocabulary.json`
- Modify: `Muse/Muse/Localization/VocabularyLocalizer.swift` (add `static let shared` + loader)
- Test (temporary, deleted after use): `Muse/MuseTests/TaxonomyDumpTests.swift`

**Interfaces:**
- Consumes: `VocabularyLocalizer.init(forward:)` (Task 2).
- Produces: `static let shared: VocabularyLocalizer` resolving `Bundle.main.preferredLocalizations.first`; bundled `VisionVocabulary.json` of shape `{ "<canonical>": { "fr": "<term>" } }`.

- [ ] **Step 1: Dump the Vision taxonomy (one-off)**

Create `Muse/MuseTests/TaxonomyDumpTests.swift`:

```swift
import XCTest
import Vision
@testable import Muse

final class TaxonomyDumpTests: XCTestCase {
    func testDumpKnownClassifications() throws {
        let req = VNClassifyImageRequest()
        let rev = VNClassifyImageRequest.currentRevision
        let terms = try VNClassifyImageRequest
            .knownClassifications(forRevision: rev)
            .map { $0.identifier }
            .sorted()
        let out = "/tmp/vision_taxonomy.txt"
        try terms.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        print("[taxonomy] \(terms.count) terms -> \(out)")
        XCTAssertGreaterThan(terms.count, 100)
        _ = req
    }
}
```

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/TaxonomyDumpTests`
Expected: PASS; `/tmp/vision_taxonomy.txt` lists the full canonical vocabulary (one term per line).

- [ ] **Step 2: Author `VisionVocabulary.json` (French)**

Create `Muse/Muse/Localization/VisionVocabulary.json` mapping each canonical term to its French translation. Shape (example):

```json
{
  "beach": { "fr": "plage" },
  "dog": { "fr": "chien" },
  "sunset": { "fr": "coucher de soleil" },
  "document": { "fr": "document" },
  "screenshot": { "fr": "capture d’écran" }
}
```

Translate every term from `/tmp/vision_taxonomy.txt` you can confidently render. **Coverage rule:** prioritize the common/high-frequency terms; any term left out falls back to English automatically (identity) — acceptable and documented in the spec (§7). Keep all keys lowercased to match the canonical identifiers. Multi-word/compound identifiers (e.g. `coffee_cup`) keep their canonical key exactly as emitted; translate the human meaning ("tasse à café").

- [ ] **Step 3: Add the JSON to the target as a bundle resource**

In Xcode, add `VisionVocabulary.json` to the **Muse** target's resources (or add the `PBXBuildFile`/`PBXFileReference` + Resources phase entry in `project.pbxproj`). Verify it copies into the app bundle.

- [ ] **Step 4: Write the failing test for the loader’s decode shape**

Append to `Muse/MuseTests/VocabularyLocalizerTests.swift`:

```swift
    func testForwardForLanguageBuildsFromNestedTable() {
        let all = ["beach": ["fr": "plage"], "dog": ["fr": "chien", "es": "perro"]]
        let loc = VocabularyLocalizer(table: all, language: "fr")
        XCTAssertEqual(loc.display("beach"), "plage")
        XCTAssertEqual(loc.display("dog"), "chien")
        XCTAssertEqual(loc.canonicalize("plage"), "beach")
    }
    func testEnglishLanguageIsIdentity() {
        let all = ["beach": ["fr": "plage"]]
        let loc = VocabularyLocalizer(table: all, language: "en")
        XCTAssertEqual(loc.display("beach"), "beach")
    }
```

- [ ] **Step 5: Run to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/VocabularyLocalizerTests`
Expected: FAIL — no `init(table:language:)`.

- [ ] **Step 6: Add the table initializer + bundle loader**

Append to `VocabularyLocalizer.swift`:

```swift
extension VocabularyLocalizer {

    /// Build a localizer for `language` from a nested `{canonical: {lang: term}}`
    /// table. English (or no entries) yields the identity localizer.
    init(table: [String: [String: String]], language: String) {
        guard language != "en" else { self.init(forward: [:]); return }
        var forward: [String: String] = [:]
        for (canon, byLang) in table {
            if let term = byLang[language] { forward[canon] = term }
        }
        self.init(forward: forward)
    }

    /// Loaded once for the app's effective language (honors the macOS per-app
    /// language override via `preferredLocalizations`). English/missing data ->
    /// identity, so AI tags stay English when the feature isn't active.
    static let shared: VocabularyLocalizer = {
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        guard lang != "en",
              let url = Bundle.main.url(forResource: "VisionVocabulary", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return .identity }
        return VocabularyLocalizer(table: table, language: lang)
    }()
}
```

- [ ] **Step 7: Run to verify it passes**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/VocabularyLocalizerTests`
Expected: PASS.

- [ ] **Step 8: Remove the one-off dump test**

```bash
rm Muse/MuseTests/TaxonomyDumpTests.swift
```
(Remove its target membership in Xcode/pbxproj too.) The taxonomy is captured in the JSON; the dump test is not shipped.

- [ ] **Step 9: Build the full app**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: success; `VisionVocabulary.json` present in the built `.app/Contents/Resources`.

- [ ] **Step 10: Commit**

```bash
git add Muse/Muse/Localization/VisionVocabulary.json Muse/Muse/Localization/VocabularyLocalizer.swift Muse/MuseTests/VocabularyLocalizerTests.swift Muse/Muse.xcodeproj/project.pbxproj
git commit -m "feat(l10n): bundled Vision vocabulary (fr) + shared loader"
```

---

### Task 4: Localize tag-label display sites (chips, banner, hero)

Render localized tag labels everywhere a canonical label is shown; keep every action/identity on the canonical label. `display()` is identity-safe, so applying it to non-vision strings (collection names) is harmless.

**Files:**
- Modify: `Muse/Muse/Models/TagSelection.swift` (parameterize banner connectives)
- Modify: `Muse/Muse/Views/TagChipsRow.swift`
- Modify: `Muse/Muse/Views/Viewer/ViewerInfoColumn.swift` (+ the shared pill-label `Text` in `Views/Viewer/`)
- Test: `Muse/MuseTests/TagSelectionTests.swift` (extend)

**Interfaces:**
- Consumes: `VocabularyLocalizer.shared.display(_:)` (Task 3).
- Produces: `TagSelection.bannerText(for:viewing:and:)` with defaulted connectives (back-compatible).

- [ ] **Step 1: Write the failing test for parameterized banner connectives**

Append to `Muse/MuseTests/TagSelectionTests.swift`:

```swift
    func testBannerTextUsesProvidedConnectives() {
        XCTAssertEqual(
            TagSelection.bannerText(for: ["plage", "chien"], viewing: "Affichage", and: "et"),
            "Affichage plage et chien")
    }
    func testBannerTextDefaultsRemainEnglish() {
        XCTAssertEqual(
            TagSelection.bannerText(for: ["blue", "screenshot"]),
            "Viewing blue and screenshot")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/TagSelectionTests`
Expected: FAIL — `bannerText` has no `viewing:`/`and:` params.

- [ ] **Step 3: Parameterize `bannerText`**

In `Muse/Muse/Models/TagSelection.swift`, replace the `bannerText(for:)` body:

```swift
    static func bannerText(for labels: [String],
                           viewing: String = "Viewing",
                           and: String = "and") -> String? {
        switch labels.count {
        case 0, 1:
            return nil
        case 2:
            return "\(viewing) \(labels[0]) \(and) \(labels[1])"
        default:
            let head = labels.dropLast().joined(separator: ", ")
            return "\(viewing) \(head), \(and) \(labels.last!)"
        }
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/TagSelectionTests`
Expected: PASS (existing + 2 new).

- [ ] **Step 5: Localize the chips + "All" in `TagChipsRow`**

In `Muse/Muse/Views/TagChipsRow.swift`:

- The "All" chip label (~line 42): change `label: "All"` to `label: String(localized: "All")`.
- The per-tag chip (~line 49): change `label: tag.label,` to `label: VocabularyLocalizer.shared.display(tag.label),`.
  - Leave the `isSelected:` check, `toggleAction:`, the plain/Cmd-click `action` closure, and the `contextMenu` Rename/Delete (which use `tag.label`) on the **canonical** `tag.label` — do NOT change those.
  - Leave the `ForEach(... id: \.element.label)` on canonical — unchanged.

- [ ] **Step 6: Localize the banner pills + VoiceOver banner in `TagChipsRow`**

In the banner block (~lines 106–136):

- Replace the guard/label source (~line 106) so the VoiceOver string uses localized labels + localized connectives:

```swift
        let localizedLabels = appState.activeTagLabels.map { VocabularyLocalizer.shared.display($0) }
        if let banner = TagSelection.bannerText(for: localizedLabels,
                                                viewing: String(localized: "Viewing"),
                                                and: String(localized: "and")) {
```

- In the `ForEach` over segments (~line 114), build segments from `localizedLabels`:

```swift
                    ForEach(Array(
                        TagSelection.bannerSegments(for: localizedLabels).enumerated()),
                            id: \.offset) { _, seg in
```

- The literal `Text("Viewing")` (~line 112) and `Text("and")` (~line 118) stay as string literals (auto-localized by the catalog in Task 8). The `.accessibilityLabel(banner)` (~line 135) now uses the localized `banner` string.

- [ ] **Step 7: Localize the hero tag pills + toasts in `ViewerInfoColumn`**

In `Muse/Muse/Views/Viewer/ViewerInfoColumn.swift`:

- The tags card `pills:` mapping (~line 179) keeps `PillItem(id: $0.id, label: $0.label)` as **canonical** (the pill tap/removal use `pill.label`/`pill.id`). Do NOT localize here.
- Instead localize at the **pill label render**: find the shared pill view in `Views/Viewer/` that renders a `PillItem`'s label as `Text(pill.label)` (the `PillFlow`/card pill cell) and change it to `Text(VocabularyLocalizer.shared.display(pill.label))`. This localizes vision tags for display while collection-name pills pass through unchanged (`display` is identity for non-vision strings). This is the single hero render site.
- Localize the tag toasts: the tags-card removal toast `show("Removed \(pill.label)")` (~line 188) → `show("Removed \(VocabularyLocalizer.shared.display(pill.label))")`; the add toast `show("Added \(candidate.label)")` similarly for tag suggestions. (The `"Removed"`/`"Added"` words are literals → auto-localized in Task 8.)

- [ ] **Step 8: Build the full app**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: success.

- [ ] **Step 9: Commit**

```bash
git add Muse/Muse/Models/TagSelection.swift Muse/Muse/Views/TagChipsRow.swift Muse/Muse/Views/Viewer/ViewerInfoColumn.swift Muse/MuseTests/TagSelectionTests.swift
git commit -m "feat(l10n): localize tag-label display (chips, banner, hero); keep actions canonical"
```

---

### Task 5: Search bridge (localized query → canonical tag match)

A French user typing `plage` must find files tagged canonical `beach`, while raw tokens still match French filenames/OCR.

**Files:**
- Create: `Muse/Muse/Database/SearchBridge.swift`
- Test: `Muse/MuseTests/SearchBridgeTests.swift`
- Modify: `Muse/Muse/Database/SearchService.swift`

**Interfaces:**
- Consumes: `VocabularyLocalizer.shared.canonicalize(_:)` (Task 3).
- Produces: `SearchBridge.tagSearchTerms(for:canonicalize:) -> [String]`.

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/SearchBridgeTests.swift`:

```swift
import XCTest
@testable import Muse

final class SearchBridgeTests: XCTestCase {
    private func canon(_ t: String) -> String? {
        ["plage": "beach", "chien": "dog"][t.lowercased()]
    }

    func testRawQueryAlwaysIncluded() {
        XCTAssertEqual(SearchBridge.tagSearchTerms(for: "sunset", canonicalize: canon),
                       ["sunset"])
    }
    func testLocalizedQueryAddsCanonical() {
        XCTAssertEqual(SearchBridge.tagSearchTerms(for: "plage", canonicalize: canon),
                       ["plage", "beach"])
    }
    func testPerTokenCanonicalization() {
        XCTAssertEqual(SearchBridge.tagSearchTerms(for: "plage chien", canonicalize: canon),
                       ["plage chien", "beach", "dog"])
    }
    func testDeduplicatesAndPreservesOrder() {
        XCTAssertEqual(SearchBridge.tagSearchTerms(for: "plage plage", canonicalize: canon),
                       ["plage plage", "beach"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/SearchBridgeTests`
Expected: FAIL — `cannot find 'SearchBridge'`.

- [ ] **Step 3: Implement `SearchBridge`**

Create `Muse/Muse/Database/SearchBridge.swift`:

```swift
//
//  SearchBridge.swift
//  Muse
//
//  Pure helper for the tag-search half of SearchService: expand a user query
//  into the set of tag-label terms to LIKE-match. Always includes the raw query
//  (so French filenames/OCR/captions still match) and adds the canonical English
//  term whenever the whole query OR any whitespace token is a known localized
//  vision term — so `plage` finds files tagged canonical `beach`.
//

import Foundation

nonisolated enum SearchBridge {
    static func tagSearchTerms(for query: String,
                               canonicalize: (String) -> String?) -> [String] {
        var terms = [query]
        if let c = canonicalize(query) { terms.append(c) }
        for token in query.split(whereSeparator: { $0.isWhitespace }) {
            if let c = canonicalize(String(token)) { terms.append(c) }
        }
        var seen = Set<String>()
        return terms.filter { seen.insert($0).inserted }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/SearchBridgeTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Wire into `SearchService`**

In `Muse/Muse/Database/SearchService.swift`, replace the tag-match block (currently ~lines 41–45):

```swift
            // 2) Tag label matches (for indexed content)
            let tagIDs = try TagRow
                .filter(TagRow.Columns.label.like("%" + trimmed + "%"))
                .fetchAll(db)
                .map { $0.file_id }
```

with an OR over the bridged terms:

```swift
            // 2) Tag label matches (for indexed content). Bridge a localized
            //    query to its canonical vision term so e.g. "plage" finds files
            //    tagged canonical "beach"; the raw query is always included.
            let tagTerms = SearchBridge.tagSearchTerms(for: trimmed) {
                VocabularyLocalizer.shared.canonicalize($0)
            }
            let tagFilter = tagTerms
                .map { TagRow.Columns.label.like("%" + $0 + "%") }
                .joined(operator: .or)
            let tagIDs = try TagRow
                .filter(tagFilter)
                .fetchAll(db)
                .map { $0.file_id }
```

(`[SQLSpecificExpressible].joined(operator: .or)` is GRDB's OR-combination of column predicates.)

- [ ] **Step 6: Build**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: success.

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Database/SearchBridge.swift Muse/MuseTests/SearchBridgeTests.swift Muse/Muse/Database/SearchService.swift
git commit -m "feat(l10n): search bridge — localized query finds canonical tags"
```

---

### Task 6: AI collection names in-language

Generated collection names come out in French: prompt the FM namer in the effective language, and localize the non-AI fallback namer through the vocabulary table.

**Files:**
- Modify: `Muse/Muse/Intelligence/Core/CollectionNaming.swift`
- Test: `Muse/MuseTests/TagFallbackNamerLocalizationTests.swift`

**Interfaces:**
- Consumes: `VocabularyLocalizer` (Task 2/3).
- Produces: `TagFallbackNamer.name(...)` returns a localized title (via an injectable localizer defaulting to `.shared`); `FoundationModelNamer` prompts in-language.

- [ ] **Step 1: Write the failing test for the fallback namer**

Create `Muse/MuseTests/TagFallbackNamerLocalizationTests.swift`:

```swift
import XCTest
@testable import Muse

final class TagFallbackNamerLocalizationTests: XCTestCase {
    func testFallbackNameIsLocalizedAndCapitalized() async {
        let namer = TagFallbackNamer(localizer: VocabularyLocalizer(forward: ["beach": "plage"]))
        let name = await namer.name(tagsByFrequency: ["beach", "sand"])
        XCTAssertEqual(name, "Plage")
    }
    func testFallbackUnknownTagPassesThrough() async {
        let namer = TagFallbackNamer(localizer: .identity)
        let name = await namer.name(tagsByFrequency: ["budget"])
        XCTAssertEqual(name, "Budget")
    }
    func testFallbackEmptyTagsReturnsCollection() async {
        let namer = TagFallbackNamer(localizer: .identity)
        let name = await namer.name(tagsByFrequency: [])
        XCTAssertEqual(name, "Collection")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/TagFallbackNamerLocalizationTests`
Expected: FAIL — `TagFallbackNamer` has no `init(localizer:)`.

- [ ] **Step 3: Localize the fallback namer**

In `Muse/Muse/Intelligence/Core/CollectionNaming.swift`, update `TagFallbackNamer`:

```swift
final class TagFallbackNamer: CollectionNamer {
    let modelVersion = "topTag-v1"
    private let localizer: VocabularyLocalizer

    init(localizer: VocabularyLocalizer = .shared) {
        self.localizer = localizer
    }

    func name(tagsByFrequency: [String]) async -> String {
        guard let top = tagsByFrequency.first else { return "Collection" }
        return localizer.display(top).capitalized
    }

    static func makeBest() -> CollectionNamer {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *),
           SystemLanguageModel.default.availability == .available {
            return FoundationModelNamer()
        }
        #endif
        return TagFallbackNamer()
    }
}
```

(Note: `"Collection"` here is a stored fallback name. Leave it as a literal — Task 8 adds it to the catalog so a freshly-named fallback collection reads in French at creation time.)

- [ ] **Step 4: Prompt the FM namer in-language**

In `FoundationModelNamer`, derive the effective language and add it to instructions + prompt:

```swift
    func name(tagsByFrequency: [String]) async -> String {
        let fallback = tagsByFrequency.first?.capitalized ?? "Collection"
        guard !tagsByFrequency.isEmpty else { return fallback }
        let language = Locale.current.localizedString(forLanguageCode:
            Bundle.main.preferredLocalizations.first ?? "en") ?? "English"
        do {
            let session = LanguageModelSession(instructions: """
            You name small collections of images from their descriptive tags.
            Reply with ONLY a short collection title, 1-3 words, no punctuation,
            written in \(language).
            """)
            let prompt = """
            These tags describe a group of images: \(tagsByFrequency.prefix(8).joined(separator: ", ")).
            Reply with ONLY a short collection title, 1-3 words, no punctuation, in \(language).
            """
            let response = try await session.respond(to: prompt)
            let title = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return (title.isEmpty || title.count > 40) ? fallback : title
        } catch {
            return fallback
        }
    }
```

- [ ] **Step 5: Run to verify it passes**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/TagFallbackNamerLocalizationTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Build**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: success.

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Intelligence/Core/CollectionNaming.swift Muse/MuseTests/TagFallbackNamerLocalizationTests.swift
git commit -m "feat(l10n): AI collection names in-language (FM prompt + fallback via vocabulary)"
```

---

### Task 7: Locale-aware formatting audit

Ensure dates/sizes/numbers render in the user's locale (e.g. `1,5 Mo`, French date order). Most `*Formatter`s are locale-aware by default; this task finds and fixes any pinned-locale or hand-built strings.

**Files:**
- Modify: audit-driven (candidates: `Muse/Muse/Viewers/FileMetadata.swift`, `Muse/Muse/Views/Viewer/ViewerInfoColumn.swift`, `Muse/Muse/Filesystem/FolderStat.swift`, anywhere using `String(format:` for sizes/dates).

- [ ] **Step 1: Enumerate the formatting sites**

Run: `grep -rn "ByteCountFormatter\|DateFormatter\|RelativeDateTimeFormatter\|NumberFormatter\|\.formatted(\|Locale(identifier" --include="*.swift" Muse/Muse`
Expected: the ~8 call-sites plus any `Locale(identifier:)` (a red flag) or `String(format:` building user-facing sizes/dates.

- [ ] **Step 2: Fix any pinned locale or hand-built numeric/date strings**

For each site:
- `ByteCountFormatter`, `DateFormatter`, `.formatted(...)`, `RelativeDateTimeFormatter` with NO explicit `.locale` already use `Locale.current` — leave them.
- If any sets `formatter.locale = Locale(identifier: "en_US")` (or similar), remove that line (or set `= .current`).
- If any builds a size/date string by hand (e.g. `String(format: "%.1f MB", …)`), replace with `ByteCountFormatter`/`.formatted()` so units and decimal separators localize.

Example (only if found) — replace a hand-built size in `FileMetadata`/`ViewerInfoColumn`:

```swift
// before: String(format: "%.1f MB", bytesDouble / 1_000_000)
// after:
ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "fix(l10n): locale-aware date/size formatting (audit)"
```

(If the audit finds nothing to change, note that in the commit body and skip — `ByteCountFormatter` at `ViewerInfoColumn.swift:117` is already locale-aware.)

---

### Task 8: UI chrome sweep + French catalog

Populate the String Catalog with French for all UI chrome. Literal `Text("…")`/`Label`/`.help`/`.accessibilityLabel`/`Button("…")`/`.alert`/`Section("…")` strings auto-extract; the only code edits are chrome strings that flow through a `String` variable (which render verbatim, NOT localized).

**Files:**
- Modify: `Muse/Muse/Resources/Localizable.xcstrings` (fill `fr`)
- Modify: UI files where a chrome string is passed as a `String` variable (wrap with `String(localized:)`).

**Interfaces:**
- Consumes: the catalog + `fr` region from Task 1.

- [ ] **Step 1: Auto-extract the literal strings**

Build once so Xcode extracts literal `LocalizedStringKey` strings into the catalog:

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Then open `Localizable.xcstrings` in Xcode — the `strings` table now lists the auto-extracted English keys (e.g. `"All"`, `"Viewing"`, `"and"`, `"Rename Tag…"`, `"Delete"`, `"Add Folder"`, `"Collections"`, the alert titles/messages, etc.).

- [ ] **Step 2: Find chrome strings passed as `String` variables (NOT auto-localized)**

`Text(someStringVariable)` and similar render **verbatim**. Audit for chrome (NOT tag/data) strings built as `String` and shown:

Run: `grep -rn 'Text(\([a-z]' --include="*.swift" Muse/Muse/Views Muse/Muse/Components Muse/Muse/Viewers | grep -v 'Text("'`
For each result that is **UI chrome** (a fixed label, not user/tag/file data), wrap the source string with `String(localized: "…")` at its definition, or convert the `Text(var)` to use a `LocalizedStringKey`. (Tag labels are already handled via `VocabularyLocalizer` in Task 4 — do NOT double-wrap those. File names, counts, dates, and user content stay verbatim.)

- [ ] **Step 3: Author French translations in the catalog**

In `Localizable.xcstrings`, fill the `fr` value for every extracted key. Direct JSON edit shape per entry:

```json
    "Add Folder" : {
      "localizations" : {
        "fr" : { "stringUnit" : { "state" : "translated", "value" : "Ajouter un dossier" } }
      }
    }
```

Translate every key. Leave none `new`/untranslated except where English is genuinely correct (mark those `state: "translated"` with the English value, or leave for graceful fallback). Mind interpolations: keep `%@`/`\(…)` placeholders intact and in natural French order.

- [ ] **Step 4: Build**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: success; no "unlocalized" warnings for chrome you intended to translate.

- [ ] **Step 5: Smoke-test French at runtime**

Run the app forced into French (no system change needed):

Run: `open -n "$(find ~/Library/Developer/Xcode/DerivedData -name Muse.app -path '*Debug*' -print -quit)" --args -AppleLanguages '(fr)'`
Verify: toolbar/menus/alerts/Collections/Settings read in French; tag chips + hero tags read in French; searching a French tag term returns results; a hand-typed tag/collection stays as typed; dates/sizes use French formatting.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Resources/Localizable.xcstrings $(git diff --name-only -- '*.swift')
git commit -m "feat(l10n): French UI chrome via String Catalog + verbatim-string sweep"
```

---

## Final verification

- [ ] **Run the full test suite**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test`
Expected: `** TEST SUCCEEDED **`; new suites (`VocabularyLocalizerTests`, `SearchBridgeTests`, `TagFallbackNamerLocalizationTests`) + extended `TagSelectionTests` all green; no regressions.

- [ ] **Removability self-check (no code change — confirm seams exist):**
  - UI per-language: dropping `fr` from `knownRegions` → English. ✅ (Task 1)
  - AI tags: `VocabularyLocalizer.shared` → `.identity` reverts all tag display + search. ✅ (Tasks 2–5 route through one type)
  - No stored data is translated (tags/FTS/collection rows canonical-English; only newly-generated collection *names* are localized at creation, which is intended user data). ✅

- [ ] **Update docs:** add the `feat/localization-french` row to the implementation-status table and a session-log entry in `docs/session-log.md` + the architecture map (new `Localization/` group, `SearchBridge.swift`), per repo convention. Commit.

---

## Self-review notes (author)

- **Spec coverage:** §4A→Tasks 1,8; §4B→Tasks 2,3,4; §4C→Task 5; §4D→Task 6; §4E→Task 7; §4F→Tasks 2,5,6 (pure tests); §5 removability→Final verification; §6 perf (display at render layer, not grid geometry)→honored by Task 4 localizing at view/render sites only; §8 caption stays canonical→untouched (no task localizes `VisionResult.caption()`).
- **Type consistency:** `VocabularyLocalizer.display`/`canonicalize`/`init(forward:)`/`init(table:language:)`/`shared`/`identity` are used identically across Tasks 2–6. `TagSelection.bannerText(for:viewing:and:)` defaults keep existing call-sites/tests valid. `SearchBridge.tagSearchTerms(for:canonicalize:)` matches its test and its SearchService call.
- **Known labor:** Task 3 (French vocabulary) and Task 8 (French UI) are translation-authoring; untranslated terms fall back to English gracefully (spec §7).
