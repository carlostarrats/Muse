# Smart Collections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add rule-driven ("smart") collections whose membership is computed live from the database on every display, instead of being hand-picked — over the axes Muse already stores (rating, color, tags, kind, date, filename, size).

**Architecture:** A smart collection is an ordinary `collections` row carrying a JSON `smart_rules` set and **no** `collection_members`. A pure `SmartRuleSet`/`SmartRule` value type models the rules; a pure `SmartCollectionResolver` evaluates each rule to a `Set<file_id>` against a fixture-testable `GRDB.Database` and combines them by Match.all (AND) / Match.any (OR). `CollectionStore` gains a single `alivePathsResolving` seam that branches on `smart_rules IS NOT NULL`, so `fetchAll` (counts) and `AppState.setActiveCollection` (grid contents) route smart collections through the resolver while every other collection path is byte-for-byte unchanged. Smart collections use `model_version = 'manual'` to inherit protection from the recluster stale-sweep and empty-state visibility for free.

**Tech Stack:** Swift, SwiftUI, GRDB (SQLite), XCTest. macOS 14.6+.

## Global Constraints

- **Storage stays canonical-English; localize at DISPLAY time.** Never persist a translated string. Rule labels/operators are enum-derived and localized via `String(localized:)`; runtime values echoed into summaries use `NSLocalizedString`.
- **Every new user-facing string MUST be localized (French).** Menu items, modal labels, rule-type/operator names, the Match toggle, the confirm dialog. After wrapping literals, run `xcodebuild -exportLocalizations` and fill the `fr` values.
- **Tags/ratings are per `(file_id, parent_dir)`.** A `file_id` satisfies a tag/rating rule if ANY of its locations does (`EXISTS`).
- **A star rating IS a mutually-exclusive `★`-run tag** (`StarRating`, label = U+2605 × 1…5). The rating rule resolves qualifying star counts → glyph labels → `tags.label IN (...)`.
- **Reachability is load-bearing.** A collection's visible contents/count are alive members (`paths.is_alive = 1`) narrowed to those under an active root via `CollectionStore.isUnderAnyRoot`. The resolver returns alive absolute paths; the SAME under-root filter is applied downstream. Never show a tile behind an unreachable root.
- **Files are never deleted from disk by this feature.** Converting a manual collection to smart deletes only its `collection_members` rows (after a confirm), never files.
- **No new network calls.**
- **GRDB writes are `try await queue.write { }`, reads `try await queue.read { }`.** Rows inserted as `var`.
- **Never bind a per-keystroke control to `@Published` AppState.** The rules modal holds its draft in local `@State` and commits only on Save.
- **Min macOS 14.6.** `.windowFittedSheetHeight(width:ideal:)` for the fixed-height scrolling sheet (never a bare `.frame(height:)`).

**Prerequisite (satisfied):** the color-search units (`ColorQuery`, `RGB`, `LabColor`, `ColorDistance`, `PaletteMatch`, `NamedColor.parse`) are merged to `main` (`Muse/Muse/Intelligence/Core/ColorSearch.swift`). The color rule reuses them.

---

## File structure

**Create:**
- `Muse/Muse/Intelligence/Collections/SmartRule.swift` — pure `SmartRuleSet`/`SmartRule` model (Codable, `isValid`, `summary`, `KindGroup` mapping, `Comparison`/`HasOp`/`DateField`/`DateOp`/`ColorTerm` enums).
- `Muse/Muse/Intelligence/Collections/SmartCollectionResolver.swift` — pure resolver over `GRDB.Database`.
- `Muse/Muse/Views/Sidebar/SmartCollectionRulesView.swift` — the rule-builder sheet.
- `Muse/MuseTests/SmartRuleSetTests.swift`
- `Muse/MuseTests/SmartCollectionResolverTests.swift`
- `Muse/MuseTests/SmartCollectionsMigrationTests.swift`

**Modify:**
- `Muse/Muse/Database/Database.swift` — add `v12_smart_collections` migration.
- `Muse/Muse/Database/Records.swift` — `CollectionRow.smart_rules: String?`.
- `Muse/Muse/Intelligence/Collections/CollectionStore.swift` — `createSmart`, `setSmartRules`, `makeSmart`, `smartRuleSet`, `alivePathsResolving`; smart-aware `fetchAll`.
- `Muse/Muse/Models/AppState+Filters.swift` — `setActiveCollection` + `exportableURLs` use `alivePathsResolving`.
- `Muse/Muse/Views/CollectionsPage.swift` — `+` becomes a menu (New Collection / New Smart Collection…).
- `Muse/Muse/Views/Sidebar/CollectionSidebarRow.swift` — "Make Smart… / Edit Rules…" context-menu item, confirm dialog, sheet, smart default icon.
- `Muse/Muse/Backup/BackupArchive.swift` — `BackupCollection.smart_rules`.
- `Muse/Muse/Backup/CollectionMaterializer.swift` — carry `smartRules` through.
- `Muse/Muse/Backup/BackupBuilder.swift` — emit `smart_rules`.
- `Muse/Muse/Backup/ReconnectApplier.swift` — restore `smart_rules`.
- `Muse/Muse/Localization/…` / `Localizable.xcstrings` — French for all new strings.

---

## Task 1: Storage — `v12_smart_collections` migration + record column

**Files:**
- Modify: `Muse/Muse/Database/Database.swift` (after the `v11_file_note` migration block, before `return migrator`)
- Modify: `Muse/Muse/Database/Records.swift:135-147` (`CollectionRow`)
- Test: `Muse/MuseTests/SmartCollectionsMigrationTests.swift`

**Interfaces:**
- Produces: `collections.smart_rules TEXT` (nullable); `CollectionRow.smart_rules: String?`.

- [ ] **Step 1: Write the failing migration test**

Create `Muse/MuseTests/SmartCollectionsMigrationTests.swift`:

```swift
import XCTest
import GRDB
@testable import Muse

final class SmartCollectionsMigrationTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    func testMigrationAddsNullableSmartRulesColumn() throws {
        let q = try makeQueue()
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order)
                VALUES ('c1', 'Plain', 0, 'manual', 0, 0, 0)
                """)
        }
        let row = try q.read { db in try CollectionRow.fetchOne(db, sql: "SELECT * FROM collections WHERE id = 'c1'") }
        XCTAssertNil(row?.smart_rules, "existing collections default to NULL smart_rules")
    }

    func testSmartRulesRoundTrips() throws {
        let q = try makeQueue()
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order, smart_rules)
                VALUES ('c2', 'Smart', 0, 'manual', 0, 0, 0, ?)
                """, arguments: ["{\"match\":\"all\",\"rules\":[]}"])
        }
        let row = try q.read { db in try CollectionRow.fetchOne(db, sql: "SELECT * FROM collections WHERE id = 'c2'") }
        XCTAssertEqual(row?.smart_rules, "{\"match\":\"all\",\"rules\":[]}")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/SmartCollectionsMigrationTests 2>&1 | tail -20`
Expected: FAIL — `CollectionRow` has no `smart_rules` member (compile error) / column missing.

- [ ] **Step 3: Add the migration**

In `Muse/Muse/Database/Database.swift`, immediately after the `v11_file_note` migration's closing `}` and before `return migrator`:

```swift
        migrator.registerMigration("v12_smart_collections") { db in
            // A smart collection stores ONLY its rule set (JSON) and holds no
            // collection_members — its membership is resolved live from the DB
            // every time it's shown. smart_rules IS NOT NULL ⇒ smart collection;
            // existing manual/auto collections keep smart_rules = NULL, untouched.
            try db.alter(table: "collections") { t in
                t.add(column: "smart_rules", .text)
            }
        }
```

- [ ] **Step 4: Add the record column**

In `Muse/Muse/Database/Records.swift`, add to `CollectionRow` after the `color` line (`:146`):

```swift
    var smart_rules: String?        // JSON SmartRuleSet; nil = not a smart collection (v12)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/SmartCollectionsMigrationTests 2>&1 | tail -20`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Database/Database.swift Muse/Muse/Database/Records.swift Muse/MuseTests/SmartCollectionsMigrationTests.swift
