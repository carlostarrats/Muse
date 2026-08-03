# Editor Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the editor's twelve control cards a persisted, user-editable workspace — hide modules you don't use, drag to reorder them within and across the two columns, and reach a one-column layout by emptying a column.

**Architecture:** A pure value type (`EditorWorkspace`: an ordered `[EditorModule]` per column plus a hidden set) persisted as JSON in `UserDefaults`, owned by an `@MainActor` singleton store on the `EditorChromeCommand` pattern so the menu bar in `MuseApp` and the editor deep inside `ContentView` can both reach it without re-rendering the shell. `EditorView`'s two hard-coded `@ViewBuilder` card lists become `ForEach` over the workspace's columns, with the card bodies extracted to three sibling files. Reorder is a live `DragGesture` reusing the sidebar's existing `ReorderMath` part-and-insert choreography, not pasteboard drag-and-drop.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSCursor`), XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-03-editor-workspace-design.md` — read it first. Section numbers below refer to it.

## Global Constraints

- **Min macOS 14.6.** No API newer than that without a fallback.
- **Localize every user-facing string.** SwiftUI text-literal positions auto-extract; anything passed as a `String` (custom-view `title:`/`label:` params, enum properties, ternaries) must be hand-wrapped in `String(localized:)`. `NSLocalizedString(var, comment:)` + a manual catalog entry for runtime-variable keys. Finish with `xcodebuild -exportLocalizations` and fill French to **0 untranslated**.
- **The Release build is warning-free. Keep it that way.**
- **`./scripts/audit-invariants.sh` must pass (15/15) before any commit.**
- **Never put editor state on `AppState`** — a `@Published` there re-evaluates the whole `ContentView` body, sidebar and grid included. `AppState` is frozen (DECIDED #26).
- **Nothing this work touches ends over 600 lines**; no new file over ~250.
- **Persist on Save only, never per drag frame.**
- **No hard-coded colours in the editor.** Every colour resolves through `PanelContrast` against the user-chosen backdrop (five levels, white → black).
- **Cursor pushes must pair.** `NSCursor.push()`/`.pop()` in LIFO order, never a bare `.set()` — mismatched pushes corrupt the stack for the whole app.
- **Test tiers:** iterate with `-only-testing:MuseTests/<AffectedTests>`, take the whole `MuseTests` target at a checkpoint, reach for `MuseUITests` only at the end. Plain `xcodebuild -scheme Muse test` runs both targets and costs minutes.

**Branch:** `feat/next-155`, cut from the current `feat/next-154` tip.

---

## File Structure

**Create**

| Path | Responsibility | Est. lines |
|---|---|---|
| `Muse/Muse/Components/EditorWorkspace.swift` | `EditorColumn`, `EditorModule`, `EditorWorkspace` + all pure operations and load repair. No SwiftUI. | ~220 |
| `Muse/Muse/Views/Editor/EditorWorkspaceStore.swift` | `@MainActor` singleton: committed workspace, reorder draft, modal flag, persistence. | ~120 |
| `Muse/Muse/Views/Editor/EditorCustomizeModal.swift` | The Customize Modules card. | ~140 |
| `Muse/Muse/Views/Editor/EditorReorderBar.swift` | The floating All Left / All Right / Reset / Cancel / Save bar. | ~120 |
| `Muse/Muse/Views/Editor/EditorReorderRow.swift` | One collapsed, wiggling, draggable module bar. | ~130 |
| `Muse/Muse/Views/Editor/EditorCardsLeft.swift` | `toolsSection`, `backdropPicker`, `insightsSection` (moved verbatim). | ~300 |
| `Muse/Muse/Views/Editor/EditorCardsRight.swift` | `lightTab`, `colorTab`, `hslSection`, `splitToneSection`, `effectsSection` + their bindings (moved verbatim). | ~380 |
| `Muse/Muse/Views/Editor/EditorCardsCrop.swift` | `cropSection`, `cropAspectMenu`, `cropApplyRow`, `straightenBinding`, `turnPhoto`, `flipPhoto` (moved verbatim). | ~260 |
| `Muse/MuseTests/EditorWorkspaceTests.swift` | Model, repair, move, moveAll, visibility. | ~330 |
| `Muse/MuseTests/EditorWorkspaceStoreTests.swift` | Persistence round-trip, draft/commit/cancel. | ~120 |

**Modify**

| Path | Change |
|---|---|
| `Muse/Muse/Components/ReorderMath.swift` | `+ isLeftColumn(x:containerWidth:)` |
| `Muse/Muse/Components/EscapeAction.swift` | `+ case cancelEditorReorder` and its resolver branch |
| `Muse/Muse/Settings/AppSettings.swift` | `+ editorWorkspaceKey` and the JSON accessor |
| `Muse/Muse/Views/Editor/EditorView.swift` | `ForEach` over the workspace; column-aware `fitInsets`; reorder-mode branch; card bodies removed |
| `Muse/Muse/MuseApp.swift` | The Editor Workspace submenu |
| `Muse/Muse/ContentView.swift` | Present the Customize card; mirror its flag; Escape branch |
| `Muse/Muse/Models/AppState.swift` | `+ editorWorkspaceModalShown` mirror in `modalPresented` |
| `Muse/MuseTests/ReorderMathTests.swift` | `+ isLeftColumn` tests |
| `Muse/MuseTests/EscapeActionTests.swift` | `+ reorder-cancel priority tests` |
| `Muse/Muse/Localizable.xcstrings` | New strings, French filled |
| `docs/new-build/FEATURE-LEDGER.md` | New feature row with its runtime plan |
| `CLAUDE.md` | One Polish row |

---

## Task 1: The workspace model

**Files:**
- Create: `Muse/Muse/Components/EditorWorkspace.swift`
- Test: `Muse/MuseTests/EditorWorkspaceTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum EditorColumn: String, Codable, Sendable { case left, right }`
  - `enum EditorModule: String, CaseIterable, Codable, Identifiable, Sendable` with 12 cases and `var id: String`, `var homeColumn: EditorColumn`, `var homeIndex: Int`, `var title: String`
  - `struct EditorWorkspace: Equatable, Sendable` with `var left: [EditorModule]`, `var right: [EditorModule]`, `var hidden: Set<EditorModule>`, `static let standard: EditorWorkspace`
  - `func modules(in: EditorColumn) -> [EditorModule]`
  - `func visible(in: EditorColumn) -> [EditorModule]`
  - `var visibleCount: Int`
  - `func column(of: EditorModule) -> EditorColumn?`
  - `mutating func move(_:toColumn:visibleSlot:)`
  - `mutating func moveAll(to: EditorColumn)`
  - `mutating func setHidden(_:_:)`
  - `struct EditorWorkspaceDTO: Codable` with `init(_ workspace:)` and `EditorWorkspace.init(dto:)`

- [ ] **Step 1: Write the failing tests**

Create `Muse/MuseTests/EditorWorkspaceTests.swift`:

```swift
//
//  EditorWorkspaceTests.swift
//  MuseTests
//
//  The editor workspace's pure operations. Everything that can silently
//  corrupt a user's saved panel layout lives here — the load-repair rules
//  especially, which are where a "my panels reset themselves" bug would be.
//

import XCTest
@testable import Muse

final class EditorWorkspaceTests: XCTestCase {

    // MARK: - Default

    func testStandardHasEveryModuleExactlyOnce() {
        let w = EditorWorkspace.standard
        let all = w.left + w.right
        XCTAssertEqual(all.count, EditorModule.allCases.count)
        XCTAssertEqual(Set(all), Set(EditorModule.allCases))
    }

    func testStandardHidesNothing() {
        XCTAssertTrue(EditorWorkspace.standard.hidden.isEmpty)
    }

    func testStandardColumnsMatchHomeColumns() {
        let w = EditorWorkspace.standard
        XCTAssertEqual(w.left, [.tools, .histogram, .insights, .history])
        XCTAssertEqual(w.right, [.looks, .light, .zones, .color,
                                 .hsl, .splitTone, .effects, .crop])
    }

    // MARK: - Load repair

    func testRepairDropsUnknownModuleId() {
        // A card removed in a later build. The entry goes; the rest loads.
        let dto = EditorWorkspaceDTO(left: ["tools", "notAModule", "histogram"],
                                     right: ["looks"], hidden: [])
        let w = EditorWorkspace(dto: dto)
        XCTAssertFalse(w.left.contains { $0.rawValue == "notAModule" })
        XCTAssertTrue(w.left.starts(with: [.tools, .histogram]))
    }

    func testRepairAppendsMissingModuleToItsHomeColumnVisible() {
        // A card added in a later build. It must APPEAR, not be hidden by
        // omission — otherwise anyone who ever opened Customize would
        // silently stop receiving new features.
        let dto = EditorWorkspaceDTO(left: ["tools"], right: ["looks"], hidden: [])
        let w = EditorWorkspace(dto: dto)
        XCTAssertEqual(Set(w.left + w.right), Set(EditorModule.allCases))
        XCTAssertFalse(w.hidden.contains(.crop))
        XCTAssertTrue(w.right.contains(.crop))
        XCTAssertTrue(w.left.contains(.histogram))
    }

    func testRepairKeepsExplicitPositionsOfKnownModules() {
        let dto = EditorWorkspaceDTO(left: ["crop"], right: ["tools"], hidden: [])
        let w = EditorWorkspace(dto: dto)
        XCTAssertEqual(w.left.first, .crop)
        XCTAssertEqual(w.right.first, .tools)
    }

    func testRepairDeduplicatesARepeatedModule() {
        let dto = EditorWorkspaceDTO(left: ["tools", "tools"],
                                     right: ["tools"], hidden: [])
        let w = EditorWorkspace(dto: dto)
        XCTAssertEqual((w.left + w.right).filter { $0 == .tools }.count, 1)
        XCTAssertEqual(w.left.first, .tools)
    }

    func testRepairDropsUnknownHiddenId() {
        let dto = EditorWorkspaceDTO(left: [], right: [], hidden: ["gone"])
        let w = EditorWorkspace(dto: dto)
        XCTAssertTrue(w.hidden.isEmpty)
    }

    func testRepairRefusesAnAllHiddenWorkspace() {
        // Not reachable through the modal (the last checkbox is inert), but a
        // hand-edited or older preferences file can arrive this way, and an
        // editor with no controls is a trap.
        let all = EditorModule.allCases.map(\.rawValue)
        let dto = EditorWorkspaceDTO(left: all, right: [], hidden: all)
        let w = EditorWorkspace(dto: dto)
        XCTAssertTrue(w.hidden.isEmpty)
        XCTAssertEqual(w.visibleCount, EditorModule.allCases.count)
    }

    func testDTORoundTripsAWorkspace() {
        var w = EditorWorkspace.standard
        w.move(.crop, toColumn: .left, visibleSlot: 0)
        w.setHidden(.splitTone, true)
        XCTAssertEqual(EditorWorkspace(dto: EditorWorkspaceDTO(w)), w)
    }

    // MARK: - Move

    func testMoveWithinAColumnToTheHead() {
        var w = EditorWorkspace.standard
        w.move(.color, toColumn: .right, visibleSlot: 0)
        XCTAssertEqual(w.right.first, .color)
        XCTAssertEqual(w.right.count, 8)
    }

    func testMoveWithinAColumnPastTheTail() {
        var w = EditorWorkspace.standard
        w.move(.looks, toColumn: .right, visibleSlot: 99)
        XCTAssertEqual(w.right.last, .looks)
    }

    func testMoveAcrossColumns() {
        var w = EditorWorkspace.standard
        w.move(.crop, toColumn: .left, visibleSlot: 1)
        XCTAssertEqual(w.left, [.tools, .crop, .histogram, .insights, .history])
        XCTAssertFalse(w.right.contains(.crop))
    }

    func testMoveIntoAnEmptyColumn() {
        var w = EditorWorkspace.standard
        w.moveAll(to: .right)
        XCTAssertTrue(w.left.isEmpty)
        w.move(.crop, toColumn: .left, visibleSlot: 0)
        XCTAssertEqual(w.left, [.crop])
    }

    func testMovePreservesTheEveryModuleOnceInvariant() {
        var w = EditorWorkspace.standard
        w.move(.crop, toColumn: .left, visibleSlot: 0)
        w.move(.tools, toColumn: .right, visibleSlot: 3)
        w.move(.crop, toColumn: .right, visibleSlot: 99)
        let all = w.left + w.right
        XCTAssertEqual(all.count, EditorModule.allCases.count)
        XCTAssertEqual(Set(all), Set(EditorModule.allCases))
    }

    func testMoveSlotIsMeasuredAmongVISIBLEModules() {
        // Hidden modules keep their position but must not consume a slot —
        // the drag only ever showed the visible ones.
        var w = EditorWorkspace.standard
        w.setHidden(.looks, true)          // right becomes [looks*, light, zones, ...]
        w.move(.crop, toColumn: .right, visibleSlot: 0)
        // Slot 0 among the visible means "before LIGHT", not "before STYLES".
        XCTAssertEqual(w.right.first, .looks)
        XCTAssertEqual(w.right[1], .crop)
        XCTAssertEqual(w.right[2], .light)
    }

    // MARK: - Move all

    func testMoveAllRightUsesReadingOrderLeftThenRight() {
        var w = EditorWorkspace.standard
        w.moveAll(to: .right)
        XCTAssertTrue(w.left.isEmpty)
        XCTAssertEqual(w.right, [.tools, .histogram, .insights, .history,
                                 .looks, .light, .zones, .color,
                                 .hsl, .splitTone, .effects, .crop])
    }

    func testMoveAllLeftUsesTheSameReadingOrder() {
        var w = EditorWorkspace.standard
        w.moveAll(to: .left)
        XCTAssertTrue(w.right.isEmpty)
        XCTAssertEqual(w.left, [.tools, .histogram, .insights, .history,
                                .looks, .light, .zones, .color,
                                .hsl, .splitTone, .effects, .crop])
    }

    func testMoveAllIsIdempotent() {
        var w = EditorWorkspace.standard
        w.moveAll(to: .right)
        let once = w
        w.moveAll(to: .right)
        XCTAssertEqual(w, once)
    }

    func testMoveAllCarriesHiddenModulesToo() {
        var w = EditorWorkspace.standard
        w.setHidden(.tools, true)
        w.moveAll(to: .right)
        XCTAssertTrue(w.right.contains(.tools))
        XCTAssertTrue(w.hidden.contains(.tools))
    }

    // MARK: - Visibility

    func testHideRemovesFromVisibleButKeepsPosition() {
        var w = EditorWorkspace.standard
        w.setHidden(.zones, true)
        XCTAssertFalse(w.visible(in: .right).contains(.zones))
        XCTAssertEqual(w.right.firstIndex(of: .zones), 2)
    }

    func testShowRestoresToTheSamePosition() {
        var w = EditorWorkspace.standard
        let before = w.right
        w.setHidden(.zones, true)
        w.setHidden(.zones, false)
        XCTAssertEqual(w.right, before)
        XCTAssertTrue(w.visible(in: .right).contains(.zones))
    }

    func testHiddenModulesKeepPositionAcrossAReorderOfOthers() {
        var w = EditorWorkspace.standard
        w.setHidden(.zones, true)
        w.move(.crop, toColumn: .right, visibleSlot: 99)
        XCTAssertTrue(w.right.contains(.zones))
        XCTAssertTrue(w.hidden.contains(.zones))
    }

    func testCannotHideTheLastVisibleModule() {
        var w = EditorWorkspace.standard
        for m in EditorModule.allCases.dropLast() { w.setHidden(m, true) }
        XCTAssertEqual(w.visibleCount, 1)
        let survivor = EditorModule.allCases.last!
        w.setHidden(survivor, true)
        XCTAssertEqual(w.visibleCount, 1, "the last visible module must not be hideable")
        XCTAssertFalse(w.hidden.contains(survivor))
    }

    // MARK: - Column lookup

    func testColumnOfFindsAModule() {
        let w = EditorWorkspace.standard
        XCTAssertEqual(w.column(of: .tools), .left)
        XCTAssertEqual(w.column(of: .crop), .right)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse \
  -only-testing:MuseTests/EditorWorkspaceTests test 2>&1 | tail -20
```
Expected: compile failure — `cannot find 'EditorWorkspace' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Muse/Muse/Components/EditorWorkspace.swift`:

```swift
//
//  EditorWorkspace.swift
//  Muse
//
//  The editor's panel layout, as a value.
//
//  The twelve control cards used to be two hard-coded @ViewBuilder lists in
//  EditorView — which cards, in what order, on which side, was source code. This
//  is the model behind them: an ordered list per column plus the set the user
//  has hidden.
//
//  SINGLE COLUMN IS NOT A MODE. It is the state where one column's list is
//  empty. A "Single Column" menu toggle was designed and rejected: restoring
//  "your last two-column arrangement" on uncheck forces two arrangements to
//  exist at once, one of them always invisible to the user, plus rules for
//  which one a reset applies to. See the spec's §9.
//
//  INVARIANT: every module appears exactly once across `left + right`,
//  INCLUDING hidden ones. Hiding is a flag, not a removal, so position and
//  visibility are independent facts and unhiding returns a card to where it
//  was rather than to the bottom. Every mutating operation here preserves it,
//  and `init(dto:)` repairs a stored workspace that violates it.
//
//  Pure: no SwiftUI, no state, no I/O. Joins GridSelection, MasonryGeometry,
//  ReorderMath and CropDragMath.
//

import Foundation

enum EditorColumn: String, Codable, Sendable, CaseIterable {
    case left, right

    var other: EditorColumn { self == .left ? .right : .left }
}

/// One control card. Raw values are the ids `EditorView.Section` already uses
/// and `AppSettings.editorExpandedSections` already persists — one identity per
/// card, so a card's open/closed state and its position can never disagree
/// about which card they mean.
enum EditorModule: String, CaseIterable, Codable, Identifiable, Sendable {
    case tools, histogram, insights, history
    case looks, light, zones, color, hsl, splitTone, effects, crop

    var id: String { rawValue }

    /// Where this card lives in the default layout. A module added in a later
    /// build with no stored position is appended to the bottom of its home
    /// column — see `EditorWorkspace.init(dto:)`.
    var homeColumn: EditorColumn {
        switch self {
        case .tools, .histogram, .insights, .history: .left
        case .looks, .light, .zones, .color, .hsl, .splitTone, .effects, .crop: .right
        }
    }

    /// Position within `homeColumn` in the default layout.
    var homeIndex: Int {
        switch self {
        case .tools: 0
        case .histogram: 1
        case .insights: 2
        case .history: 3
        case .looks: 0
        case .light: 1
        case .zones: 2
        case .color: 3
        case .hsl: 4
        case .splitTone: 5
        case .effects: 6
        case .crop: 7
        }
    }

    /// The card's heading — the same string the panel draws, so the Customize
    /// list names cards the way the user sees them. Hand-wrapped because an
    /// enum property is not a SwiftUI text-literal position and would
    /// otherwise ship in English.
    var title: String {
        switch self {
        case .tools: String(localized: "TOOLS")
        case .histogram: String(localized: "HISTOGRAM")
        case .insights: String(localized: "INSIGHTS")
        case .history: String(localized: "SNAPSHOTS")
        case .looks: String(localized: "STYLES")
        case .light: String(localized: "LIGHT")
        case .zones: String(localized: "TONE ZONES")
        case .color: String(localized: "COLOR")
        case .hsl: String(localized: "COLOR MIX")
        case .splitTone: String(localized: "SPLIT TONE")
        case .effects: String(localized: "EFFECTS")
        case .crop: String(localized: "CROP & STRAIGHTEN")
        }
    }
}

struct EditorWorkspace: Equatable, Sendable {
    var left: [EditorModule]
    var right: [EditorModule]
    var hidden: Set<EditorModule>

    /// The factory layout: two columns, home order, nothing hidden. What
    /// View ▸ Editor Workspace ▸ Default Layout restores.
    static let standard = EditorWorkspace(
        left: EditorModule.allCases
            .filter { $0.homeColumn == .left }
            .sorted { $0.homeIndex < $1.homeIndex },
        right: EditorModule.allCases
            .filter { $0.homeColumn == .right }
            .sorted { $0.homeIndex < $1.homeIndex },
        hidden: [])

    // MARK: - Reading

    func modules(in column: EditorColumn) -> [EditorModule] {
        column == .left ? left : right
    }

    /// What the panel actually draws.
    func visible(in column: EditorColumn) -> [EditorModule] {
        modules(in: column).filter { !hidden.contains($0) }
    }

    var visibleCount: Int { EditorModule.allCases.count - hidden.count }

    func column(of module: EditorModule) -> EditorColumn? {
        if left.contains(module) { return .left }
        if right.contains(module) { return .right }
        return nil
    }

    /// True when every card is on one side — what the canvas geometry reads to
    /// give the photo the emptied column's space back.
    func isEmpty(_ column: EditorColumn) -> Bool { visible(in: column).isEmpty }

    // MARK: - Mutating

    /// Move `module` into `column` at `visibleSlot` — a slot among that
    /// column's VISIBLE modules (0...count), which is what a drag can produce,
    /// since reorder mode only ever draws the visible ones.
    ///
    /// Hidden modules keep their array positions, so an insertion lands just
    /// before the slot-th visible module rather than at a raw array index that
    /// would drift every time something was hidden.
    mutating func move(_ module: EditorModule, toColumn column: EditorColumn,
                       visibleSlot slot: Int) {
        left.removeAll { $0 == module }
        right.removeAll { $0 == module }

        var target = modules(in: column)
        let visibleTargets = target.filter { !hidden.contains($0) }
        let insertAt: Int
        if slot >= visibleTargets.count {
            insertAt = target.count
        } else {
            insertAt = target.firstIndex(of: visibleTargets[max(0, slot)]) ?? target.count
        }
        target.insert(module, at: insertAt)
        write(target, to: column)
    }

    /// Everything to one side, in READING ORDER — the left column's list first,
    /// then the right's, whichever column receives. So All Right gives
    /// TOOLS · HISTOGRAM · … · STYLES · LIGHT · …, matching the single-column
    /// layout the design approved, and All Left gives the same sequence on the
    /// other side. Hidden modules travel too: they keep their flag and their
    /// place in the order, so unhiding one later still lands it sensibly.
    mutating func moveAll(to column: EditorColumn) {
        let merged = left + right
        write(merged, to: column)
        write([], to: column.other)
    }

    /// The last visible module CANNOT be hidden. An editor with no controls,
    /// recoverable only through the menu bar, is a trap — and "show me only the
    /// photo" is already the hide-UI eye's job, done reversibly.
    mutating func setHidden(_ module: EditorModule, _ shouldHide: Bool) {
        if shouldHide {
            guard visibleCount > 1, !hidden.contains(module) else { return }
            hidden.insert(module)
        } else {
            hidden.remove(module)
        }
    }

    private mutating func write(_ modules: [EditorModule], to column: EditorColumn) {
        if column == .left { left = modules } else { right = modules }
    }
}

// MARK: - Storage

/// The on-disk shape. Plain strings, so an id written by a newer build (or one
/// removed by a later one) cannot fail the decode of the WHOLE workspace and
/// throw away a layout the user built. Repair happens in `init(dto:)`.
struct EditorWorkspaceDTO: Codable, Sendable {
    var left: [String]
    var right: [String]
    var hidden: [String]

    init(left: [String], right: [String], hidden: [String]) {
        self.left = left
        self.right = right
        self.hidden = hidden
    }

    init(_ workspace: EditorWorkspace) {
        left = workspace.left.map(\.rawValue)
        right = workspace.right.map(\.rawValue)
        // Sorted so the encoded bytes are stable across launches — an
        // unordered Set would rewrite the preference on every save.
        hidden = workspace.hidden.map(\.rawValue).sorted()
    }
}

extension EditorWorkspace {
    /// Load a stored workspace, repairing the three ways it can disagree with
    /// the running build:
    ///
    /// 1. An UNKNOWN id (a card this build no longer has) is dropped, and the
    ///    rest of the workspace still loads.
    /// 2. A MISSING module (a card this build added) is appended to the bottom
    ///    of its home column, VISIBLE. Never hidden by omission — otherwise
    ///    anyone who had ever opened Customize would silently stop receiving
    ///    new features.
    /// 3. A DUPLICATE id keeps its first occurrence, so the every-module-once
    ///    invariant holds whatever was on disk.
    ///
    /// Plus one safety repair: a workspace with EVERY module hidden is not
    /// reachable through the modal, but a hand-edited or older preferences file
    /// can arrive that way, and it would leave an editor with no controls.
    init(dto: EditorWorkspaceDTO) {
        var seen: Set<EditorModule> = []
        func clean(_ ids: [String]) -> [EditorModule] {
            ids.compactMap { EditorModule(rawValue: $0) }
                .filter { seen.insert($0).inserted }
        }
        var left = clean(dto.left)
        var right = clean(dto.right)

        // Anything this build knows about that the file didn't mention.
        for module in EditorModule.allCases where !seen.contains(module) {
            if module.homeColumn == .left { left.append(module) } else { right.append(module) }
        }

        var hidden = Set(dto.hidden.compactMap { EditorModule(rawValue: $0) })
        if hidden.count >= EditorModule.allCases.count { hidden = [] }

        self.init(left: left, right: right, hidden: hidden)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse \
  -only-testing:MuseTests/EditorWorkspaceTests test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, 24 tests.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Components/EditorWorkspace.swift Muse/MuseTests/EditorWorkspaceTests.swift
git commit -m "The editor's panel layout becomes a value, not source code

Twelve cards in two hard-coded ViewBuilder lists become an ordered list
per column plus a hidden set. Single column is not a mode here and never
will be: it is the state where one column's list is empty.

The invariant that matters is every module appearing exactly once across
both columns INCLUDING hidden ones — hiding is a flag, not a removal, so
unhiding returns a card where it was rather than to the bottom.

The DTO is plain strings on purpose. A card id written by a newer build,
or one this build dropped, must not fail the decode of a whole layout the
user built. Repair drops unknowns, appends anything missing VISIBLE to
its home column, and refuses an all-hidden workspace."
```

---

## Task 2: Cross-column drag math

**Files:**
- Modify: `Muse/Muse/Components/ReorderMath.swift`
- Test: `Muse/MuseTests/ReorderMathTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ReorderMath.isLeftColumn(x: CGFloat, containerWidth: CGFloat) -> Bool`

The existing three functions (`rowShift`, `slot`, `insertionLineY`) are used **as-is** for within-column drags — the editor calls exactly what the sidebar calls, and inherits all 13 existing tests. Only the "which column" decision is new.

- [ ] **Step 1: Write the failing tests**

Append to `Muse/MuseTests/ReorderMathTests.swift`, inside the existing class:

```swift
    // MARK: - Column split (editor workspace reorder)

    func testColumnSplitLeftHalfIsLeft() {
        XCTAssertTrue(ReorderMath.isLeftColumn(x: 100, containerWidth: 1000))
    }

    func testColumnSplitRightHalfIsRight() {
        XCTAssertFalse(ReorderMath.isLeftColumn(x: 900, containerWidth: 1000))
    }

    func testColumnSplitExactMidpointIsRight() {
        // Deliberate: the midpoint belongs to ONE side, and picking `<` makes
        // the boundary consistent with `slot`'s `y < midY`.
        XCTAssertFalse(ReorderMath.isLeftColumn(x: 500, containerWidth: 1000))
    }

    func testColumnSplitBeyondLeftEdgeIsLeft() {
        XCTAssertTrue(ReorderMath.isLeftColumn(x: -40, containerWidth: 1000))
    }

    func testColumnSplitBeyondRightEdgeIsRight() {
        XCTAssertFalse(ReorderMath.isLeftColumn(x: 1400, containerWidth: 1000))
    }

    func testColumnSplitZeroWidthIsRight() {
        // Degenerate container (a frame not yet measured). Must not trap.
        XCTAssertFalse(ReorderMath.isLeftColumn(x: 0, containerWidth: 0))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse \
  -only-testing:MuseTests/ReorderMathTests test 2>&1 | tail -20
```
Expected: compile failure — no `isLeftColumn` member.

- [ ] **Step 3: Write the implementation**

Append inside `enum ReorderMath` in `Muse/Muse/Components/ReorderMath.swift`:

```swift
    /// Which of two side-by-side columns a drag at horizontal position `x`
    /// belongs to, split at the container's midpoint.
    ///
    /// Deliberately NOT measured from the columns' own frames, the way `slot`
    /// measures rows: the editor's workspace reorder can EMPTY a column, and an
    /// empty column has no frames to hit-test — you would be unable to drag
    /// anything back into it. The midpoint is always there.
    ///
    /// The midpoint itself resolves right, matching `slot`'s `y < midY`.
    static func isLeftColumn(x: CGFloat, containerWidth: CGFloat) -> Bool {
        x < containerWidth / 2
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse \
  -only-testing:MuseTests/ReorderMathTests test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, 19 tests (13 existing + 6 new).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Components/ReorderMath.swift Muse/MuseTests/ReorderMathTests.swift
git commit -m "ReorderMath learns which column a drag is over

The editor's workspace reorder is the sidebar's drag with one extra
question. The within-column math is unchanged and called as-is, so it
inherits all 13 existing tests.

The column decision is a midpoint split rather than a hit-test against
the columns' frames, because this reorder can EMPTY a column — and an
empty column has no frames to hit, so you could never drag anything back
into it."
```

---

## Task 3: Persistence and the store

**Files:**
- Modify: `Muse/Muse/Settings/AppSettings.swift`
- Create: `Muse/Muse/Views/Editor/EditorWorkspaceStore.swift`
- Test: `Muse/MuseTests/EditorWorkspaceStoreTests.swift`

**Interfaces:**
- Consumes: `EditorWorkspace`, `EditorWorkspaceDTO` (Task 1).
- Produces:
  - `AppSettings.editorWorkspaceKey: String`
  - `AppSettings.editorWorkspace: EditorWorkspace` (get/set)
  - `@MainActor final class EditorWorkspaceStore: ObservableObject` with `static let shared`, `@Published private(set) var workspace`, `@Published private(set) var reorderDraft: EditorWorkspace?`, `@Published var customizeShown: Bool`, `var reorderMode: Bool`, `var active: EditorWorkspace`, and methods `resetToDefault()`, `setHidden(_:_:)`, `beginReorder()`, `updateDraft(_:)`, `resetDraft()`, `saveReorder()`, `cancelReorder()`

- [ ] **Step 1: Write the failing tests**

Create `Muse/MuseTests/EditorWorkspaceStoreTests.swift`:

```swift
//
//  EditorWorkspaceStoreTests.swift
//  MuseTests
//
//  Persistence round-trip and the reorder draft's commit/cancel discipline.
//  Leaving reorder mode by ANY route other than Save is a cancel — a
//  half-finished arrangement must never be committed by the user closing the
//  viewer.
//

import XCTest
@testable import Muse

@MainActor
final class EditorWorkspaceStoreTests: XCTestCase {

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: AppSettings.editorWorkspaceKey)
        EditorWorkspaceStore.shared.reloadForTesting()
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: AppSettings.editorWorkspaceKey)
        EditorWorkspaceStore.shared.reloadForTesting()
    }

    // MARK: - AppSettings

    func testUnsetPreferenceReadsAsTheStandardWorkspace() {
        XCTAssertEqual(AppSettings.editorWorkspace, .standard)
    }

    func testWorkspaceRoundTripsThroughPreferences() {
        var w = EditorWorkspace.standard
        w.move(.crop, toColumn: .left, visibleSlot: 0)
        w.setHidden(.splitTone, true)
        AppSettings.editorWorkspace = w
        XCTAssertEqual(AppSettings.editorWorkspace, w)
    }

    func testMalformedPreferenceFallsBackToStandard() {
        UserDefaults.standard.set(Data("not json".utf8),
                                  forKey: AppSettings.editorWorkspaceKey)
        XCTAssertEqual(AppSettings.editorWorkspace, .standard)
    }

    func testPreferenceOfTheWrongTypeFallsBackToStandard() {
        UserDefaults.standard.set(42, forKey: AppSettings.editorWorkspaceKey)
        XCTAssertEqual(AppSettings.editorWorkspace, .standard)
    }

    // MARK: - Store

    func testStoreStartsFromPreferences() {
        var w = EditorWorkspace.standard
        w.setHidden(.effects, true)
        AppSettings.editorWorkspace = w
        EditorWorkspaceStore.shared.reloadForTesting()
        XCTAssertTrue(EditorWorkspaceStore.shared.workspace.hidden.contains(.effects))
    }

    func testSetHiddenPersistsImmediately() {
        // Customize applies LIVE — no OK button — so a checkbox write must
        // survive a relaunch on its own.
        EditorWorkspaceStore.shared.setHidden(.zones, true)
        XCTAssertTrue(AppSettings.editorWorkspace.hidden.contains(.zones))
    }

    func testResetToDefaultClearsLayoutAndVisibility() {
        let store = EditorWorkspaceStore.shared
        store.setHidden(.zones, true)
        store.beginReorder()
        var d = store.reorderDraft!
        d.moveAll(to: .right)
        store.updateDraft(d)
        store.saveReorder()

        store.resetToDefault()
        XCTAssertEqual(store.workspace, .standard)
        XCTAssertEqual(AppSettings.editorWorkspace, .standard)
    }

    // MARK: - Reorder draft

    func testBeginReorderCopiesTheCommittedWorkspace() {
        let store = EditorWorkspaceStore.shared
        store.beginReorder()
        XCTAssertTrue(store.reorderMode)
        XCTAssertEqual(store.reorderDraft, store.workspace)
    }

    func testDraftEditsDoNotTouchTheCommittedWorkspace() {
        let store = EditorWorkspaceStore.shared
        store.beginReorder()
        var d = store.reorderDraft!
        d.moveAll(to: .right)
        store.updateDraft(d)
        XCTAssertEqual(store.workspace, .standard)
        XCTAssertEqual(AppSettings.editorWorkspace, .standard)
    }

    func testSaveCommitsAndPersists() {
        let store = EditorWorkspaceStore.shared
        store.beginReorder()
        var d = store.reorderDraft!
        d.moveAll(to: .right)
        store.updateDraft(d)
        store.saveReorder()
        XCTAssertFalse(store.reorderMode)
        XCTAssertTrue(store.workspace.left.isEmpty)
        XCTAssertTrue(AppSettings.editorWorkspace.left.isEmpty)
    }

    func testCancelRestoresTheEntryWorkspaceExactly() {
        let store = EditorWorkspaceStore.shared
        let entry = store.workspace
        store.beginReorder()
        var d = store.reorderDraft!
        d.moveAll(to: .right)
        store.updateDraft(d)
        store.cancelReorder()
        XCTAssertFalse(store.reorderMode)
        XCTAssertNil(store.reorderDraft)
        XCTAssertEqual(store.workspace, entry)
    }

    func testResetDraftRestoresOrderButLeavesHiddenAlone() {
        // Reorder owns order and sides; Customize owns visibility. The
        // floating bar's Reset must not reach across that line.
        let store = EditorWorkspaceStore.shared
        store.setHidden(.zones, true)
        store.beginReorder()
        var d = store.reorderDraft!
        d.moveAll(to: .right)
        store.updateDraft(d)
        store.resetDraft()
        XCTAssertEqual(store.reorderDraft?.left, EditorWorkspace.standard.left)
        XCTAssertEqual(store.reorderDraft?.right, EditorWorkspace.standard.right)
        XCTAssertEqual(store.reorderDraft?.hidden, [.zones])
    }

    func testCancelUndoesAResetInsideTheMode() {
        let store = EditorWorkspaceStore.shared
        store.beginReorder()
        var d = store.reorderDraft!
        d.moveAll(to: .right)
        store.updateDraft(d)
        store.saveReorder()
        let entry = store.workspace

        store.beginReorder()
        store.resetDraft()
        store.cancelReorder()
        XCTAssertEqual(store.workspace, entry)
    }

    func testActiveIsTheDraftWhileReorderingAndTheWorkspaceOtherwise() {
        let store = EditorWorkspaceStore.shared
        XCTAssertEqual(store.active, store.workspace)
        store.beginReorder()
        var d = store.reorderDraft!
        d.moveAll(to: .right)
        store.updateDraft(d)
        XCTAssertEqual(store.active, d)
        store.cancelReorder()
        XCTAssertEqual(store.active, store.workspace)
    }

    func testEditorDismissedCancelsAnInFlightReorder() {
        // Leaving the mode by any route other than Save is a cancel.
        let store = EditorWorkspaceStore.shared
        let entry = store.workspace
        store.beginReorder()
        var d = store.reorderDraft!
        d.moveAll(to: .right)
        store.updateDraft(d)
        store.editorDismissed()
        XCTAssertFalse(store.reorderMode)
        XCTAssertEqual(store.workspace, entry)
    }

    func testEditorDismissedClosesTheCustomizeModal() {
        let store = EditorWorkspaceStore.shared
        store.customizeShown = true
        store.editorDismissed()
        XCTAssertFalse(store.customizeShown)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse \
  -only-testing:MuseTests/EditorWorkspaceStoreTests test 2>&1 | tail -20
```
Expected: compile failure — no `editorWorkspaceKey`, no `EditorWorkspaceStore`.

- [ ] **Step 3a: Add the preference**

In `Muse/Muse/Settings/AppSettings.swift`, add the key beside the other editor keys (after `editorZebraLowKey`):

```swift
    /// The editor's panel workspace — which cards, in what order, on which
    /// side, and which are hidden. A GLOBAL working preference like the
    /// backdrop and the expanded set, stored as JSON because it is structured.
    /// Not library data: it does not go in the database and does not ride a
    /// backup.
    static let editorWorkspaceKey = "editorWorkspace"
```

And the accessor, after `editorExpandedSections`:

```swift
    /// The saved editor workspace. Unset, malformed, or the wrong type all
    /// read as the standard layout — a preference that cannot be parsed must
    /// never leave the user with an editor that has no controls. The repair of
    /// a workspace that parses but disagrees with this build (an id we no
    /// longer have, a card we just added) lives in `EditorWorkspace.init(dto:)`.
    static var editorWorkspace: EditorWorkspace {
        get {
            guard let data = UserDefaults.standard.data(forKey: editorWorkspaceKey),
                  let dto = try? JSONDecoder().decode(EditorWorkspaceDTO.self, from: data)
            else { return .standard }
            return EditorWorkspace(dto: dto)
        }
        set {
            guard let data = try? JSONEncoder().encode(EditorWorkspaceDTO(newValue)) else {
                return
            }
            UserDefaults.standard.set(data, forKey: editorWorkspaceKey)
        }
    }
```

- [ ] **Step 3b: Write the store**

Create `Muse/Muse/Views/Editor/EditorWorkspaceStore.swift`:

```swift
//
//  EditorWorkspaceStore.swift
//  Muse
//
//  The seam between the View menu, the Customize modal, and the editor's
//  panels.
//
//  A Pattern B singleton, exactly like `EditorChromeCommand` and for the same
//  two reasons: the menu bar is built in `MuseApp` while the editor is several
//  layers inside `ContentView`'s viewer overlay, so a command needs somewhere
//  to meet — and a `@Published` on `AppState` re-evaluates the whole
//  `ContentView` body, sidebar and grid included, on every change. `AppState`
//  is frozen (DECIDED #26).
//
//  Reorder is TRANSACTIONAL and the committed workspace is not. Customize
//  applies live (no OK button, so each checkbox persists on its own), while
//  reorder edits a DRAFT that only `saveReorder()` commits. Leaving the mode by
//  any other route — Cancel, Escape, or the viewer closing — discards it. A
//  half-finished arrangement must never be committed by the user closing a
//  photo.
//

import SwiftUI

@MainActor
final class EditorWorkspaceStore: ObservableObject {
    static let shared = EditorWorkspaceStore()

    /// The committed layout. Persisted on every write.
    @Published private(set) var workspace: EditorWorkspace

    /// The in-flight arrangement while reorder mode is active; nil otherwise.
    @Published private(set) var reorderDraft: EditorWorkspace?

    /// The Customize Modules card. Presented by `ContentView` (hoisted above
    /// the viewer like every other editor modal) and mirrored into
    /// `AppState.modalPresented` so Escape and the key catcher see it.
    @Published var customizeShown = false

    var reorderMode: Bool { reorderDraft != nil }

    /// What the panels should DRAW — the draft while rearranging, so the bars
    /// move as you drag without any of it being committed.
    var active: EditorWorkspace { reorderDraft ?? workspace }

    private init() {
        workspace = AppSettings.editorWorkspace
    }

    // MARK: - Committed edits

    /// View ▸ Editor Workspace ▸ Default Layout. The one action that clears the
    /// hidden set as well as the order — the floating bar's Reset deliberately
    /// does not (see `resetDraft`).
    func resetToDefault() {
        cancelReorder()
        commit(.standard)
    }

    /// Customize applies live, so this persists immediately.
    func setHidden(_ module: EditorModule, _ shouldHide: Bool) {
        var next = workspace
        next.setHidden(module, shouldHide)
        commit(next)
    }

    // MARK: - Reorder transaction

    func beginReorder() {
        guard reorderDraft == nil else { return }
        customizeShown = false
        reorderDraft = workspace
    }

    func updateDraft(_ next: EditorWorkspace) {
        guard reorderDraft != nil else { return }
        reorderDraft = next
    }

    /// The floating bar's Reset: standard order and sides, hidden set UNTOUCHED.
    /// Visibility belongs to Customize, and a Reset that silently un-hid four
    /// cards would be reaching across that line. Stays in the mode, so Cancel
    /// can still undo the reset.
    func resetDraft() {
        guard let draft = reorderDraft else { return }
        reorderDraft = EditorWorkspace(left: EditorWorkspace.standard.left,
                                       right: EditorWorkspace.standard.right,
                                       hidden: draft.hidden)
    }

    func saveReorder() {
        guard let draft = reorderDraft else { return }
        reorderDraft = nil
        commit(draft)
    }

    func cancelReorder() {
        reorderDraft = nil
    }

    /// The editor left the screen. Anything in flight is discarded — there is
    /// deliberately no "save your layout?" prompt on the way out of a photo
    /// viewer; the cost of losing a rearrangement is a few seconds of dragging.
    func editorDismissed() {
        cancelReorder()
        customizeShown = false
    }

    // MARK: -

    private func commit(_ next: EditorWorkspace) {
        workspace = next
        AppSettings.editorWorkspace = next
    }

    #if DEBUG
    /// Re-read the preference. Tests only — the store is a singleton and each
    /// test needs it to start from the defaults it just wrote.
    func reloadForTesting() {
        reorderDraft = nil
        customizeShown = false
        workspace = AppSettings.editorWorkspace
    }
    #endif
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse \
  -only-testing:MuseTests/EditorWorkspaceStoreTests test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, 16 tests.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Settings/AppSettings.swift \
        Muse/Muse/Views/Editor/EditorWorkspaceStore.swift \
        Muse/MuseTests/EditorWorkspaceStoreTests.swift
git commit -m "Persist the editor workspace, and make reorder transactional

A Pattern B singleton on the EditorChromeCommand model: the menu is built
in MuseApp, the editor is layers deep in ContentView's viewer overlay, and
a @Published on AppState would re-render the sidebar and grid with every
change.

Customize applies live, so each checkbox persists on its own. Reorder does
not — it edits a draft that only Save commits. Cancel, Escape and the
viewer closing all discard it, because a half-finished arrangement must
never be committed by the user closing a photo.

An unparseable preference reads as the standard layout. A stored workspace
that cannot be read must never leave someone with an editor that has no
controls."
```

---

## Task 4: Extract the card bodies out of `EditorView`

Pure refactor — **no behaviour change**. `EditorView.swift` is 1,682 lines and Task 5 rewrites every card declaration in it; this makes room first.

**Files:**
- Create: `Muse/Muse/Views/Editor/EditorCardsLeft.swift`
- Create: `Muse/Muse/Views/Editor/EditorCardsRight.swift`
- Create: `Muse/Muse/Views/Editor/EditorCardsCrop.swift`
- Modify: `Muse/Muse/Views/Editor/EditorView.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing new. Every moved member keeps its exact name and signature and stays `private` — Swift extensions in the same module can hold `private` members that the primary declaration uses, provided they are in the same file… **they are not**, so each moved member changes `private` → `internal` (drop the keyword). Nothing outside the `Muse` module can see them regardless, and this mirrors the 2026-06-20 `SidebarReorderSupport` extraction, which did the same.

- [ ] **Step 1: Move the left-column card bodies**

Create `Muse/Muse/Views/Editor/EditorCardsLeft.swift` with this header, then **cut** (do not retype) these members from `EditorView.swift` into an `extension EditorView { … }`, dropping `private`:

- `toolsSection`
- `backdropPicker`
- `backdropSwatch(_:)`
- `isWiping`
- `insightsSection`
- `hasInsights`
- `loadFeedback()` and any other `insights`-only helper it calls

```swift
//
//  EditorCardsLeft.swift
//  Muse
//
//  The left column's card bodies — TOOLS (with the backdrop picker) and
//  INSIGHTS. Moved verbatim out of EditorView.swift in the workspace pass:
//  that file was 1,682 lines and the workspace rewrites every card
//  declaration in it, so the bodies came out first. Behaviour unchanged;
//  `private` became internal only because an extension in another file cannot
//  see the primary declaration's private members. Same move, same reason, as
//  the 2026-06-20 SidebarReorderSupport extraction.
//
//  HISTOGRAM and SNAPSHOTS are not here — they were already their own views
//  (ScopesPanel, EditVersionsList).
//

import SwiftUI
import AppKit

extension EditorView {
    // … moved members …
}
```

- [ ] **Step 2: Build to verify the move compiles**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`. If a moved member is still `private`, the error names it — drop the keyword.

- [ ] **Step 3: Move the right-column card bodies**

Create `Muse/Muse/Views/Editor/EditorCardsRight.swift` the same way, moving:

- `lightTab`, `toneBinding(_:)`, `presenceBinding(_:)`, `curveBinding`
- `colorTab`, `colorBinding(_:)`
- `hslSection`, `hslTabs`, `hslTabButton(_:_:)`, `hslBinding(_:)`, `HSLTab`, `hslBandNames`
- `splitToneSection`, `splitBinding(_:)`
- `effectsSection`, `effectsGroupLabel(_:)`, `vignetteBinding(_:)`, `grainBinding(_:)`
- `looksTab`, `stylesModeButtons`, `stylesModeButton(...)`, `stylesSummary`
- `autoAndReset(...)`, `resetButton(_:action:)`

Header:

```swift
//
//  EditorCardsRight.swift
//  Muse
//
//  The right column's card bodies — STYLES, LIGHT, COLOR, COLOR MIX, SPLIT
//  TONE and EFFECTS, plus the parameter bindings they write through and the
//  shared Auto/Reset heading accessories. Moved verbatim out of
//  EditorView.swift; see EditorCardsLeft.swift for why.
//
//  TONE ZONES is not here — it was already its own view (ToneZoneStrip).
//

import SwiftUI
```

**Note:** `HSLTab` was a `private enum` nested in `EditorView` and is referenced by the `@State private var hslTab`, which STAYS in `EditorView`. Move the enum but keep it nested (`extension EditorView { enum HSLTab … }` is not legal for a nested type in an extension in Swift — a nested type must be declared in the primary declaration). **Leave `HSLTab` in `EditorView.swift`** and move only the views and bindings.

- [ ] **Step 4: Build to verify**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Move the crop card body**

Create `Muse/Muse/Views/Editor/EditorCardsCrop.swift`, moving:

- `cropSection`, `cropAspectMenu`, `cropApplyRow`, `cropResetButton`, `isApplyHot`
- `selectAspect(_:)`, `straightenBinding`, `turnPhoto(by:)`, `flipPhoto(horizontal:)`

`@State private var cropAspect`, `cropPortrait` and `applyCropHovering` **stay in `EditorView`** (stored properties cannot live in an extension) and change `private` → internal so the extension can read them.

Header:

```swift
//
//  EditorCardsCrop.swift
//  Muse
//
//  CROP & STRAIGHTEN. Its own file because it is the largest single card and
//  the only one whose control writes into a DIFFERENT coordinate space than
//  the one it is drawn in — see CropDragMath and the durable constraint about
//  EditRenderer.applyGeometry cropping BEFORE it flips and turns. Moved
//  verbatim out of EditorView.swift; see EditorCardsLeft.swift for why.
//

import SwiftUI
```

- [ ] **Step 6: Build and run the whole unit target**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Release build 2>&1 | tail -5
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests test 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **` with no warnings, and `** TEST SUCCEEDED **` with the suite at its pre-task count + 40 (Tasks 1–3).

- [ ] **Step 7: Verify the line budget**

Run:
```bash
wc -l Muse/Muse/Views/Editor/EditorView.swift Muse/Muse/Views/Editor/EditorCards*.swift
```
Expected: `EditorView.swift` under 700 (it still holds the two panel-content lists, which Task 5 replaces); no card file over 400.

- [ ] **Step 8: Commit**

```bash
git add Muse/Muse/Views/Editor/
git commit -m "Move the editor's card bodies out of EditorView

A file move, nothing else. EditorView was 1,682 lines and the workspace
pass rewrites every card declaration in it, so the bodies come out first
rather than a thirteenth concern going in.

Three files by what they are: the left column's tools and insights, the
right column's tone and colour cards with the bindings they write through,
and crop on its own — it is the largest card and the only one whose
control writes into a different coordinate space than it is drawn in.

private became internal only because an extension in another file cannot
see the primary declaration's private members. Same move, same reason, as
the 2026-06-20 SidebarReorderSupport extraction."
```

---

## Task 5: Drive the panels from the workspace

The two hard-coded `@ViewBuilder` lists become `ForEach` over the workspace. **No visible change yet** — the default workspace produces today's exact layout.

**Files:**
- Create: `Muse/Muse/Views/Editor/EditorCardBuilder.swift`
- Modify: `Muse/Muse/Views/Editor/EditorView.swift`

**Interfaces:**
- Consumes: `EditorWorkspaceStore.shared.active`, `EditorWorkspace.visible(in:)`, `EditorModule` (Tasks 1, 3).
- Produces: `EditorView.card(for: EditorModule) -> some View` and `EditorView.column(_ column: EditorColumn) -> some View`.

- [ ] **Step 1: Write the card builder**

Create `Muse/Muse/Views/Editor/EditorCardBuilder.swift`:

```swift
//
//  EditorCardBuilder.swift
//  Muse
//
//  Module → card. The one place that knows a section id means a particular
//  EditorSection with a particular heading, accessory and body.
//
//  Its own file for a compile-time reason as much as a legibility one: a
//  twelve-way switch inside a @ViewBuilder nests _ConditionalContent twelve
//  deep, and that type-checks far faster with the branches away from the rest
//  of the view.
//

import SwiftUI

extension EditorView {
    /// One card, built for the module the workspace asked for.
    ///
    /// INSIGHTS is conditional on having something to say — that is a
    /// hidden-by-ABSENCE, which is not the same as a user-hidden module and is
    /// why it also drops out of the Customize list when empty.
    @ViewBuilder
    func card(for module: EditorModule) -> some View {
        switch module {
        case .tools:
            EditorSection(title: module.title, ink: ink,
                          isExpanded: expansion(Section.tools)) { toolsSection }
        case .histogram:
            EditorSection(title: module.title, ink: ink,
                          isExpanded: expansion(Section.histogram)) {
                ScopesPanel(session: session)
            }
        case .insights:
            if hasInsights {
                EditorSection(title: module.title, ink: ink,
                              isExpanded: expansion(Section.insights)) { insightsSection }
            }
        case .history:
            EditorSection(title: module.title, ink: ink,
                          isExpanded: expansion(Section.history)) {
                EditVersionsList(session: session)
            }
        case .looks:
            EditorSection(title: module.title, ink: ink,
                          accessory: stylesModeButtons,
                          summary: stylesSummary,
                          isExpanded: expansion(Section.looks)) { looksTab }
        case .light:
            EditorSection(title: module.title, ink: ink,
                          accessory: autoAndReset(
                              autoHelp: String(localized: "Auto Light"),
                              auto: {
                                  Task {
                                      guard let r = await session.autoToneResult() else { return }
                                      AutoToneApply.light(r, onto: &session.draft)
                                      session.commitGesture()
                                  }
                              },
                              resetHelp: String(localized: "Reset Light"),
                              reset: {
                                  session.draft.setTone { $0 = .neutral }
                                  session.draft.setPresence { $0 = .neutral }
                                  session.draft.setCurve { $0 = .neutral }
                                  session.commitGesture()
                              }),
                          isExpanded: expansion(Section.light)) { lightTab }
        case .zones:
            EditorSection(title: module.title, ink: ink,
                          accessory: resetButton(String(localized: "Reset Tone Zones")) {
                              session.draft.setToneZone { $0 = .neutral }
                              session.commitGesture()
                          },
                          isExpanded: expansion(Section.zones)) {
                ToneZoneStrip(session: session)
            }
        case .color:
            EditorSection(title: module.title, ink: ink,
                          accessory: autoAndReset(
                              autoHelp: String(localized: "Auto Color"),
                              auto: {
                                  Task {
                                      guard let r = await session.autoToneResult() else { return }
                                      AutoToneApply.color(r, onto: &session.draft)
                                      session.commitGesture()
                                  }
                              },
                              resetHelp: String(localized: "Reset Color"),
                              reset: {
                                  session.draft.setColor { $0 = .neutral }
                                  session.commitGesture()
                              }),
                          isExpanded: expansion(Section.color)) { colorTab }
        case .hsl:
            EditorSection(title: module.title, ink: ink,
                          accessory: resetButton(String(localized: "Reset Color Mix")) {
                              session.draft.setHSL { $0 = .neutral }
                              session.commitGesture()
                          },
                          isExpanded: expansion(Section.hsl)) { hslSection }
        case .splitTone:
            EditorSection(title: module.title, ink: ink,
                          accessory: resetButton(String(localized: "Reset Split Tone")) {
                              session.draft.setSplitTone { $0 = .neutral }
                              session.commitGesture()
                          },
                          isExpanded: expansion(Section.splitTone)) { splitToneSection }
        case .effects:
            EditorSection(title: module.title, ink: ink,
                          accessory: resetButton(String(localized: "Reset Effects")) {
                              session.draft.setVignette { $0 = .neutral }
                              session.draft.setGrain { $0 = .neutral }
                              session.commitGesture()
                          },
                          isExpanded: expansion(Section.effects)) { effectsSection }
        case .crop:
            EditorSection(title: module.title, ink: ink,
                          accessory: cropResetButton,
                          isExpanded: expansion(Section.crop)) { cropSection }
        }
    }
}
```

- [ ] **Step 2: Replace the two panel-content lists**

In `EditorView.swift`, delete `leftPanelContent` and `rightPanelContent` entirely and add:

```swift
    /// The workspace decides which cards a column holds and in what order. It
    /// used to be two hard-coded @ViewBuilder lists here — the layout was
    /// source code.
    @ViewBuilder
    func columnContent(_ column: EditorColumn) -> some View {
        ForEach(workspace.active.visible(in: column)) { module in
            card(for: module)
        }
    }
```

and, beside the other `@ObservedObject`s at the top of `EditorView`:

```swift
    /// The panel layout — which cards, where, and which are hidden.
    @ObservedObject private var workspace = EditorWorkspaceStore.shared
```

Then in `body`, replace the two `EditorPanel` call sites' content closures:

```swift
                    EditorPanel(topInset: Self.panelTop, ink: ink,
                                backingVisible: isZoomed, chrome: { EmptyView() }) {
                        columnContent(.left)
                    }
```
```swift
                    EditorPanel(topInset: ViewerGeometry.chromeTop, ink: ink,
                                backingVisible: isZoomed, chrome: { chromeRow }) {
                        columnContent(.right)
                    }
```

**Also:** a column with no visible cards must not draw an empty panel. Wrap the LEFT panel in `if !workspace.active.isEmpty(.left)`. The RIGHT panel always draws — it carries the pinned chrome row, which is not a module (spec §2). When the right column has no cards, `EditorPanel` renders the chrome row alone, which is exactly what the hide-UI eye already produces.

- [ ] **Step 3: Tell the store when the editor comes and goes**

In `EditorView`'s `.onDisappear`, alongside `chromeCommand.editorDismissed()`:

```swift
            // Leaving the editor by any route discards an in-flight
            // rearrangement and closes the Customize card — see the store.
            workspace.editorDismissed()
```

- [ ] **Step 4: Build and verify no visible change**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Release build 2>&1 | tail -5
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests test 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **` warning-free, `** TEST SUCCEEDED **`.

Then launch and confirm the editor looks **identical** to before:
```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/Muse-*/Build/Products/Debug/Muse.app
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build 2>&1 | tail -3
stat -f '%Sm %N' ~/Library/Developer/Xcode/DerivedData/Muse-*/Build/Products/Debug/Muse.app/Contents/MacOS/Muse
open ~/Library/Developer/Xcode/DerivedData/Muse-*/Build/Products/Debug/Muse.app
```
**`BUILD SUCCEEDED` is not proof the running app has the change — check the mtime is from this minute before looking at anything.**

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Views/Editor/
git commit -m "The editor's panels read their layout instead of declaring it

Two hard-coded ViewBuilder lists become ForEach over the workspace. No
visible change: the default workspace produces exactly today's layout.

The left panel stops drawing when it has no cards. The right one always
draws, because it carries the chrome row — zoom, the eye, Share and the
close button are viewer controls, not modules, and they stay pinned
top-right whatever happens to the cards. That is what makes an all-cards-
left layout coherent.

The module-to-card switch is its own file for a compile-time reason as
much as a tidiness one: twelve _ConditionalContent branches inside a
@ViewBuilder type-check a lot faster away from the rest of the view."
```

---

## Task 6: Column-aware canvas geometry

**Files:**
- Modify: `Muse/Muse/Views/Editor/EditorView.swift` (`fitInsets`)
- Test: `Muse/MuseTests/EditorCanvasGeometryTests.swift`

**Interfaces:**
- Consumes: `EditorWorkspace.isEmpty(_:)` (Task 1).
- Produces: `EditorView.panelInsets(leftEmpty:rightEmpty:chromeProgress:) -> EdgeInsets` — extracted as a `static` pure function so it can be tested without a view.

Spec §8. **Sides follow the cards, the top stays with the chrome.**

- [ ] **Step 1: Write the failing tests**

Append to `Muse/MuseTests/EditorCanvasGeometryTests.swift`:

```swift
    // MARK: - Column-aware fit insets

    func testBothColumnsReserveAPanelOnEachSide() {
        let i = EditorView.panelInsets(leftEmpty: false, rightEmpty: false,
                                       chromeProgress: 1)
        XCTAssertEqual(i.leading, ViewerGeometry.editorPanelWidth, accuracy: 0.01)
        XCTAssertEqual(i.trailing, ViewerGeometry.editorPanelWidth, accuracy: 0.01)
    }

    func testAllCardsRightGivesThePhotoTheLeftSide() {
        // Preview's exact geometry — content left, column right — so switching
        // Preview to Edit does not move the photo at all.
        let i = EditorView.panelInsets(leftEmpty: true, rightEmpty: false,
                                       chromeProgress: 1)
        XCTAssertEqual(i.leading, ViewerGeometry.sidePad, accuracy: 0.01)
        XCTAssertEqual(i.trailing, ViewerGeometry.editorPanelWidth, accuracy: 0.01)
    }

    func testAllCardsLeftGivesThePhotoTheRightSide() {
        let i = EditorView.panelInsets(leftEmpty: false, rightEmpty: true,
                                       chromeProgress: 1)
        XCTAssertEqual(i.leading, ViewerGeometry.editorPanelWidth, accuracy: 0.01)
        XCTAssertEqual(i.trailing, ViewerGeometry.sidePad, accuracy: 0.01)
    }

    func testTheTopInsetNeverMoves() {
        // The chrome row is pinned, so a photo widening into an emptied right
        // column must still start below it.
        for (l, r) in [(false, false), (true, false), (false, true), (true, true)] {
            let i = EditorView.panelInsets(leftEmpty: l, rightEmpty: r,
                                           chromeProgress: 1)
            XCTAssertEqual(i.top, ViewerGeometry.topPad, accuracy: 0.01,
                           "top moved for leftEmpty=\(l) rightEmpty=\(r)")
        }
    }

    func testHidingTheUIStillCollapsesEverySideToBare() {
        let i = EditorView.panelInsets(leftEmpty: false, rightEmpty: false,
                                       chromeProgress: 0)
        XCTAssertEqual(i.leading, ViewerGeometry.sidePad, accuracy: 0.01)
        XCTAssertEqual(i.trailing, ViewerGeometry.sidePad, accuracy: 0.01)
        XCTAssertEqual(i.top, ViewerGeometry.sidePad, accuracy: 0.01)
    }

    func testMidChromeProgressInterpolatesFromTheColumnAwareTarget() {
        // Emptying a column and hiding the UI must compose: the interpolation
        // runs toward THIS layout's inset, not the two-column one.
        let i = EditorView.panelInsets(leftEmpty: true, rightEmpty: false,
                                       chromeProgress: 0.5)
        XCTAssertEqual(i.leading, ViewerGeometry.sidePad, accuracy: 0.01,
                       "an emptied side is already bare at any progress")
        let expected = ViewerGeometry.sidePad
            + (ViewerGeometry.editorPanelWidth - ViewerGeometry.sidePad) * 0.5
        XCTAssertEqual(i.trailing, expected, accuracy: 0.01)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse \
  -only-testing:MuseTests/EditorCanvasGeometryTests test 2>&1 | tail -20
```
Expected: compile failure — no `panelInsets`.

- [ ] **Step 3: Write the implementation**

In `EditorView.swift`, replace the existing `fitInsets` with:

```swift
    /// The free space the image FITS into. Zoom is not clamped to it — the
    /// photo grows past it and under the panels, like Preview's does under the
    /// info column.
    private var fitInsets: EdgeInsets {
        Self.panelInsets(leftEmpty: workspace.active.isEmpty(.left),
                         rightEmpty: workspace.active.isEmpty(.right),
                         chromeProgress: chromeProgress)
    }

    /// Sides follow the cards; the top stays with the chrome.
    ///
    /// An emptied column gives the photo its space back — all-cards-right
    /// lands on Preview's exact geometry (content left, column right), so
    /// switching Preview ⇄ Edit does not move the photo at all. The TOP inset
    /// never changes, because the chrome row is pinned top-right whatever
    /// happens to the cards, and a photo widening into an emptied right column
    /// must not run under it.
    ///
    /// `chromeProgress` (1 = panels shown, 0 = hidden by the eye) interpolates
    /// toward THIS layout's targets, so hiding the UI on a single-column
    /// workspace composes correctly instead of animating from a two-column
    /// inset that is not there.
    ///
    /// Static and pure so the rule can be tested without standing up a view.
    static func panelInsets(leftEmpty: Bool, rightEmpty: Bool,
                            chromeProgress p: Double) -> EdgeInsets {
        let column = ViewerGeometry.editorPanelWidth
        let bare = ViewerGeometry.sidePad
        func lerp(_ hidden: CGFloat, _ shown: CGFloat) -> CGFloat {
            hidden + (shown - hidden) * p
        }
        return EdgeInsets(top: lerp(bare, ViewerGeometry.topPad),
                          leading: lerp(bare, leftEmpty ? bare : column),
                          bottom: lerp(bare, ViewerGeometry.bottomPad),
                          trailing: lerp(bare, rightEmpty ? bare : column))
    }
```

- [ ] **Step 4: Step the canvas when a column empties**

The insets must **slide**, not jump — the photo has to glide into the freed space when Save empties a column. `chromeProgress` already steps frame by frame for the hide-UI toggle; reuse it by re-running the same stepped animation whenever the emptiness of either column changes. In `EditorView.body`, add:

```swift
        .onChange(of: workspace.active.isEmpty(.left)) { _, _ in stepCanvasRefit() }
        .onChange(of: workspace.active.isEmpty(.right)) { _, _ in stepCanvasRefit() }
```

and beside `toggleChrome()`:

```swift
    /// Re-fit the canvas after the columns changed shape.
    ///
    /// `fitInsets` is a value the MTKView reads once per render, so a plain
    /// SwiftUI animation would not reach it — the same reason `toggleChrome`
    /// steps `chromeProgress` frame by frame rather than animating it. Nothing
    /// about the PROGRESS changes here; stepping it to its own current value
    /// is what re-publishes the insets on each frame while the panels slide.
    private func stepCanvasRefit() {
        guard !session.uiHidden else { return }
        chromeAnimation?.cancel()
        let frames = max(1, Int(Self.chromeFade * 60))
        chromeAnimation = Task { @MainActor in
            for _ in 1...frames {
                if Task.isCancelled { return }
                chromeProgress = 1
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse \
  -only-testing:MuseTests/EditorCanvasGeometryTests test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, existing tests + 6.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Views/Editor/EditorView.swift Muse/MuseTests/EditorCanvasGeometryTests.swift
git commit -m "The canvas insets follow the cards, the top stays with the chrome

fitInsets reserved a panel's width on both sides unconditionally, so an
emptied column would have left the photo centred beside a dead strip.

All-cards-right now lands on Preview's exact geometry — content left,
column right — so switching Preview to Edit does not move the photo at
all. The top inset never changes, because the chrome row is pinned and a
photo widening into an emptied right column must not run under it.

Extracted as a static function: the rule is worth testing without standing
up a view, and the interpolation has to run toward THIS layout's targets
so hiding the UI on a single-column workspace composes instead of
animating from a two-column inset that is not there."
```

---

## Task 7: The View menu and the Customize modal

**Files:**
- Create: `Muse/Muse/Views/Editor/EditorCustomizeModal.swift`
- Modify: `Muse/Muse/MuseApp.swift`
- Modify: `Muse/Muse/Models/AppState.swift`
- Modify: `Muse/Muse/ContentView.swift`
- Modify: `Muse/Muse/Components/EscapeAction.swift`
- Test: `Muse/MuseTests/EscapeActionTests.swift`

**Interfaces:**
- Consumes: `EditorWorkspaceStore.shared` (Task 3), `EditorModule.title` (Task 1).
- Produces:
  - `struct EditorCustomizeModal: View` (no parameters — reads the shared store)
  - `AppState.editorWorkspaceModalShown: Bool` (a non-`@Published` mirror, `announcementPresented` pattern)
  - `EscapeAction.cancelEditorReorder`
  - `EscapeResolver.action(..., editorReorderActive: Bool = false)`

- [ ] **Step 1: Write the failing Escape tests**

Append to `Muse/MuseTests/EscapeActionTests.swift`:

```swift
    // MARK: - Editor workspace reorder

    func testReorderCancelBeatsClosingTheHero() {
        // Reorder mode lives INSIDE the hero. Without this branch Escape would
        // close the whole viewer and silently discard the arrangement.
        XCTAssertEqual(
            EscapeResolver.action(hasSelectedFile: true, selectedFileIsHero: true,
                                  searchActive: false, tagsActive: false,
                                  insideCollection: false, showingCollectionsPage: false,
                                  editorReorderActive: true),
            .cancelEditorReorder)
    }

    func testAModalStillBeatsReorderCancel() {
        // A card raised over the editor is the innermost layer, as always.
        XCTAssertEqual(
            EscapeResolver.action(modalPresented: true,
                                  hasSelectedFile: true, selectedFileIsHero: true,
                                  searchActive: false, tagsActive: false,
                                  insideCollection: false, showingCollectionsPage: false,
                                  editorReorderActive: true),
            .dismissModal)
    }

    func testReorderCancelBeatsCompare() {
        XCTAssertEqual(
            EscapeResolver.action(hasSelectedFile: false, selectedFileIsHero: false,
                                  searchActive: false, tagsActive: false,
                                  insideCollection: false, showingCollectionsPage: false,
                                  compareActive: true, editorReorderActive: true),
            .cancelEditorReorder)
    }

    func testWithoutReorderTheHeroStillCloses() {
        XCTAssertEqual(
            EscapeResolver.action(hasSelectedFile: true, selectedFileIsHero: true,
                                  searchActive: false, tagsActive: false,
                                  insideCollection: false, showingCollectionsPage: false,
                                  editorReorderActive: false),
            .closeHero)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse \
  -only-testing:MuseTests/EscapeActionTests test 2>&1 | tail -20
```
Expected: compile failure — no `editorReorderActive`, no `.cancelEditorReorder`.

- [ ] **Step 3: Add the Escape case**

In `Muse/Muse/Components/EscapeAction.swift`, add the case after `dismissModal`:

```swift
    /// The editor's workspace reorder mode is active — cancel it, discarding
    /// the in-flight arrangement. Resolves ABOVE the viewer cases: reorder
    /// lives INSIDE the hero, so without this Escape would close the whole
    /// viewer and take the rearrangement with it.
    case cancelEditorReorder
```

and the resolver branch, immediately after the `modalPresented` early return:

```swift
        if editorReorderActive { return .cancelEditorReorder }
```

with the new parameter added to the signature after `modalPresented`:

```swift
                       editorReorderActive: Bool = false,
```

- [ ] **Step 4: Write the Customize modal**

Create `Muse/Muse/Views/Editor/EditorCustomizeModal.swift`:

```swift
//
//  EditorCustomizeModal.swift
//  Muse
//
//  View ▸ Editor Workspace ▸ Customize Modules…
//
//  Which of the twelve control cards the editor shows. It applies LIVE — no OK
//  button — so you can watch a card leave the panel behind the card. A
//  confirm step on a checkbox list is ceremony, and each write persists on its
//  own (see EditorWorkspaceStore.setHidden).
//
//  It does NOT reorder. No handles, no up/down arrows: reorder is its own mode
//  with its own gestures, and two ways to do one thing in two places drift
//  apart.
//
//  Rows are listed in PANEL order — left column top to bottom, then right — so
//  the list reads like the thing it edits.
//

import SwiftUI

struct EditorCustomizeModal: View {
    @ObservedObject private var store = EditorWorkspaceStore.shared
    /// INSIGHTS draws only when the photo has something to say, so it is
    /// listed only then. Hidden-by-ABSENCE is not the same as user-hidden.
    let showsInsights: Bool
    var onClose: () -> Void

    @Environment(\.theme) private var theme

    private var rows: [EditorModule] {
        let w = store.workspace
        return (w.left + w.right).filter { $0 != .insights || showsInsights }
    }

    var body: some View {
        ModalCard(title: String(localized: "Customize Modules"), onClose: onClose) {
            VStack(alignment: .leading, spacing: theme.spacingS) {
                Text("Choose which control cards the editor shows. Hidden cards keep their place and return where they were.")
                    .font(theme.labelFont)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, theme.spacingS)

                ForEach(rows) { module in
                    row(module)
                }
            }
        }
    }

    private func row(_ module: EditorModule) -> some View {
        let isVisible = !store.workspace.hidden.contains(module)
        // The LAST visible module cannot be hidden — an editor with no
        // controls, recoverable only through the menu bar, is a trap, and
        // "show me only the photo" is already the hide-UI eye's job.
        let isLast = isVisible && store.workspace.visibleCount == 1
        return Toggle(isOn: Binding(get: { isVisible },
                                    set: { store.setHidden(module, !$0) })) {
            Text(module.title)
                .font(theme.labelFont)
                .foregroundStyle(theme.textPrimary)
        }
        .toggleStyle(.checkbox)
        .disabled(isLast)
        .help(isLast
              ? Text("At least one card has to stay visible")
              : Text(module.title))
        .accessibilityLabel(Text(module.title))
        .accessibilityHint(isLast
                           ? Text("At least one card has to stay visible")
                           : Text("Show or hide this card in the editor"))
    }
}
```

**Before writing this:** grep for the app's existing modal-card wrapper and match it exactly —

```bash
grep -rn "struct ModalCard\|struct MuseAlert\|struct InfoModal" --include="*.swift" Muse/Muse/Views | head
```

If the wrapper has a different name or signature, use the real one; the body above is the content, not the chrome.

- [ ] **Step 5: Add the menu**

In `Muse/Muse/MuseApp.swift`, add the observed store beside `editorChrome`:

```swift
    @ObservedObject private var editorWorkspace = EditorWorkspaceStore.shared
```

and, inside the existing `CommandGroup(after: .sidebar)` block after the Hide-controls button:

```swift
                Divider()

                // The editor's panel layout. Named "Editor Workspace" — a
                // noun, the editor's workspace. "Edit Workspace" reads as a
                // verb, which is wrong for a submenu that contains an actual
                // Customize item.
                //
                // There is deliberately NO "Single Column" item: single column
                // is the state where one column is empty, reached by dragging.
                // A toggle that restored "your last two-column arrangement"
                // would force two arrangements to exist at once, one of them
                // always invisible. See the spec's §9.
                Menu {
                    Button {
                        EditorWorkspaceStore.shared.resetToDefault()
                    } label: {
                        Label("Default Layout", systemImage: "arrow.counterclockwise")
                    }
                    Button {
                        EditorWorkspaceStore.shared.customizeShown = true
                    } label: {
                        Label("Customize Modules…", systemImage: "checklist")
                    }
                    Button {
                        EditorWorkspaceStore.shared.beginReorder()
                    } label: {
                        Label("Reorder Modules", systemImage: "arrow.up.arrow.down")
                    }
                } label: {
                    Label("Editor Workspace", systemImage: "rectangle.split.2x1")
                }
                // Off outside Edit mode (uiHidden is nil when no editor is on
                // screen), behind any modal, and during a reorder — the mode
                // owns the editor until it is saved or cancelled.
                .disabled(editorChrome.uiHidden == nil || appState.modalPresented
                          || editorWorkspace.reorderMode)
```

**No keyboard shortcuts.** None of the three is a control you bounce on.

- [ ] **Step 6: Register the modal and present it**

In `Muse/Muse/Models/AppState.swift`, beside `announcementPresented`:

```swift
    /// Mirror of `EditorWorkspaceStore.customizeShown`, so the key-catcher gate
    /// and the Escape resolver see the Customize card like any other modal.
    ///
    /// Deliberately NOT `@Published`, exactly like `announcementPresented`:
    /// AppState is frozen (DECIDED #26) and a published flag here would fan a
    /// whole-shell re-render out of a feature that owns its own store. It does
    /// not need to be — the card is presented from `ContentView`, which
    /// observes `EditorWorkspaceStore` directly, so the body that reads
    /// `modalPresented` is already re-evaluating when this changes.
    /// `ContentView` is the only writer.
    var editorWorkspaceModalShown = false
```

and add it to `modalPresented`:

```swift
            || editorWorkspaceModalShown
```

In `ContentView.swift`: observe the store, mirror the flag, present the card, and add the Escape branches.

```swift
    @ObservedObject private var editorWorkspace = EditorWorkspaceStore.shared
```

In `dismissTopModal()`, before the `settingsShown` branch:

```swift
        if editorWorkspace.customizeShown { editorWorkspace.customizeShown = false; return }
```

Where the other hoisted editor cards are presented (search for `editPromptRequest` in `ContentView`), add — **hoisted above the viewer for the standing reason: an in-window card is sized from its host's geometry, and the editor's 260pt column would size it to 260pt**:

```swift
                if editorWorkspace.customizeShown {
                    EditorCustomizeModal(showsInsights: appState.editorHasInsights) {
                        editorWorkspace.customizeShown = false
                    }
                }
```

Mirror the flag wherever the other mirrors are maintained:

```swift
                .onChange(of: editorWorkspace.customizeShown) { _, shown in
                    appState.editorWorkspaceModalShown = shown
                }
```

Feed the resolver:

```swift
                    editorReorderActive: editorWorkspace.reorderMode,
```

and handle the new action wherever `EscapeAction` is switched on:

```swift
                case .cancelEditorReorder: editorWorkspace.cancelReorder()
```

**`appState.editorHasInsights`:** `hasInsights` currently lives on `EditorView` and depends on `session`. The modal is hoisted, so it cannot read it. Add a plain (non-`@Published`) `var editorHasInsights = false` to `AppState`, written from `EditorView.loadFeedback()` — the same mirror pattern, same justification.

- [ ] **Step 7: Build and test**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Release build 2>&1 | tail -5
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests test 2>&1 | tail -5
```
Expected: warning-free build; `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add Muse/Muse/ Muse/MuseTests/
git commit -m "View menu gets Editor Workspace, and Customize Modules ships

Three items, no shortcuts: Default Layout, Customize Modules and Reorder
Modules. Named Editor Workspace because it is a noun — 'Edit Workspace'
reads as a verb, which is wrong for a submenu containing an actual
Customize item. There is deliberately no Single Column item.

Customize applies live and each checkbox persists on its own. The last
visible card's checkbox is inert: an editor with no controls, recoverable
only through the menu bar, is a trap, and 'show me only the photo' is
already the eye's job.

Escape gains a branch ABOVE the viewer cases. Reorder mode lives inside
the hero, so without it Escape would close the whole viewer and take the
in-flight arrangement with it."
```

---

## Task 8: Reorder mode

**Files:**
- Create: `Muse/Muse/Views/Editor/EditorReorderRow.swift`
- Create: `Muse/Muse/Views/Editor/EditorReorderBar.swift`
- Modify: `Muse/Muse/Views/Editor/EditorView.swift`
- Modify: `Muse/Muse/Views/Editor/EditorPanel.swift`

**Interfaces:**
- Consumes: `EditorWorkspaceStore` (Task 3), `ReorderMath.isLeftColumn` / `.slot` / `.rowShift` / `.insertionLineY` (Task 2 + existing), `PanelContrast.Ink`.
- Produces: `struct EditorReorderRow: View`, `struct EditorReorderBar: View`, `struct EditorModuleFramePreference: PreferenceKey`.

**Design note (deviation from spec §7, deliberate):** the spec said `EditorSection` would gain a reorder presentation. It does not. Reorder mode renders a **completely different, simple row view** instead of the card — which achieves "cards force-collapse" by simply not drawing cards, keeps `EditorSection` untouched, and makes "nothing inside a card is reachable" structurally true rather than a set of guards. `AppSettings.editorExpandedSections` is never written, so every card returns to its previous open/closed state on exit for free.

- [ ] **Step 1: Write the collapsed, wiggling row**

Create `Muse/Muse/Views/Editor/EditorReorderRow.swift`:

```swift
//
//  EditorReorderRow.swift
//  Muse
//
//  One module, while you are rearranging the editor's panels.
//
//  This is NOT an EditorSection with its content hidden — it is a different
//  view entirely. That is what makes "nothing inside a card is reachable"
//  structurally true instead of a list of guards on every slider: there is no
//  inside. It also means AppSettings.editorExpandedSections is never written,
//  so every card returns to its previous open/closed state on exit for free.
//
//  The wiggle is the iOS home-screen tell. Without it a panel of collapsed
//  bars reads as broken rather than as a mode.
//

import SwiftUI
import AppKit

struct EditorReorderRow: View {
    let module: EditorModule
    let ink: PanelContrast.Ink
    /// Dimmed and still while it is the one being dragged — an opaque copy
    /// follows the cursor instead (see EditorView.draggedModuleOverlay), which
    /// keeps it above every bar it passes without per-row zIndex juggling.
    var isDragging: Bool
    /// Phase offset so the twelve bars do not wiggle in lockstep, which reads
    /// as one shaking slab rather than twelve loose cards.
    var wigglePhase: Double

    @State private var wiggling = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(module.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink.labelText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink.baseColor.opacity(0.8))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(hovering ? ink.cardFill.opacity(0.9) : ink.cardFill))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .rotationEffect(.degrees(wiggling && !isDragging ? 0.7 : -0.7))
        .animation(.easeInOut(duration: 0.13).repeatForever(autoreverses: true)
                    .delay(wigglePhase),
                   value: wiggling)
        .opacity(isDragging ? 0 : 1)
        .onHover { hovering = $0; syncCursor() }
        .onAppear { wiggling = true }
        .onDisappear { clearCursor() }
        .accessibilityLabel(Text(module.title))
        .accessibilityHint(Text("Drag to move this card. Use the buttons below to save or cancel."))
    }

    // The open hand / closed fist discipline the editor already uses for
    // panning. A bare .set() is clobbered by AppKit's per-mouse-move cursor
    // recalculation, and mismatched push/pop corrupts the stack for the WHOLE
    // app — so pushes are tracked and popped exactly once.
    @State private var pushed = false

    private func syncCursor() {
        let want = hovering && !isDragging
        if want && !pushed { pushed = true; NSCursor.openHand.push() }
        else if !want && pushed { pushed = false; NSCursor.pop() }
    }

    private func clearCursor() {
        if pushed { pushed = false; NSCursor.pop() }
    }
}

/// Each module bar's frame in the reorder coordinate space, so the drag can map
/// a position to a column and an insertion slot. Mirrors the sidebar's
/// RootFramePreference.
struct EditorModuleFramePreference: PreferenceKey {
    static let defaultValue: [EditorModule: CGRect] = [:]
    static func reduce(value: inout [EditorModule: CGRect],
                       nextValue: () -> [EditorModule: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
```

- [ ] **Step 2: Write the floating bar**

Create `Muse/Muse/Views/Editor/EditorReorderBar.swift`:

```swift
//
//  EditorReorderBar.swift
//  Muse
//
//  The floating control bar for reorder mode, over the photo near the bottom
//  and clear of both columns.
//
//  Two groups, because they are different kinds of thing: the left pair
//  rearranges, the right three end the mode. Cancel throws away whatever
//  either pair did.
//

import SwiftUI

struct EditorReorderBar: View {
    let ink: PanelContrast.Ink
    var onAllLeft: () -> Void
    var onAllRight: () -> Void
    var onReset: () -> Void
    var onCancel: () -> Void
    var onSave: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            button(String(localized: "All Left"), systemName: "arrow.left.to.line",
                   action: onAllLeft)
            button(String(localized: "All Right"), systemName: "arrow.right.to.line",
                   action: onAllRight)

            Divider().frame(height: 18).padding(.horizontal, 2)

            button(String(localized: "Reset"), systemName: "arrow.counterclockwise",
                   action: onReset)
            button(String(localized: "Cancel"), systemName: nil, action: onCancel)
            button(String(localized: "Save"), systemName: nil, prominent: true, action: onSave)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule(style: .continuous).fill(ink.backing.opacity(0.94)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .environment(\.theme, theme.onPanel(ink))
    }

    private func button(_ label: String, systemName: String?,
                        prominent: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemName {
                    Image(systemName: systemName).font(.system(size: 9, weight: .bold))
                }
                Text(label).font(.system(size: 11, weight: prominent ? .semibold : .medium))
            }
            .foregroundStyle(prominent ? ink.selectionInk : ink.baseColor)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule(style: .continuous)
                .fill(prominent ? ink.selectionFill : ink.cardFill))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}
```

**Before writing:** confirm `PanelContrast.Ink` exposes `selectionInk`, `selectionFill`, `backing`, `cardFill`, `baseColor`, `labelText`. If the selection pair lives on `Theme` rather than `Ink`, take them from `theme.onPanel(ink)` instead and adjust.

```bash
grep -n "var \|let " Muse/Muse/Components/PanelContrast.swift | head -30
```

- [ ] **Step 3: Wire the mode into `EditorView`**

Add the drag state:

```swift
    // MARK: - Workspace reorder
    /// The module being dragged, and the frozen layout snapshot the slot math
    /// is measured against — the dragged bar's own frame moves with the drag
    /// and would corrupt it. Mirrors SidebarView's reorder state exactly.
    @State private var draggingModule: EditorModule?
    @State private var dragStartFrames: [EditorModule: CGRect] = [:]
    @State private var moduleFrames: [EditorModule: CGRect] = [:]
    @State private var dropTarget: Int?
    @State private var dropColumn: EditorColumn = .right
    @State private var dragTranslation: CGSize = .zero
    private static let reorderSpace = "editorReorderSpace"
```

In `columnContent`, branch on the mode:

```swift
    @ViewBuilder
    func columnContent(_ column: EditorColumn) -> some View {
        let modules = workspace.active.visible(in: column)
        if workspace.reorderMode {
            ForEach(Array(modules.enumerated()), id: \.element) { index, module in
                EditorReorderRow(module: module, ink: ink,
                                 isDragging: draggingModule == module,
                                 wigglePhase: Double(index) * 0.037)
                    .background(GeometryReader { geo in
                        Color.clear.preference(
                            key: EditorModuleFramePreference.self,
                            value: [module: geo.frame(in: .named(Self.reorderSpace))])
                    })
                    .offset(y: rowShift(module, in: column, index: index))
                    .gesture(reorderGesture(module))
            }
        } else {
            ForEach(modules) { module in
                card(for: module)
            }
        }
    }
```

The gesture, mirroring `SidebarView.rootRow`'s `ReorderContext` exactly:

```swift
    private func reorderGesture(_ module: EditorModule) -> some Gesture {
        DragGesture(coordinateSpace: .named(Self.reorderSpace))
            .onChanged { value in
                if draggingModule != module {
                    // A layout snapshot is needed to compute slots; without one
                    // everything resolves to "append to end".
                    guard !moduleFrames.isEmpty else { return }
                    draggingModule = module
                    dragStartFrames = moduleFrames
                }
                dragTranslation = value.translation
                let column: EditorColumn = ReorderMath.isLeftColumn(
                    x: value.location.x, containerWidth: canvasSize.width) ? .left : .right
                let others = otherModules(in: column)
                let slot = ReorderMath.slot(
                    forY: value.location.y,
                    orderedStartFrames: others.map { dragStartFrames[$0] })
                if slot != dropTarget || column != dropColumn {
                    // Animate the PARTING only, never the finger-follow offset.
                    withAnimation(.easeInOut(duration: 0.16)) {
                        dropTarget = slot
                        dropColumn = column
                    }
                }
            }
            .onEnded { _ in commitReorder(module) }
    }

    /// The visible modules of `column` EXCLUDING the dragged one — insertion
    /// happens among these, since the dragged bar is conceptually lifted out.
    private func otherModules(in column: EditorColumn) -> [EditorModule] {
        workspace.active.visible(in: column).filter { $0 != draggingModule }
    }

    private func rowShift(_ module: EditorModule, in column: EditorColumn,
                          index: Int) -> CGFloat {
        guard let dragging = draggingModule, dragging != module,
              column == dropColumn else { return 0 }
        let pitch = (dragStartFrames[dragging]?.height ?? 34) + 14   // + VStack spacing
        let draggedIndex = workspace.active.visible(in: column).firstIndex(of: dragging)
        return ReorderMath.rowShift(forIndex: index, draggedIndex: draggedIndex,
                                    dropTarget: dropTarget, pitch: pitch)
    }

    /// Commit WITHOUT animation: after parting, the bars are already in their
    /// final visual positions, so writing the array and clearing the offsets in
    /// the same frame is seamless. Animating here double-moves them.
    private func commitReorder(_ module: EditorModule) {
        defer {
            draggingModule = nil
            dropTarget = nil
            dragStartFrames = [:]
            dragTranslation = .zero
        }
        guard let slot = dropTarget else { return }
        var next = workspace.active
        next.move(module, toColumn: dropColumn, visibleSlot: slot)
        workspace.updateDraft(next)
    }
```

In `body`, add the coordinate space, the insertion line, the dragged overlay and the bar:

```swift
        .coordinateSpace(name: Self.reorderSpace)
```

and inside the root `ZStack`, after the panels:

```swift
            if workspace.reorderMode {
                // The insertion line draws in the PanelContrast-resolved accent
                // — the same blue as a selected tab — because the editor
                // backdrop runs white to black and a fixed colour is illegible
                // on at least one of them.
                insertionLine
                draggedModuleOverlay
                EditorReorderBar(
                    ink: ink,
                    onAllLeft: { moveAll(to: .left) },
                    onAllRight: { moveAll(to: .right) },
                    onReset: { workspace.resetDraft() },
                    onCancel: { workspace.cancelReorder() },
                    onSave: { workspace.saveReorder() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 28)
            }
```

with:

```swift
    private func moveAll(to column: EditorColumn) {
        var next = workspace.active
        next.moveAll(to: column)
        withAnimation(.easeInOut(duration: 0.2)) { workspace.updateDraft(next) }
    }
```

Write `insertionLine` and `draggedModuleOverlay` against `SidebarView.insertionLine` and `SidebarView.draggedRowOverlay` — same shapes, editor ink:

```swift
    /// A thin accent rule at the gap the bar will land in — an overshoot cue.
    @ViewBuilder
    private var insertionLine: some View {
        if let y = ReorderMath.insertionLineY(
            dropTarget: dropTarget,
            orderedLiveFrames: otherModules(in: dropColumn).map { moduleFrames[$0] }),
           draggingModule != nil {
            RoundedRectangle(cornerRadius: 1)
                .fill(panelTheme.controlAccent)
                .frame(width: ViewerGeometry.columnWidth, height: 2)
                .position(x: columnCentreX(dropColumn), y: y)
        }
    }

    /// An opaque copy of the dragged bar, above every bar it passes — a single
    /// floating copy is simpler and more reliable than per-row zIndex juggling.
    @ViewBuilder
    private var draggedModuleOverlay: some View {
        if let module = draggingModule, let start = dragStartFrames[module] {
            EditorReorderRow(module: module, ink: ink, isDragging: false, wigglePhase: 0)
                .frame(width: ViewerGeometry.columnWidth)
                .scaleEffect(1.02)
                .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
                .position(x: start.midX + dragTranslation.width,
                          y: start.midY + dragTranslation.height)
                .allowsHitTesting(false)
        }
    }
```

- [ ] **Step 4: Bring the column backing up in reorder mode**

In `EditorPanel`, the backing currently rises only while zoomed. In reorder mode the bars are thin with gaps between them, so an insertion line would be drawn over the photograph and vanish against a bright one. Change the two call sites in `EditorView.body`:

```swift
                        backingVisible: isZoomed || workspace.reorderMode,
```

Add a note in `EditorPanel.swift` above `backingVisible`:

```swift
    /// The canvas is zoomed (so the photo runs under this panel) OR the
    /// workspace is being rearranged — in reorder mode the cards are thin bars
    /// with gaps between them, and an insertion line drawn over the photograph
    /// disappears against a bright one. Either way, bring the solid slab up.
```

- [ ] **Step 5: Collect the frames**

On the `HStack` holding the two panels in `EditorView.body`:

```swift
            .onPreferenceChange(EditorModuleFramePreference.self) { moduleFrames = $0 }
```

- [ ] **Step 6: Build and drive it**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Release build 2>&1 | tail -5
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests test 2>&1 | tail -5
rm -rf ~/Library/Developer/Xcode/DerivedData/Muse-*/Build/Products/Debug/Muse.app
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build 2>&1 | tail -3
stat -f '%Sm %N' ~/Library/Developer/Xcode/DerivedData/Muse-*/Build/Products/Debug/Muse.app/Contents/MacOS/Muse
```

Confirm the binary's mtime is from this minute, then launch and check by hand:
1. Open a photo → Edit → View ▸ Editor Workspace ▸ Reorder Modules.
2. Bars collapse and wiggle; no slider is reachable.
3. Hover a bar → open hand. Drag → closed fist, bars part, accent line marks the gap.
4. Drag a left bar to the right column; it lands.
5. All Right → left column empties, photo does **not** move yet.
6. Save → photo glides left into the freed space.
7. Re-enter, Cancel → nothing changed. Escape → same.
8. Change the backdrop to white, then to black; the insertion line stays visible in both.

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Views/Editor/
git commit -m "Reorder mode: collapsed wiggling bars you can drag between columns

The drag is the sidebar's, deliberately — same part-and-insert, same
insertion line, same ReorderMath. Learn it in one place, you know it in
the other. Only the column decision is new, and it is a midpoint split
because a column can be empty and empty columns have no frames to hit.

A module bar is NOT an EditorSection with its content hidden; it is a
different view. That is what makes 'nothing inside a card is reachable'
structurally true rather than a guard on every slider, and it means the
expanded-sections preference is never written, so every card comes back
the way you left it.

The column backing comes up for the mode. The bars are thin with gaps
between them, and an insertion line drawn over the photograph disappears
against a bright one — resolved accent or not."
```

---

## Task 9: Localization, accessibility, and the docs

**Files:**
- Modify: `Muse/Muse/Localizable.xcstrings`
- Modify: `docs/new-build/FEATURE-LEDGER.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Export and fill French**

Run:
```bash
mkdir -p /tmp/muse-loc
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj \
  -localizationPath /tmp/muse-loc -exportLanguage fr 2>&1 | tail -5
```

This **write-backs** every new key into the source `.xcstrings` — a plain build does not. Then fill each empty `fr` value. New keys to expect:

| English | French |
|---|---|
| Editor Workspace | Espace de travail de l'éditeur |
| Default Layout | Disposition par défaut |
| Customize Modules… | Personnaliser les modules… |
| Reorder Modules | Réorganiser les modules |
| Customize Modules | Personnaliser les modules |
| Choose which control cards the editor shows. Hidden cards keep their place and return where they were. | Choisissez les cartes de contrôle affichées par l'éditeur. Les cartes masquées conservent leur place et reviennent là où elles étaient. |
| At least one card has to stay visible | Au moins une carte doit rester visible |
| Show or hide this card in the editor | Afficher ou masquer cette carte dans l'éditeur |
| All Left | Tout à gauche |
| All Right | Tout à droite |
| Save | Enregistrer |
| Cancel | Annuler |
| Drag to move this card. Use the buttons below to save or cancel. | Faites glisser pour déplacer cette carte. Utilisez les boutons ci-dessous pour enregistrer ou annuler. |

The twelve module titles (`TOOLS`, `HISTOGRAM`, …) already exist — `EditorModule.title` reuses the exact strings `EditorView` was passing, so no new keys and no re-translation.

- [ ] **Step 2: Verify zero untranslated**

Run:
```bash
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj \
  -localizationPath /tmp/muse-loc2 -exportLanguage fr 2>&1 | grep -i "untranslated\|error"
```
Expected: 0 untranslated.

- [ ] **Step 3: Check for unlocalized strings in the new code**

Run:
```bash
grep -rn '"' --include="*.swift" \
  Muse/Muse/Views/Editor/EditorCustomizeModal.swift \
  Muse/Muse/Views/Editor/EditorReorderBar.swift \
  Muse/Muse/Views/Editor/EditorReorderRow.swift \
  Muse/Muse/Components/EditorWorkspace.swift \
  | grep -v "String(localized:\|Text(\|systemName:\|//\|accessibilityLabel(Text\|help(Text"
```
Expected: only `rawValue` strings, coordinate-space names, and preference keys — never user-facing text.

- [ ] **Step 4: Add the FEATURE-LEDGER row**

Append to `docs/new-build/FEATURE-LEDGER.md`:

```markdown
| Editor workspace (hide / reorder / one-column) | ✅ 40 unit tests (`EditorWorkspaceTests`, `EditorWorkspaceStoreTests`, + `ReorderMathTests`/`EscapeActionTests`/`EditorCanvasGeometryTests` additions) | ✅ spec + plan reviewed | ⚠️ **PARTIAL** — the drag, the wiggle and the cursor cannot be proven from a green suite. Runtime plan: (1) enter reorder mode, confirm every card is a bar and no slider is reachable; (2) hover → open hand, drag → closed fist, and the cursor is clean after Cancel; (3) the insertion line is visible on the WHITE backdrop and on the BLACK one; (4) a cross-column drag lands; (5) All Right → Save → the photo glides left rather than jumping; (6) Cancel and Escape both restore; (7) quit and relaunch — the layout persisted; (8) Customize honours Escape and its last checkbox is inert. |
```

- [ ] **Step 5: Add the CLAUDE.md row**

Add one line to the implementation-status table, after Polish 32:

```markdown
| Polish 33 — **editor workspace** (hide modules via a Customize modal; drag-reorder within and across columns; one column is the state where a column is empty, not a mode; canvas insets follow the cards; `EditorView` 1,682 → ~550 lines) | ✅ built + tested; **runtime PARTIAL — see FEATURE-LEDGER** | `feat/next-155` |
```

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Localizable.xcstrings docs/ CLAUDE.md
git commit -m "Localize the workspace strings and record the feature

Thirteen new keys, French filled, 0 untranslated. The twelve module
titles are not among them — EditorModule.title reuses the exact strings
EditorView was already passing, so the headings and the Customize list
can never disagree about what a card is called.

The ledger row is honest about what is unproven: the drag, the wiggle and
the cursor stack cannot be shown green by a unit suite, and the insertion
line needs checking against the white backdrop AND the black one."
```

---

## Task 10: Verification checkpoint

- [ ] **Step 1: Release build, warning-free**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Release build 2>&1 \
  | grep -E "warning:|error:|BUILD" | tail -20
```
Expected: `** BUILD SUCCEEDED **`, zero `warning:` lines.

- [ ] **Step 2: Full unit target**

Run:
```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests test 2>&1 \
  | grep -E "Executed|TEST" | tail -5
```
Expected: `** TEST SUCCEEDED **`, ~2,048 tests (2,002 + ~46).

- [ ] **Step 3: Audit invariants**

Run:
```bash
./scripts/audit-invariants.sh
```
Expected: 15/15 pass.

- [ ] **Step 4: UI surface drive**

Run:
```bash
osascript -e 'quit app "Muse"' 2>/dev/null || true
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse \
  -only-testing:MuseUITests/MuseSurfaceDriveTests test 2>&1 | tail -10
```
Expected: `** TEST SUCCEEDED **`. **Quit all but one Muse instance first** — GRDB's `busyMode` is `.immediateError`, and two instances against one database manufacture phantom "my edit didn't save" bugs.

- [ ] **Step 5: Line budget**

Run:
```bash
wc -l Muse/Muse/Views/Editor/*.swift Muse/Muse/Components/EditorWorkspace.swift | sort -rn | head
```
Expected: nothing over 600.

- [ ] **Step 6: Commit any fixes and push the branch**

```bash
git status --short
git push -u origin feat/next-155
```

---

## Self-Review

**Spec coverage**

| Spec section | Task |
|---|---|
| §2 twelve modules, ids, granularity | 1 |
| §2 chrome row is not a module | 5 (right panel always draws), 6 (top inset fixed) |
| §3 data model + invariant | 1 |
| §3 load rules (unknown / missing / malformed) | 1, 3 |
| §4 store on the `EditorChromeCommand` pattern | 3 |
| §5 menu, naming, disabling | 7 |
| §6 Customize: live, panel order, last-inert, no reorder | 7 |
| §7 reorder: collapse, wiggle, cursor, backing, insertion line, floating bar, Escape, dismissal-cancels | 8 (Escape resolver in 7) |
| §8 canvas geometry | 6 |
| §10 files + line budget | 4, 10 |
| §11 performance rules (persist on Save, not `AppState`) | 3 |
| §12 testing | 1, 2, 3, 6, 7, 9, 10 |

No gaps.

**Placeholder scan** — no TBD / TODO / "handle edge cases" / "similar to Task N". Every code step carries real code. Two steps deliberately ask the implementer to `grep` first (the modal-card wrapper's real name in Task 7 Step 4, `PanelContrast.Ink`'s real members in Task 8 Step 2) rather than guessing at an API I have not read; both give the exact command and what to do with the answer.

**Type consistency** — checked across tasks: `EditorWorkspace.move(_:toColumn:visibleSlot:)`, `moveAll(to:)`, `setHidden(_:_:)`, `visible(in:)`, `isEmpty(_:)`, `visibleCount`, `EditorWorkspaceStore.active` / `.reorderMode` / `.updateDraft(_:)` / `.resetDraft()` / `.saveReorder()` / `.cancelReorder()` / `.editorDismissed()`, `ReorderMath.isLeftColumn(x:containerWidth:)`, `EditorView.panelInsets(leftEmpty:rightEmpty:chromeProgress:)`, `EditorView.card(for:)` / `.columnContent(_:)`, `EditorModule.title` — each is defined once and used with the same signature everywhere.

**Known risk, called out rather than hidden:** Task 8's drag wiring is written against `SidebarView`'s reorder, which is tuned for a single column of uniform rows in a scroll view. The editor's bars sit in two independently-scrolling `EditorPanel`s, so a drag that crosses columns while one of them is scrolled may compute a slot against frames measured in a different scroll offset. `moduleFrames` is captured in the shared `reorderSpace`, which should absorb it, but this is the part most likely to need adjustment when driven by hand at Task 8 Step 6. The sidebar carries the same class of known limitation in its own comment; final placement stays correct either way, because the commit is identity-based.