git commit -m "feat: v12_smart_collections column + CollectionRow.smart_rules"
```

---

## Task 2: Pure rule model — `SmartRuleSet` / `SmartRule`

**Files:**
- Create: `Muse/Muse/Intelligence/Collections/SmartRule.swift`
- Test: `Muse/MuseTests/SmartRuleSetTests.swift`

**Interfaces:**
- Produces:
  - `struct SmartRuleSet: Codable, Equatable { enum Match: String, Codable { case all, any }; var match: Match; var rules: [SmartRule]; var isValid: Bool; func encodedJSON() -> String?; static func decode(_ json: String) -> SmartRuleSet? }`
  - `enum SmartRule: Codable, Equatable` cases: `.rating(op: Comparison, stars: Int)`, `.color(ColorTerm)`, `.tag(op: HasOp, label: String)`, `.kind(KindGroup)`, `.date(field: DateField, op: DateOp)`, `.filename(contains: String)`, `.size(op: Comparison, bytes: Int64)`; each has `var isValid: Bool`.
  - `enum Comparison: String, Codable { case atLeast, equal, atMost }`
  - `enum HasOp: String, Codable { case has, hasNot }`
  - `enum ColorTerm: Codable, Equatable { case name(String); case hex(String) }`
  - `enum DateField: String, Codable { case created, modified }`
  - `enum DateOp: Codable, Equatable { case withinDays(Int); case before(Int64); case after(Int64) }` (dates as epoch-seconds `Int64`, matching `files.created_at`)
  - `enum KindGroup: String, Codable, CaseIterable { case image, raw, pdf, video, audio, document; var kinds: [String] }`

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/SmartRuleSetTests.swift`:

```swift
import XCTest
@testable import Muse

final class SmartRuleSetTests: XCTestCase {

    // Round-trip every rule type through JSON.
    func testEveryRuleTypeRoundTrips() {
        let set = SmartRuleSet(match: .all, rules: [
            .rating(op: .atLeast, stars: 4),
            .color(.hex("#3a7bd5")),
            .color(.name("red")),
            .tag(op: .has, label: "beach"),
            .tag(op: .hasNot, label: "draft"),
            .kind(.image),
            .date(field: .modified, op: .withinDays(30)),
            .date(field: .created, op: .before(1_700_000_000)),
            .filename(contains: "invoice"),
            .size(op: .atMost, bytes: 5_000_000),
        ])
        guard let json = set.encodedJSON(), let back = SmartRuleSet.decode(json) else {
            return XCTFail("round-trip failed")
        }
        XCTAssertEqual(set, back)
    }

    func testLegacyEmptyRuleSetDecodes() {
        let back = SmartRuleSet.decode("{\"match\":\"any\",\"rules\":[]}")
        XCTAssertEqual(back, SmartRuleSet(match: .any, rules: []))
    }

    func testInvalidJSONReturnsNil() {
        XCTAssertNil(SmartRuleSet.decode("not json"))
    }

    // Validity boundaries.
    func testRatingStarsBounds() {
        XCTAssertFalse(SmartRule.rating(op: .atLeast, stars: 0).isValid)
        XCTAssertTrue(SmartRule.rating(op: .atLeast, stars: 1).isValid)
        XCTAssertTrue(SmartRule.rating(op: .equal, stars: 5).isValid)
        XCTAssertFalse(SmartRule.rating(op: .atMost, stars: 6).isValid)
    }

    func testTagLabelNonEmpty() {
        XCTAssertFalse(SmartRule.tag(op: .has, label: "  ").isValid)
        XCTAssertTrue(SmartRule.tag(op: .has, label: "beach").isValid)
    }

    func testFilenameNonEmpty() {
        XCTAssertFalse(SmartRule.filename(contains: "").isValid)
        XCTAssertTrue(SmartRule.filename(contains: "a").isValid)
    }

    func testSizePositive() {
        XCTAssertFalse(SmartRule.size(op: .atMost, bytes: 0).isValid)
        XCTAssertTrue(SmartRule.size(op: .atMost, bytes: 1).isValid)
    }

    func testColorHexMustParse() {
        XCTAssertTrue(SmartRule.color(.hex("#3a7bd5")).isValid)
        XCTAssertTrue(SmartRule.color(.hex("3a7bd5")).isValid)
        XCTAssertFalse(SmartRule.color(.hex("nope")).isValid)
        XCTAssertTrue(SmartRule.color(.name("red")).isValid)   // any non-empty name; resolution deferred
        XCTAssertFalse(SmartRule.color(.name("")).isValid)
    }

    func testSetIsValidRequiresAtLeastOneValidRuleAndAllValid() {
        XCTAssertFalse(SmartRuleSet(match: .all, rules: []).isValid, "no rules = nothing to match")
        XCTAssertFalse(SmartRuleSet(match: .all, rules: [.tag(op: .has, label: "")]).isValid)
        XCTAssertTrue(SmartRuleSet(match: .all, rules: [.tag(op: .has, label: "x")]).isValid)
    }

    func testKindGroupMapping() {
        XCTAssertEqual(SmartRule.KindGroup.image.kinds, ["image", "psd", "svg"])
        XCTAssertEqual(SmartRule.KindGroup.raw.kinds, ["raw"])
        XCTAssertEqual(SmartRule.KindGroup.document.kinds, ["text", "markdown", "code", "office"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/SmartRuleSetTests 2>&1 | tail -20`
Expected: FAIL — `SmartRuleSet` undefined (compile error).

- [ ] **Step 3: Write the model**

Create `Muse/Muse/Intelligence/Collections/SmartRule.swift`:

```swift
//
//  SmartRule.swift
//  Muse
//
//  The pure, Codable model behind a smart collection: a Match.all/.any set of
//  rules over the axes Muse already stores (rating, color, tags, kind, date,
//  filename, size). No I/O — SmartCollectionResolver evaluates these against
//  the DB. Persisted as JSON in collections.smart_rules (v12).
//

import Foundation

/// AND (`all`) / OR (`any`) over a list of rules. A smart collection stores one.
struct SmartRuleSet: Codable, Equatable {
    enum Match: String, Codable { case all, any }
    var match: Match
    var rules: [SmartRule]

    /// Savable iff there's at least one rule and every rule is valid.
    var isValid: Bool { !rules.isEmpty && rules.allSatisfy(\.isValid) }

    func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String) -> SmartRuleSet? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SmartRuleSet.self, from: self.self == self ? data : data)
    }
}

/// `≥ / = / ≤` — shared by rating and size.
enum Comparison: String, Codable { case atLeast, equal, atMost }
enum HasOp: String, Codable { case has, hasNot }
enum DateField: String, Codable { case created, modified }

/// A color rule term: a palette color name or a hex string.
enum ColorTerm: Codable, Equatable {
    case name(String)
    case hex(String)
}

/// Relative or absolute date bound. Dates are epoch seconds (files.created_at).
enum DateOp: Codable, Equatable {
    case withinDays(Int)
    case before(Int64)
    case after(Int64)
}

enum SmartRule: Codable, Equatable {
    case rating(op: Comparison, stars: Int)
    case color(ColorTerm)
    case tag(op: HasOp, label: String)
    case kind(KindGroup)
    case date(field: DateField, op: DateOp)
    case filename(contains: String)
    case size(op: Comparison, bytes: Int64)

    /// A display-friendly grouping of AssetKind values (files.kind rawValue).
    enum KindGroup: String, Codable, CaseIterable {
        case image, raw, pdf, video, audio, document

        /// The AssetKind rawValues this group matches in files.kind.
        var kinds: [String] {
            switch self {
            case .image:    return ["image", "psd", "svg"]
            case .raw:      return ["raw"]
            case .pdf:      return ["pdf"]
            case .video:    return ["video"]
            case .audio:    return ["audio"]
            case .document: return ["text", "markdown", "code", "office"]
            }
        }
    }

    var isValid: Bool {
        switch self {
        case let .rating(_, stars):        return (1...5).contains(stars)
        case let .color(term):
            switch term {
            case let .name(n): return !n.trimmingCharacters(in: .whitespaces).isEmpty
            case let .hex(h):  return SmartRule.parsedHex(h) != nil
            }
        case let .tag(_, label):           return !label.trimmingCharacters(in: .whitespaces).isEmpty
        case .kind:                        return true
        case let .date(_, op):
            if case let .withinDays(d) = op { return d > 0 }
            return true
        case let .filename(contains):      return !contains.isEmpty
        case let .size(_, bytes):          return bytes > 0
        }
    }

    /// Decode a rule's hex term to sRGB 0…1 (via NamedColor). `#` optional,
    /// 3-digit shorthand expands. Returns nil for a non-hex string.
    static func parsedHex(_ raw: String) -> RGB? {
        var s = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let (r, g, b) = NamedColor.parse(s) else { return nil }
        return RGB(r: r, g: g, b: b)
    }
}
```

Note the `SmartRuleSet.decode` body has a copy-paste artifact — replace it with the clean version in Step 3b.

- [ ] **Step 3b: Fix `decode` (remove the artifact)**

Replace the `decode` body so it reads:

```swift
    static func decode(_ json: String) -> SmartRuleSet? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SmartRuleSet.self, from: data)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/SmartRuleSetTests 2>&1 | tail -20`
Expected: PASS. If Codable synthesis for the associated-value enums fails to compile, no manual coding keys are needed — Swift synthesizes `Codable` for enums with associated values automatically (macOS 14 / Swift 5.9+). Confirm the build is clean.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Intelligence/Collections/SmartRule.swift Muse/MuseTests/SmartRuleSetTests.swift
git commit -m "feat: SmartRuleSet/SmartRule pure model (Codable, validity, kind mapping)"
```

---

## Task 3: Pure resolver — `SmartCollectionResolver`

**Files:**
- Create: `Muse/Muse/Intelligence/Collections/SmartCollectionResolver.swift`
- Test: `Muse/MuseTests/SmartCollectionResolverTests.swift`

**Interfaces:**
- Consumes: `SmartRuleSet`, `SmartRule`, `RGB`, `LabColor`, `ColorDistance`, `PaletteMatch`, `NamedColor`, `StarRating`.
- Produces:
  - `enum SmartCollectionResolver { static func memberIDs(_ set: SmartRuleSet, db: GRDB.Database) throws -> Set<String>; static func alivePaths(_ set: SmartRuleSet, db: GRDB.Database) throws -> [String] }`
  - `memberIDs` = the combined `Set<file_id>` (AND/OR); reachability is NOT applied here.
  - `alivePaths` = distinct `paths.absolute_path` where `is_alive = 1` for those file_ids (order unspecified; the caller sorts).

**Design:** each rule evaluates to a `Set<file_id>` over the whole `files` table; `.all` intersects, `.any` unions. This is correct for both match modes and for mixing the in-memory color rule with SQL rules (no candidate-then-filter asymmetry). At personal scale (a few thousand files, a handful of rules) set algebra over id strings is trivially fast. An empty rule set → empty result.

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/SmartCollectionResolverTests.swift`:

```swift
import XCTest
import GRDB
@testable import Muse

final class SmartCollectionResolverTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    /// Insert a file (+ one alive path) with optional metadata.
    private func insert(_ db: GRDB.Database, id: String, kind: String = "image",
                        path: String, size: Int64? = nil, created: Int64? = nil,
                        modified: Int64? = nil, palette: [String]? = nil) throws {
        let pj = palette.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) } ?? nil
        try db.execute(sql: """
            INSERT INTO files (id, kind, size_bytes, created_at, modified_at, last_seen_at, palette)
            VALUES (?, ?, ?, ?, ?, 0, ?)
            """, arguments: [id, kind, size, created, modified, pj])
        try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES (?, ?, ?, 1)",
                       arguments: ["p_\(id)", id, path])
    }

    private func tag(_ db: GRDB.Database, fileID: String, dir: String, label: String) throws {
        try db.execute(sql: """
            INSERT INTO tags (id, file_id, parent_dir, label, source, model_version)
            VALUES (?, ?, ?, ?, 'manual', 'test')
            """, arguments: [UUID().uuidString, fileID, dir, label])
    }

    private func resolve(_ q: DatabaseQueue, _ set: SmartRuleSet) throws -> Set<String> {
        try q.read { db in try SmartCollectionResolver.memberIDs(set, db: db) }
    }

    func testKindRule() throws {
        let q = try makeQueue()
        try q.write { db in
            try insert(db, id: "a", kind: "image", path: "/x/a.jpg")
            try insert(db, id: "b", kind: "pdf", path: "/x/b.pdf")
        }
        let ids = try resolve(q, SmartRuleSet(match: .all, rules: [.kind(.pdf)]))
        XCTAssertEqual(ids, ["b"])
    }

    func testSizeRule() throws {
        let q = try makeQueue()
        try q.write { db in
            try insert(db, id: "a", path: "/x/a.jpg", size: 1_000_000)
            try insert(db, id: "b", path: "/x/b.jpg", size: 9_000_000)
        }
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [.size(op: .atMost, bytes: 5_000_000)])), ["a"])
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [.size(op: .atLeast, bytes: 5_000_000)])), ["b"])
    }

    func testDateWithinAndBounds() throws {
        let q = try makeQueue()
        try q.write { db in
            try insert(db, id: "old", path: "/x/o.jpg", created: 1_000)
            try insert(db, id: "new", path: "/x/n.jpg", created: 2_000)
        }
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [.date(field: .created, op: .after(1_500))])), ["new"])
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [.date(field: .created, op: .before(1_500))])), ["old"])
    }

    func testFilenameMatchesBasenameNotFullPath() throws {
        let q = try makeQueue()
        try q.write { db in
            // "invoice" appears in a's DIRECTORY but b's BASENAME. Only b matches.
            try insert(db, id: "a", path: "/invoice/photo.jpg")
            try insert(db, id: "b", path: "/x/invoice-2024.pdf", kind: "pdf")
        }
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [.filename(contains: "invoice")])), ["b"])
    }

    func testTagHasAndHasNotAnyLocation() throws {
        let q = try makeQueue()
        try q.write { db in
            try insert(db, id: "a", path: "/x/a.jpg")
            try insert(db, id: "b", path: "/x/b.jpg")
            try tag(db, fileID: "a", dir: "/x", label: "beach")
        }
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [.tag(op: .has, label: "beach")])), ["a"])
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [.tag(op: .hasNot, label: "beach")])), ["b"])
    }

    func testRatingComparisons() throws {
        let q = try makeQueue()
        try q.write { db in
            try insert(db, id: "a", path: "/x/a.jpg")
            try insert(db, id: "b", path: "/x/b.jpg")
            try tag(db, fileID: "a", dir: "/x", label: StarRating.label(for: 3)!)
            try tag(db, fileID: "b", dir: "/x", label: StarRating.label(for: 5)!)
        }
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [.rating(op: .atLeast, stars: 4)])), ["b"])
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [.rating(op: .equal, stars: 3)])), ["a"])
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [.rating(op: .atMost, stars: 3)])), ["a"])
    }

    func testColorRuleUsesPaletteMatch() throws {
        let q = try makeQueue()
        try q.write { db in
            try insert(db, id: "blue", path: "/x/blue.jpg", palette: ["#3a7bd5", "#204080"])
            try insert(db, id: "red", path: "/x/red.jpg", palette: ["#d53a3a", "#802020"])
            try insert(db, id: "none", path: "/x/none.jpg")   // no palette
        }
        let ids = try resolve(q, SmartRuleSet(match: .all, rules: [.color(.hex("#3a7bd5"))]))
        XCTAssertEqual(ids, ["blue"])
    }

    func testMatchAllIntersects() throws {
        let q = try makeQueue()
        try q.write { db in
            try insert(db, id: "a", kind: "image", path: "/x/a.jpg", size: 1_000)
            try insert(db, id: "b", kind: "image", path: "/x/b.jpg", size: 9_000)
        }
        let ids = try resolve(q, SmartRuleSet(match: .all, rules: [.kind(.image), .size(op: .atMost, bytes: 5_000)]))
        XCTAssertEqual(ids, ["a"])
    }

    func testMatchAnyUnions() throws {
        let q = try makeQueue()
        try q.write { db in
            try insert(db, id: "a", kind: "pdf", path: "/x/a.pdf", size: 9_000)
            try insert(db, id: "b", kind: "image", path: "/x/b.jpg", size: 1_000)
        }
        let ids = try resolve(q, SmartRuleSet(match: .any, rules: [.kind(.pdf), .size(op: .atMost, bytes: 5_000)]))
        XCTAssertEqual(ids, ["a", "b"])
    }

    func testEmptyRuleSetResolvesEmpty() throws {
        let q = try makeQueue()
        try q.write { db in try insert(db, id: "a", path: "/x/a.jpg") }
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [])), [])
    }

    func testAlivePathsExcludesDeadRows() throws {
        let q = try makeQueue()
        try q.write { db in
            try insert(db, id: "a", path: "/x/a.jpg")
            try db.execute(sql: "UPDATE paths SET is_alive = 0 WHERE file_id = 'a'")
        }
        let paths = try q.read { db in
            try SmartCollectionResolver.alivePaths(SmartRuleSet(match: .all, rules: [.kind(.image)]), db: db)
        }
        XCTAssertTrue(paths.isEmpty, "a file with no alive path contributes no tile")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/SmartCollectionResolverTests 2>&1 | tail -20`
Expected: FAIL — `SmartCollectionResolver` undefined.

- [ ] **Step 3: Write the resolver**

Create `Muse/Muse/Intelligence/Collections/SmartCollectionResolver.swift`:

```swift
//
//  SmartCollectionResolver.swift
//  Muse
//
//  Live membership for a smart collection: evaluate each SmartRule to a
//  Set<file_id> over the files table, then combine by Match.all (∩) / .any (∪).
//  Pure (takes a GRDB.Database) so it's fixture-testable. Reachability (under
//  an active root) is applied by the caller on the returned alive paths, using
//  the same CollectionStore.isUnderAnyRoot rule as manual collections.
//

import Foundation
import GRDB

enum SmartCollectionResolver {

    /// Combined matching file_ids (content rows). NOT reachability-filtered.
    static func memberIDs(_ set: SmartRuleSet, db: GRDB.Database) throws -> Set<String> {
        guard !set.rules.isEmpty else { return [] }
        let perRule = try set.rules.map { try evaluate($0, db: db) }
        switch set.match {
        case .all:
            return perRule.dropFirst().reduce(perRule[0]) { $0.intersection($1) }
        case .any:
            return perRule.reduce(into: Set<String>()) { $0.formUnion($1) }
        }
    }

    /// Distinct alive absolute paths for the matching members (what the grid
    /// renders, one tile per alive path). Empty when nothing matches.
    static func alivePaths(_ set: SmartRuleSet, db: GRDB.Database) throws -> [String] {
        let ids = try memberIDs(set, db: db)
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        return try String.fetchAll(db, sql: """
            SELECT DISTINCT absolute_path FROM paths
            WHERE is_alive = 1 AND file_id IN (\(placeholders))
            """, arguments: StatementArguments(Array(ids)))
    }

    // MARK: - Per-rule evaluation

    private static func evaluate(_ rule: SmartRule, db: GRDB.Database) throws -> Set<String> {
        switch rule {
        case let .kind(group):
            return try idSet(db, sql: "SELECT id FROM files WHERE kind IN (\(qmarks(group.kinds.count)))",
                             args: group.kinds)

        case let .size(op, bytes):
            let cmp = sqlComparison(op)
            return try idSet(db, sql: "SELECT id FROM files WHERE size_bytes IS NOT NULL AND size_bytes \(cmp) ?",
                             args: [bytes])

        case let .date(field, op):
            let col = field == .created ? "created_at" : "modified_at"
            switch op {
            case let .before(t):
                return try idSet(db, sql: "SELECT id FROM files WHERE \(col) IS NOT NULL AND \(col) < ?", args: [t])
            case let .after(t):
                return try idSet(db, sql: "SELECT id FROM files WHERE \(col) IS NOT NULL AND \(col) > ?", args: [t])
            case let .withinDays(days):
                // "within N days of now" — but the resolver is pure/deterministic
                // for tests, so callers that need "now" pass an absolute .after.
                // withinDays is converted to an absolute bound at rule-BUILD time
                // (see SmartCollectionRulesView). Here it degrades to a no-op-safe
                // relative bound using the row's own value is impossible; treat it
                // as "modified/created in the last N*86400s before the newest such
                // value in the library" is overkill — instead the builder stores
                // withinDays only for display and the SAVED rule is .after(epoch).
                // Defensive fallback: match everything so a stray withinDays never
                // silently empties a collection.
                _ = days
                return try idSet(db, sql: "SELECT id FROM files WHERE \(col) IS NOT NULL", args: [])
            }

        case let .filename(contains):
            // Pre-narrow with LIKE on the whole path, then keep only rows whose
            // BASENAME contains the term (case-insensitive) — LIKE alone would
            // also match a directory component.
            let needle = contains.lowercased()
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT file_id, absolute_path FROM paths
                WHERE is_alive = 1 AND LOWER(absolute_path) LIKE '%' || ? || '%'
                """, arguments: [needle])
            var out = Set<String>()
            for r in rows {
                guard let fid = r["file_id"] as String?, let p = r["absolute_path"] as String? else { continue }
                if (p as NSString).lastPathComponent.lowercased().contains(needle) { out.insert(fid) }
            }
            return out

        case let .tag(op, label):
            let has = try idSet(db, sql: "SELECT DISTINCT file_id FROM tags WHERE label = ?", args: [label])
            if op == .has { return has }
            // hasNot = every file MINUS those that have the tag (any location).
            let all = try idSet(db, sql: "SELECT id FROM files", args: [])
            return all.subtracting(has)

        case let .rating(op, stars):
            let labels = qualifyingRatingLabels(op: op, stars: stars)
            guard !labels.isEmpty else { return [] }
            return try idSet(db, sql: "SELECT DISTINCT file_id FROM tags WHERE label IN (\(qmarks(labels.count)))",
                             args: labels)

        case let .color(term):
            guard let target = colorLab(term) else { return [] }
            let rows = try Row.fetchAll(db, sql: "SELECT id, palette FROM files WHERE palette IS NOT NULL")
            var out = Set<String>()
            for row in rows {
                guard let id = row["id"] as String?,
                      let json = row["palette"] as String?,
                      let data = json.data(using: .utf8),
                      let hexes = try? JSONDecoder().decode([String].self, from: data) else { continue }
                let palette: [LabColor] = hexes.compactMap { hex in
                    NamedColor.parse(hex).map { LabColor(rgb: RGB(r: $0.0, g: $0.1, b: $0.2)) }
                }
                if PaletteMatch.matches(query: [target], palette: palette,
                                        threshold: ColorDistance.nearThreshold) {
                    out.insert(id)
                }
            }
            return out
        }
    }

    // MARK: - Helpers

    private static func idSet(_ db: GRDB.Database, sql: String,
                              args: [DatabaseValueConvertible]) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: sql, arguments: StatementArguments(args)))
    }

    private static func qmarks(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ",")
    }

    private static func sqlComparison(_ op: Comparison) -> String {
        switch op { case .atLeast: return ">="; case .equal: return "="; case .atMost: return "<=" }
    }

    /// The star-glyph labels a rating rule matches, e.g. atLeast 4 → ["★★★★","★★★★★"].
    private static func qualifyingRatingLabels(op: Comparison, stars: Int) -> [String] {
        let range: [Int]
        switch op {
        case .atLeast: range = Array(stars...StarRating.maxStars)
        case .equal:   range = [stars]
        case .atMost:  range = Array(1...stars)
        }
        return range.compactMap { StarRating.label(for: $0) }
    }

    /// A color term → its LAB target, or nil if it can't be decoded.
    private static func colorLab(_ term: ColorTerm) -> LabColor? {
        switch term {
        case let .hex(h):
            return SmartRule.parsedHex(h).map { LabColor(rgb: $0) }
        case let .name(n):
            // Reuse NamedColor's name table (it decodes both names and hex).
            return NamedColor.parse(n).map { LabColor(rgb: RGB(r: $0.0, g: $0.1, b: $0.2)) }
        }
    }
}
```

Verify `StarRating.maxStars` exists (it does: `Muse/Muse/Models/StarRating.swift`). Verify `NamedColor.parse` accepts a color *name* (not only hex); if it only decodes hex, the `.name` color term will resolve `nil` and match nothing — acceptable for v1 (the UI value field accepts hex; a bare name is a soft path). Confirm during Step 4 and, if names don't resolve, leave the `.name` fallback as-is (documented).

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/SmartCollectionResolverTests 2>&1 | tail -30`
Expected: PASS (all cases). Fix any SQL/column mismatches revealed.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Intelligence/Collections/SmartCollectionResolver.swift Muse/MuseTests/SmartCollectionResolverTests.swift
git commit -m "feat: SmartCollectionResolver — live per-rule set algebra over the DB"
```

---

## Task 4: `CollectionStore` smart CRUD + smart-aware counts

**Files:**
- Modify: `Muse/Muse/Intelligence/Collections/CollectionStore.swift`
- Test: extend `Muse/MuseTests/SmartCollectionResolverTests.swift` (or a new `SmartCollectionStoreTests.swift`)

**Interfaces:**
- Produces:
  - `static func createSmart(queue:, name: String, ruleSet: SmartRuleSet) async throws -> String` — inserts a `model_version = 'manual'` row with `smart_rules` set, appended at the bottom sort slot; returns id.
  - `static func setSmartRules(queue:, id: String, name: String?, ruleSet: SmartRuleSet) async throws` — updates `smart_rules` (+ name if non-nil).
  - `static func makeSmart(queue:, id: String, ruleSet: SmartRuleSet) async throws` — sets `smart_rules` AND `DELETE FROM collection_members WHERE collection_id = ?`; forces `model_version = 'manual'`.
  - `static func smartRuleSet(queue:, id: String) async throws -> SmartRuleSet?` — decoded rules for a row, or nil if not smart.
  - `static func alivePathsResolving(queue:, collectionID: String, limit: Int? = nil) async throws -> [String]` — smart → resolver.alivePaths; else the existing `alivePaths` SQL.
  - `fetchAll` now computes `aliveCount`/`memberIDs` for smart rows via the resolver.

- [ ] **Step 1: Write the failing test**

Add to `SmartCollectionResolverTests.swift` (append inside the class):

```swift
    func testCreateSmartAndResolveAlivePaths() async throws {
        let q = try makeQueue()
        try await q.write { db in
            try self.insert(db, id: "a", kind: "pdf", path: "/x/a.pdf")
            try self.insert(db, id: "b", kind: "image", path: "/x/b.jpg")
        }
        let set = SmartRuleSet(match: .all, rules: [.kind(.pdf)])
        let id = try await CollectionStore.createSmart(queue: q, name: "PDFs", ruleSet: set)

        let back = try await CollectionStore.smartRuleSet(queue: q, id: id)
        XCTAssertEqual(back, set)

        let paths = try await CollectionStore.alivePathsResolving(queue: q, collectionID: id)
        XCTAssertEqual(paths, ["/x/a.pdf"])
    }

    func testFetchAllCountsSmartCollectionLive() async throws {
        let q = try makeQueue()
        try await q.write { db in
            try self.insert(db, id: "a", kind: "pdf", path: "/root/a.pdf")
            try self.insert(db, id: "b", kind: "pdf", path: "/root/b.pdf")
            try self.insert(db, id: "c", kind: "image", path: "/root/c.jpg")
        }
        _ = try await CollectionStore.createSmart(queue: q, name: "PDFs",
                                                  ruleSet: SmartRuleSet(match: .all, rules: [.kind(.pdf)]))
        let all = try await CollectionStore.fetchAll(queue: q, rootPaths: ["/root"])
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].aliveCount, 2, "two PDFs match, resolved live")
    }

    func testMakeSmartDropsMembers() async throws {
        let q = try makeQueue()
        try await q.write { db in
            try self.insert(db, id: "a", kind: "pdf", path: "/root/a.pdf")
        }
        let cid = try await CollectionStore.createManual(queue: q)  // empty manual
        try await CollectionStore.addFile(queue: q, fileID: "a", collectionID: cid)
        try await CollectionStore.makeSmart(queue: q, id: cid,
                                            ruleSet: SmartRuleSet(match: .all, rules: [.kind(.image)]))
        let members = try await q.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collection_members WHERE collection_id = ?",
                             arguments: [cid]) ?? -1
        }
        XCTAssertEqual(members, 0, "hand-picked members are removed on conversion")
        XCTAssertNotNil(try await CollectionStore.smartRuleSet(queue: q, id: cid))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/SmartCollectionResolverTests 2>&1 | tail -20`
Expected: FAIL — `createSmart` / `smartRuleSet` / `alivePathsResolving` / `makeSmart` undefined.

- [ ] **Step 3: Add the CRUD methods**

In `CollectionStore.swift`, add these methods inside `enum CollectionStore` (e.g. after `createManual(queue:)` at ~`:193`):

```swift
    /// Create a smart collection: a manual-marked row (so the reclusterer never
    /// prunes it and it stays visible even when its rules match nothing) whose
    /// membership is defined by `ruleSet`, held as JSON in smart_rules. No member
    /// rows — membership resolves live.
    @discardableResult
    static func createSmart(queue: DatabaseQueue, name: String, ruleSet: SmartRuleSet) async throws -> String {
        let id = UUID().uuidString
        let now = Int64(Date().timeIntervalSince1970)
        let json = ruleSet.encodedJSON()
        try await queue.write { db in
            let order = try nextSortOrder(db)
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order, smart_rules)
                VALUES (?, ?, 0, 'manual', ?, ?, ?, ?)
                """, arguments: [id, name, now, now, order, json])
        }
        return id
    }

    /// Replace a smart collection's rules (and optionally its name).
    static func setSmartRules(queue: DatabaseQueue, id: String, name: String?,
                              ruleSet: SmartRuleSet) async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let json = ruleSet.encodedJSON()
        try await queue.write { db in
            if let name {
                try db.execute(sql: "UPDATE collections SET name = ?, smart_rules = ?, updated_at = ? WHERE id = ?",
                               arguments: [name, json, now, id])
            } else {
                try db.execute(sql: "UPDATE collections SET smart_rules = ?, updated_at = ? WHERE id = ?",
                               arguments: [json, now, id])
            }
        }
    }

    /// Convert an existing (manual/auto) collection into a smart one: set its
    /// rules, force model_version = 'manual' (protection + empty-visibility), and
    /// drop its hand-picked members (they're replaced by rule-based membership).
    static func makeSmart(queue: DatabaseQueue, id: String, ruleSet: SmartRuleSet) async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let json = ruleSet.encodedJSON()
        try await queue.write { db in
            try db.execute(sql: """
                UPDATE collections SET smart_rules = ?, model_version = 'manual', updated_at = ? WHERE id = ?
                """, arguments: [json, now, id])
            try db.execute(sql: "DELETE FROM collection_members WHERE collection_id = ?", arguments: [id])
        }
    }

    /// Decoded rule set for a smart collection, or nil if the row isn't smart.
    static func smartRuleSet(queue: DatabaseQueue, id: String) async throws -> SmartRuleSet? {
        try await queue.read { db in
            guard let json = try String.fetchOne(db, sql: "SELECT smart_rules FROM collections WHERE id = ?",
                                                 arguments: [id]) else { return nil }
            return SmartRuleSet.decode(json)
        }
    }

    /// Alive absolute paths for ANY collection — resolving smart collections via
    /// their rules and reading member rows for the rest. The single seam so
    /// setActiveCollection / exportableURLs / cover mosaics stay collection-kind
    /// agnostic. `limit` caps the returned paths (cover thumbnails).
    static func alivePathsResolving(queue: DatabaseQueue, collectionID: String,
                                    limit: Int? = nil) async throws -> [String] {
        if let set = try await smartRuleSet(queue: queue, id: collectionID) {
            let paths = try await queue.read { db in
                try SmartCollectionResolver.alivePaths(set, db: db)
            }
            if let limit { return Array(paths.prefix(limit)) }
            return paths
        }
        return try await alivePaths(queue: queue, collectionID: collectionID, limit: limit)
    }
```

- [ ] **Step 4: Make `fetchAll` smart-aware**

In `fetchAll` (`CollectionStore.swift:269-297`), replace the per-row `map` body so a smart row resolves live. Change the `rows.map { row in … }` closure to:

```swift
            return try rows.map { row in
                // Smart collections hold no member rows — resolve alive paths from
                // their rules. Everything else reads collection_members as before.
                let alivePaths: [String]
                let members: [String]
                if let json = row.smart_rules, let set = SmartRuleSet.decode(json) {
                    alivePaths = try SmartCollectionResolver.alivePaths(set, db: db)
                    members = Array(try SmartCollectionResolver.memberIDs(set, db: db))
                } else {
                    members = try String.fetchAll(db, sql:
                        "SELECT file_id FROM collection_members WHERE collection_id = ?",
                        arguments: [row.id])
                    alivePaths = try String.fetchAll(db, sql: """
                        SELECT DISTINCT p.absolute_path FROM paths p
                        JOIN collection_members m ON m.file_id = p.file_id
                        WHERE m.collection_id = ? AND p.is_alive = 1
                        """, arguments: [row.id])
                }
                let alive = rootPaths.isEmpty
                    ? alivePaths.count
                    : alivePaths.filter { isUnderAnyRoot($0, roots: rootPaths) }.count
                return Loaded(collection: row, memberIDs: members, aliveCount: alive,
                              coverFileID: row.cover_file_id)
            }
```

The existing `.filter { $0.aliveCount > 0 || $0.collection.model_version == "manual" }` keeps a zero-match smart collection visible (it's `model_version == "manual"`), and `.sorted { $0.aliveCount > $1.aliveCount }` is unchanged.

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/SmartCollectionResolverTests 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Intelligence/Collections/CollectionStore.swift Muse/MuseTests/SmartCollectionResolverTests.swift
git commit -m "feat: CollectionStore smart CRUD + smart-aware fetchAll counts"
```

---

## Task 5: Wire live contents into `AppState.setActiveCollection` + `exportableURLs`

**Files:**
- Modify: `Muse/Muse/Models/AppState+Filters.swift:142` and `:193`

**Interfaces:**
- Consumes: `CollectionStore.alivePathsResolving`.

There is no unit test for `AppState` (it's `@MainActor` UI state); correctness is covered by the resolver/store tests + the runtime verification in Task 11.

- [ ] **Step 1: Route opening a collection through the resolver**

In `setActiveCollection` (`AppState+Filters.swift:142`), replace:

```swift
            let paths = (try? await CollectionStore.alivePaths(
                queue: q, collectionID: id
            )) ?? []
```

with:

```swift
            let paths = (try? await CollectionStore.alivePathsResolving(
                queue: q, collectionID: id
            )) ?? []
```

- [ ] **Step 2: Route sidebar-menu export through the resolver**

In `exportableURLs(forCollection:)` (`AppState+Filters.swift:193`), replace:

```swift
        let paths = (try? await CollectionStore.alivePaths(queue: q, collectionID: id)) ?? []
```

with:

```swift
        let paths = (try? await CollectionStore.alivePathsResolving(queue: q, collectionID: id)) ?? []
```

- [ ] **Step 3: Build & run the full suite**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Models/AppState+Filters.swift
git commit -m "feat: open + export smart collections via alivePathsResolving"
```

---

## Task 6: Reclustering safety — confirm smart collections are untouched

**Files:**
- Test: `Muse/MuseTests/SmartCollectionResolverTests.swift` (append)

Smart collections use `model_version = 'manual'`, so `CollectionStore.protectedCollectionIDs` already returns them and the recluster stale-sweep (`CollectionsEngine.swift:154-161`) skips them. This task locks that with a test — no production change unless the test fails.

- [ ] **Step 1: Write the protection test**

Append to `SmartCollectionResolverTests.swift`:

```swift
    func testSmartCollectionIsProtectedFromStaleSweep() async throws {
        let q = try makeQueue()
        try await q.write { db in try self.insert(db, id: "a", kind: "pdf", path: "/root/a.pdf") }
        let id = try await CollectionStore.createSmart(queue: q, name: "PDFs",
                                                       ruleSet: SmartRuleSet(match: .all, rules: [.kind(.pdf)]))
        let protectedIDs = try await CollectionStore.protectedCollectionIDs(queue: q)
        XCTAssertTrue(protectedIDs.contains(id), "smart collections (model_version=manual) survive reclustering")
    }
```

- [ ] **Step 2: Run test**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/SmartCollectionResolverTests/testSmartCollectionIsProtectedFromStaleSweep 2>&1 | tail -10`
Expected: PASS. If it fails, the fix is to add smart ids to `protectedCollectionIDs`; it should already pass because `createSmart` writes `model_version = 'manual'`.

- [ ] **Step 3: Commit**

```bash
git add Muse/MuseTests/SmartCollectionResolverTests.swift
git commit -m "test: lock smart collections against the recluster stale-sweep"
```

---

## Task 7: Rule-builder sheet — `SmartCollectionRulesView`

**Files:**
- Create: `Muse/Muse/Views/Sidebar/SmartCollectionRulesView.swift`

**Interfaces:**
- Consumes: `SmartRuleSet`, `SmartRule`, `CollectionStore.createSmart` / `setSmartRules` / `makeSmart`, `CollectionsEngine.shared.reload()`, `.windowFittedSheetHeight`.
- Produces: `struct SmartCollectionRulesView: View` initialized with either a new draft or an existing collection's `(id, name, SmartRuleSet)`, plus an `onClose` and an optional `onConvertConfirmNeeded` flag.

Draft state (name, match, `[SmartRule]`) is local `@State`; nothing writes to `AppState`/DB until Save. Save is disabled until name is non-empty and `ruleSet.isValid`.

- [ ] **Step 1: Write the view**

Create `Muse/Muse/Views/Sidebar/SmartCollectionRulesView.swift`:

```swift
//
//  SmartCollectionRulesView.swift
//  Muse
//
//  The mail-style rule builder for a smart collection: a Name field, a
//  Match All/Any toggle, and a list of rule rows (type ▾ · operator ▾ · value).
//  Draft state is local @State — it commits to CollectionStore only on Save
//  (never per keystroke to AppState). Save is gated on a non-empty name and a
//  valid rule set. Presented via .windowFittedSheetHeight (its body scrolls).
//

import SwiftUI

struct SmartCollectionRulesView: View {
    /// nil id = creating a new smart collection; non-nil = editing / converting.
    let collectionID: String?
    /// When true (converting a manual collection with members), Save shows a
    /// data-loss confirm before writing.
    let confirmConversion: Bool
    let onClose: () -> Void

    @State private var name: String
    @State private var match: SmartRuleSet.Match
    @State private var rules: [SmartRule]
    @State private var showConvertConfirm = false

    init(collectionID: String?, initialName: String, initialSet: SmartRuleSet,
         confirmConversion: Bool = false, onClose: @escaping () -> Void) {
        self.collectionID = collectionID
        self.confirmConversion = confirmConversion
        self.onClose = onClose
        _name = State(initialValue: initialName)
        _match = State(initialValue: initialSet.match)
        _rules = State(initialValue: initialSet.rules.isEmpty ? [.tag(op: .has, label: "")] : initialSet.rules)
    }

    private var ruleSet: SmartRuleSet { SmartRuleSet(match: match, rules: rules) }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && ruleSet.isValid }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Smart Collection")
                    .font(.system(size: 24, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                SheetCloseButton { onClose() }
            }
            .padding(.bottom, 20)

            TextField(String(localized: "Name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .padding(.bottom, 14)

            HStack(spacing: 8) {
                Text("Match")
                Picker("", selection: $match) {
                    Text("All").tag(SmartRuleSet.Match.all)
                    Text("Any").tag(SmartRuleSet.Match.any)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Text("of the following rules")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(rules.indices, id: \.self) { i in
                        SmartRuleRow(rule: $rules[i]) {
                            if rules.count > 1 { rules.remove(at: i) }
                        }
                    }
                }
            }
            .frame(minHeight: 120)

            Button {
                rules.append(.tag(op: .has, label: ""))
            } label: {
                Label("Add Rule", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if confirmConversion { showConvertConfirm = true } else { save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(.top, 20)
        }
        .padding(28)
        .windowFittedSheetHeight(width: 520, ideal: 560)
        .alert("Replace this collection’s items with rules?", isPresented: $showConvertConfirm) {
            Button("Replace", role: .destructive) { save() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The images you added by hand are removed from this collection and replaced by rule-based membership. Your files stay on disk.")
        }
    }

    private func save() {
        let set = ruleSet
        let finalName = name.trimmingCharacters(in: .whitespaces)
        let id = collectionID
        let convert = confirmConversion
        onClose()
        Task { @MainActor in
            guard let q = Database.shared.dbQueue else { return }
            if let id {
                if convert {
                    try? await CollectionStore.makeSmart(queue: q, id: id, ruleSet: set)
                    try? await CollectionStore.rename(queue: q, id: id, name: finalName)
                } else {
                    try? await CollectionStore.setSmartRules(queue: q, id: id, name: finalName, ruleSet: set)
                }
            } else {
                _ = try? await CollectionStore.createSmart(queue: q, name: finalName, ruleSet: set)
            }
            await CollectionsEngine.shared.reload()
        }
    }
}
```

- [ ] **Step 2: Write the rule row**

Append to the same file (`SmartCollectionRulesView.swift`):

```swift
/// One editable rule: a type picker, a type-specific operator + value control,
/// and a remove button. All edits mutate the bound `SmartRule` in place.
private struct SmartRuleRow: View {
    @Binding var rule: SmartRule
    let onRemove: () -> Void

    // A stable "kind" discriminator for the type picker.
    private enum Kind: String, CaseIterable, Identifiable {
        case rating, color, tag, kind, date, filename, size
        var id: String { rawValue }
        var label: String {
            switch self {
            case .rating:   return String(localized: "Rating")
            case .color:    return String(localized: "Color")
            case .tag:      return String(localized: "Tag")
            case .kind:     return String(localized: "Kind")
            case .date:     return String(localized: "Date")
            case .filename: return String(localized: "Filename")
            case .size:     return String(localized: "Size")
            }
        }
    }

    private var currentKind: Kind {
        switch rule {
        case .rating:   return .rating
        case .color:    return .color
        case .tag:      return .tag
        case .kind:     return .kind
        case .date:     return .date
        case .filename: return .filename
        case .size:     return .size
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { currentKind },
                set: { rule = SmartRuleRow.defaultRule(for: $0) })) {
                ForEach(Kind.allCases) { k in Text(k.label).tag(k) }
            }
            .labelsHidden()
            .frame(width: 120)

            valueControls

            Spacer(minLength: 4)
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Remove rule"))
        }
    }

    /// A sensible default rule when the type changes.
    static func defaultRule(for kind: Kind) -> SmartRule {
        switch kind {
        case .rating:   return .rating(op: .atLeast, stars: 4)
        case .color:    return .color(.hex(""))
        case .tag:      return .tag(op: .has, label: "")
        case .kind:     return .kind(.image)
        case .date:     return .date(field: .modified, op: .withinDays(30))
        case .filename: return .filename(contains: "")
        case .size:     return .size(op: .atMost, bytes: 5_000_000)
        }
    }

    @ViewBuilder private var valueControls: some View {
        switch rule {
        case let .rating(op, stars):
            comparisonPicker(op) { rule = .rating(op: $0, stars: stars) }
            Stepper(value: Binding(get: { stars },
                                   set: { rule = .rating(op: op, stars: min(5, max(1, $0))) }),
                    in: 1...5) {
                Text("\(stars) ★")
            }
            .fixedSize()

        case let .color(term):
            // v1 is hex-only: NamedColor.parse decodes hex, not color names, so a
            // bare name would silently match nothing. The COLORS card copies hex,
            // which is the intended input. (.name stays in the model for a future
            // named-color table.)
            TextField(String(localized: "#hex"),
                      text: Binding(get: { colorString(term) },
                                    set: { rule = .color(.hex($0)) }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)

        case let .tag(op, label):
            Picker("", selection: Binding(get: { op },
                                          set: { rule = .tag(op: $0, label: label) })) {
                Text("has").tag(HasOp.has)
                Text("has no").tag(HasOp.hasNot)
            }.labelsHidden().frame(width: 90)
            TextField(String(localized: "tag"),
                      text: Binding(get: { label }, set: { rule = .tag(op: op, label: $0) }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)

        case let .kind(group):
            Picker("", selection: Binding(get: { group },
                                          set: { rule = .kind($0) })) {
                ForEach(SmartRule.KindGroup.allCases, id: \.self) { g in
                    Text(kindLabel(g)).tag(g)
                }
            }.labelsHidden().frame(width: 140)

        case let .date(field, op):
            Picker("", selection: Binding(get: { field },
                                          set: { rule = .date(field: $0, op: op) })) {
                Text("created").tag(DateField.created)
                Text("modified").tag(DateField.modified)
            }.labelsHidden().frame(width: 110)
            dateOpControls(field: field, op: op)

        case let .filename(contains):
            TextField(String(localized: "contains"),
                      text: Binding(get: { contains }, set: { rule = .filename(contains: $0) }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

        case let .size(op, bytes):
            comparisonPicker(op) { rule = .size(op: $0, bytes: bytes) }
            let mb = Binding(get: { Double(bytes) / 1_000_000 },
                             set: { rule = .size(op: op, bytes: Int64(max(0, $0) * 1_000_000)) })
            TextField("MB", value: mb, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
            Text("MB").foregroundStyle(.secondary)
        }
    }

    // MARK: - small helpers

    @ViewBuilder private func comparisonPicker(_ op: Comparison,
                                               _ set: @escaping (Comparison) -> Void) -> some View {
        Picker("", selection: Binding(get: { op }, set: set)) {
            Text("≥").tag(Comparison.atLeast)
            Text("=").tag(Comparison.equal)
            Text("≤").tag(Comparison.atMost)
        }.labelsHidden().frame(width: 70)
    }

    @ViewBuilder private func dateOpControls(field: DateField, op: DateOp) -> some View {
        // v1: "within N days" only (before/after are stored but the builder
        // exposes the common relative case; N is converted to an absolute
        // .after bound at Save time by the parent). Keep the UI to a stepper.
        let days = Binding<Int>(
            get: { if case let .withinDays(d) = op { return d } else { return 30 } },
            set: { rule = .date(field: field, op: .withinDays(max(1, $0))) })
        Stepper(value: days, in: 1...3650) {
            Text("within \(days.wrappedValue) days")
        }.fixedSize()
    }

    private func kindLabel(_ g: SmartRule.KindGroup) -> String {
        switch g {
        case .image:    return String(localized: "Images")
        case .raw:      return String(localized: "RAW")
        case .pdf:      return String(localized: "PDFs")
        case .video:    return String(localized: "Videos")
        case .audio:    return String(localized: "Audio")
        case .document: return String(localized: "Documents")
        }
    }

    private func colorString(_ term: ColorTerm) -> String {
        switch term { case let .name(n): return n; case let .hex(h): return h }
    }
}
```

**Note on `withinDays` at Save time:** the resolver treats a persisted `.withinDays` defensively (matches all). To make "within N days" actually filter, convert it to an absolute `.after(now − N·86400)` in `SmartCollectionRulesView.save()` before persisting. Add this transform in Step 3.

- [ ] **Step 3: Convert relative dates to absolute at Save**

In `SmartCollectionRulesView.save()`, compute the resolved set before persisting:

```swift
    private func save() {
        let now = Int64(Date().timeIntervalSince1970)
        let resolvedRules = rules.map { rule -> SmartRule in
            if case let .date(field, .withinDays(d)) = rule {
                return .date(field: field, op: .after(now - Int64(d) * 86_400))
            }
            return rule
        }
        let set = SmartRuleSet(match: match, rules: resolvedRules)
        let finalName = name.trimmingCharacters(in: .whitespaces)
        // …rest unchanged (uses `set`)…
```

Replace the earlier `let set = ruleSet` line with this block. This keeps the stored rule an absolute, deterministic bound (matching the resolver's tested `.after` path), so "within 30 days" means "after the timestamp 30 days before you saved." (Documented tradeoff: the bound is fixed at save time, not re-evaluated daily — acceptable for v1; a future version can persist `.withinDays` and resolve "now" in the resolver.)

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: BUILD SUCCEEDED. Fix any SwiftUI type-inference errors (segmented Picker tags, Binding closures).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Views/Sidebar/SmartCollectionRulesView.swift
git commit -m "feat: SmartCollectionRulesView — mail-style rule builder sheet"
```

---

## Task 8: Entry points — Collections page `+` menu + sidebar context menu

**Files:**
- Modify: `Muse/Muse/Views/CollectionsPage.swift:138,170-185`
- Modify: `Muse/Muse/Views/Sidebar/CollectionSidebarRow.swift`

- [ ] **Step 1: Collections page `+` becomes a menu**

In `CollectionsPage.swift`, add sheet state near the other `@State` in the page view:

```swift
    @State private var showingNewSmart = false
```

Replace the `AddCollectionButton { createCollection() }` usage (`:138`) with a menu:

```swift
            Menu {
                Button("New Collection") { createCollection() }
                Button("New Smart Collection…") { showingNewSmart = true }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New Collection")
            .accessibilityLabel("New Collection")
```

Attach the sheet to the page's root view (alongside existing modifiers):

```swift
            .sheet(isPresented: $showingNewSmart) {
                SmartCollectionRulesView(collectionID: nil,
                                         initialName: defaultSmartName(),
                                         initialSet: SmartRuleSet(match: .all, rules: [])) {
                    showingNewSmart = false
                }
            }
```

Add a helper next to `createCollection()` for the default name (reuse `ManualCollectionName`):

```swift
    private func defaultSmartName() -> String {
        let names = appState.sidebarCollections.map { $0.collection.name }
        return ManualCollectionName.next(existing: names)
    }
```

(If `AddCollectionButton` becomes unused, leave it — removing it is unrelated churn; or delete it if nothing else references it after this change. Verify with a grep before deleting.)

- [ ] **Step 2: Sidebar context-menu entry + sheet**

In `CollectionSidebarRow.swift`, add state near the other `@State` (`:37`):

```swift
    @State private var showingRules = false
```

Compute whether this row is smart from its stored rules (add a computed property):

```swift
    private var isSmart: Bool { loaded.collection.smart_rules != nil }
    private var memberCount: Int { loaded.aliveCount }
```

In the `.contextMenu { … }` (after "Change Symbol & Color…", `:134`), add:

```swift
            if isSmart {
                Button("Edit Rules…") { showingRules = true }
            } else {
                Button("Make Smart…") { showingRules = true }
            }
```

Mirror it in `.accessibilityActions { … }` (after the "Change Symbol & Color" action, `:158`):

```swift
            Button(isSmart ? String(localized: "Edit Rules") : String(localized: "Make Smart")) { showingRules = true }
```

Add the sheet next to the existing `.sheet(isPresented: $showingCustomize)` (`:187`):

```swift
        .sheet(isPresented: $showingRules) {
            SmartCollectionRulesView(
                collectionID: id,
                initialName: loaded.collection.name,
                initialSet: loaded.collection.smart_rules.flatMap(SmartRuleSet.decode)
                    ?? SmartRuleSet(match: .all, rules: []),
                confirmConversion: !isSmart && memberCount > 0) {
                showingRules = false
            }
        }
```

`confirmConversion: !isSmart && memberCount > 0` shows the data-loss confirm only when converting a hand-made collection that actually has members. Editing an existing smart collection (or an empty manual one) saves without the confirm.

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Views/CollectionsPage.swift Muse/Muse/Views/Sidebar/CollectionSidebarRow.swift
git commit -m "feat: entry points for new/edit smart collections (page + · sidebar menu)"
```

---

## Task 9: Distinct default icon for smart collections

**Files:**
- Modify: `Muse/Muse/Views/Sidebar/CollectionSidebarRow.swift` (icon resolution)
- Modify: `Muse/Muse/Components/CollectionAppearance.swift` (add a smart default constant)

A smart collection with no user-chosen icon shows a rules/funnel glyph instead of the classic stack, so it reads differently in the sidebar. A user-set icon (v10) still wins.

- [ ] **Step 1: Add a smart default icon constant**

In `CollectionAppearance.swift`, add near `defaultIcon`:

```swift
    /// The default sidebar glyph for a SMART collection when the user hasn't
    /// chosen one (v10). Reads as "rule-driven" vs. the classic stack.
    static let smartDefaultIcon = "line.3.horizontal.decrease.circle"
```

- [ ] **Step 2: Use it in the row's icon resolution**

Find where `CollectionSidebarRow` resolves the icon (a call to `CollectionAppearance.resolvedIcon(loaded.collection.icon)`). Replace it with a smart-aware resolution:

```swift
    private var resolvedIcon: String {
        if let icon = loaded.collection.icon { return icon }        // user override wins
        return isSmart ? CollectionAppearance.smartDefaultIcon : CollectionAppearance.defaultIcon
    }
```

and use `resolvedIcon` where the icon `Image(systemName:)` is built. (Search the file for `resolvedIcon(` / `defaultIcon` and the `Image(systemName:` in the row body; substitute the computed property.)

- [ ] **Step 3: Build & verify existing appearance tests still pass**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/CollectionAppearanceTests 2>&1 | tail -10`
Expected: PASS (the constant is additive; `resolvedIcon(nil)` for non-smart is unchanged).

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Views/Sidebar/CollectionSidebarRow.swift Muse/Muse/Components/CollectionAppearance.swift
git commit -m "feat: distinct default sidebar icon for smart collections"
```

---

## Task 10: Backup / restore carries `smart_rules`

**Files:**
- Modify: `Muse/Muse/Backup/BackupArchive.swift:39-51` (`BackupCollection`)
- Modify: `Muse/Muse/Backup/BackupBuilder.swift:102-106`
- Modify: `Muse/Muse/Backup/CollectionMaterializer.swift:17-52`
- Modify: `Muse/Muse/Backup/ReconnectApplier.swift:86-94`
- Test: `Muse/MuseTests/CollectionMaterializerTests.swift` (append)

A smart collection has no members; it's `model_version = 'manual'`, so `CollectionMaterializer` already keeps it (empty manual isn't dropped). It must carry `smart_rules` end-to-end so the restored library re-resolves membership from its own files.

- [ ] **Step 1: Write the failing materializer test**

Append to `CollectionMaterializerTests.swift`:

```swift
    func testSmartRulesCarryThroughMaterialize() {
        let smart = BackupCollection(
            id: "s1", name: "PDFs", sort_order: 0, model_version: "manual", is_hidden: 0,
            cover_hash: nil, members: [], excluded_hashes: [],
            icon: nil, color: nil, smart_rules: "{\"match\":\"all\",\"rules\":[]}")
        let out = CollectionMaterializer.materialize([smart], fileIDForHash: [:])
        XCTAssertEqual(out.count, 1, "an empty smart (manual) collection is kept")
        XCTAssertEqual(out[0].smartRules, "{\"match\":\"all\",\"rules\":[]}")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/CollectionMaterializerTests 2>&1 | tail -15`
Expected: FAIL — `BackupCollection`/`MaterializedCollection` have no `smart_rules`/`smartRules`.

- [ ] **Step 3: Add the field to `BackupCollection`**

In `BackupArchive.swift`, add to `BackupCollection` after `color` (`:50`):

```swift
    var smart_rules: String? = nil   // v12; optional so pre-smart archives decode
```

- [ ] **Step 4: Emit it in `BackupBuilder`**

In `BackupBuilder.swift` (`:102-106`), add `smart_rules: c.smart_rules` to the `BackupCollection(...)` initializer call:

```swift
                collections.append(BackupCollection(
                    id: c.id, name: c.name, sort_order: c.sort_order,
                    model_version: c.model_version, is_hidden: c.is_hidden,
                    cover_hash: coverHash, members: members, excluded_hashes: excluded,
                    icon: c.icon, color: c.color, smart_rules: c.smart_rules))
```

(Match the existing argument order/labels in that call — insert `smart_rules:` last.)

- [ ] **Step 5: Carry it through `CollectionMaterializer`**

In `CollectionMaterializer.swift`, add to `MaterializedCollection` after `color` (`:27`):

```swift
    var smartRules: String? = nil
```

and pass it in the `MaterializedCollection(...)` build (`:46-52`):

```swift
                icon: c.icon, color: c.color, smartRules: c.smart_rules))
```

- [ ] **Step 6: Restore it in `ReconnectApplier`**

In `ReconnectApplier.swift` (`:86-94`), extend the collections INSERT to include `smart_rules`:

```swift
                    INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, cover_file_id, sort_order, icon, color, smart_rules)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
```

and add `c.smartRules` to the arguments array (last, matching the new column):

```swift
                                     c.coverFileID, c.sortOrder, c.icon, c.color, c.smartRules])
```

(Verify the `created_at`/`updated_at` argument expressions already present in that call are unchanged; only append the `smart_rules` column + value.)

- [ ] **Step 7: Run tests to verify they pass**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/CollectionMaterializerTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Muse/Muse/Backup/BackupArchive.swift Muse/Muse/Backup/BackupBuilder.swift Muse/Muse/Backup/CollectionMaterializer.swift Muse/Muse/Backup/ReconnectApplier.swift Muse/MuseTests/CollectionMaterializerTests.swift
git commit -m "feat: back up + restore smart_rules on collections"
```

---

## Task 11: Localization + runtime verification + docs

**Files:**
- Modify: `Muse/Muse/…` (any remaining bare-`String` labels), `Localizable.xcstrings`
- Modify: `CLAUDE.md` phase log + a `docs/session-log.md` entry

- [ ] **Step 1: Sweep for unlocalized strings**

All SwiftUI text literals in the new views auto-extract. Verify no bare `String` (non-`String(localized:)`) user-facing text remains in `SmartCollectionRulesView.swift`, `SmartRule.swift` summaries (if any), the two menu items, and the confirm dialog. The operator glyphs (`≥`/`=`/`≤`, `★`) are language-neutral. Grep:

Run: `grep -rn 'Text("\|Button("\|"\.\.\.\|placeholder' Muse/Muse/Views/Sidebar/SmartCollectionRulesView.swift`
Confirm each literal is inside a SwiftUI text position (auto-extracted) or wrapped in `String(localized:)`.

- [ ] **Step 2: Export + fill French**

Run:
```bash
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj -localizationPath /tmp/muse-loc -exportLanguage fr 2>&1 | tail -5
```
Fill the new empty `fr` values in `Muse/Muse/Localizable.xcstrings` (e.g. "New Smart Collection…" → "Nouvelle collection intelligente…", "Make Smart…" → "Rendre intelligente…", "Edit Rules…" → "Modifier les règles…", "Match" → "Correspondance", "Add Rule" → "Ajouter une règle", rule-type + kind labels, the confirm dialog title/body). Re-run the export to confirm 0 untranslated.

- [ ] **Step 3: Full unit suite green**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: all tests pass (existing + new).

- [ ] **Step 4: Runtime verification (per the "verify runtime, not just tests" memory)**

Build and launch the app. Manually verify the round trip:
1. Collections page **+** → **New Smart Collection…** → add a rule (e.g. Kind = PDFs), Save → the collection appears in the sidebar with the funnel icon and a live count.
2. Open it → the grid shows exactly the matching files.
3. Add a matching file on disk / change a rating → reopen → membership reflects it (live, no stale cache).
4. Right-click a hand-made collection with members → **Make Smart…** → Save → confirm dialog appears; on Replace, members are dropped and rules take over.
5. Right-click a smart collection → **Edit Rules…** → change Match All→Any → Save → count updates.

Use the `run` skill or `open -n <Muse.app>` to launch. Record the observed outcome.

- [ ] **Step 5: Update docs**

Add a Polish 24 row to the `CLAUDE.md` phase log (branch `feat/next-134`) summarizing smart collections, and a dated `docs/session-log.md` entry. Update the spec's `Status:` line to "Shipped."

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Localizable.xcstrings CLAUDE.md docs/session-log.md docs/superpowers/specs/2026-07-07-smart-collections-design.md
git commit -m "docs+i18n: localize smart-collections strings, record Polish 24"
```

---

## Self-review notes

- **Spec coverage:** §2 storage → Task 1; rule model → Task 2; §3 resolver (grain, AND/OR, color in-memory, alive) → Task 3; §3.1 counts → folded into `fetchAll` (Task 4) which is the off-render-path aggregation seam re-run by `CollectionsEngine.recluster` on index/tag changes — the design's "cache + invalidate on tagsVersion/index/rule-edit" without a separate cache object; §4 UI (builder, entry points, distinct icon, localization) → Tasks 7–9, 11; §5 reclustering-skip → Task 6 (inherited via `model_version='manual'`), make-smart confirm → Tasks 7–8, delete reuses existing path (unchanged), backup/restore → Task 10; §6 testing → Tasks 2, 3, 4, 6, 10.
- **Deferred per spec §Non-goals:** no per-folder scope, no materialized membership/triggers, no rule types beyond the seven, `smart_searches` dead table untouched.
- **Known v1 tradeoff (documented in Task 7):** "within N days" is frozen to an absolute bound at save time rather than re-evaluated daily. `.before`/`.after` are stored/tested but the builder only surfaces the relative "within N days" case for dates; before/after remain available for a future UI without a model change.
- **Color rule is hex-only in v1** (verified: `NamedColor.parse` decodes hex, not color names). The `.name(...)` case stays in the model for a future named-color table but the builder only emits `.hex`; the resolver's `.name` path resolves nil (matches nothing) and is never produced by the UI. Color *names* remain searchable as tags (`ColorTagger`, unchanged).
