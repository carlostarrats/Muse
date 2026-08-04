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

    // MARK: - Visible index (the drag's per-row lookup)

    func testVisibleIndexSkipsHiddenModules() {
        var w = EditorWorkspace.standard
        w.setHidden(.looks, true)
        XCTAssertEqual(w.visibleIndex(of: .light, in: .right), 0)
        XCTAssertEqual(w.visibleIndex(of: .zones, in: .right), 1)
    }

    func testVisibleIndexIsNilForAHiddenOrAbsentModule() {
        var w = EditorWorkspace.standard
        w.setHidden(.looks, true)
        XCTAssertNil(w.visibleIndex(of: .looks, in: .right))
        XCTAssertNil(w.visibleIndex(of: .tools, in: .right))
    }

    func testVisibleIndexMatchesTheArrayItReplaced() {
        // It exists only to avoid allocating; it must agree with the obvious
        // version everywhere, including with things hidden.
        var w = EditorWorkspace.standard
        w.setHidden(.zones, true)
        w.setHidden(.tools, true)
        for column in EditorColumn.allCases {
            for module in EditorModule.allCases {
                XCTAssertEqual(w.visibleIndex(of: module, in: column),
                               w.visible(in: column).firstIndex(of: module),
                               "\(module) in \(column)")
            }
        }
    }

    /// The arithmetic the VoiceOver "Move Down" action relies on. `move`
    /// removes the module BEFORE computing slots, so moving down by one needs
    /// no +1 — removal already shifted everything below it up. Getting this
    /// wrong moves the card two places, or not at all.
    func testMovingDownOnePlaceLandsExactlyOnePlaceDown() {
        var w = EditorWorkspace(left: [], right: [.looks, .light, .zones, .color],
                                hidden: [])
        let index = w.visibleIndex(of: .light, in: .right)!
        w.move(.light, toColumn: .right, visibleSlot: index + 1)
        XCTAssertEqual(w.right, [.looks, .zones, .light, .color])
    }

    func testMovingUpOnePlaceLandsExactlyOnePlaceUp() {
        var w = EditorWorkspace(left: [], right: [.looks, .light, .zones, .color],
                                hidden: [])
        let index = w.visibleIndex(of: .zones, in: .right)!
        w.move(.zones, toColumn: .right, visibleSlot: index - 1)
        XCTAssertEqual(w.right, [.looks, .zones, .light, .color])
    }

    func testMovingDownRepeatedlyWalksAModuleToTheEnd() {
        var w = EditorWorkspace(left: [], right: [.looks, .light, .zones, .color],
                                hidden: [])
        for _ in 0..<3 {
            guard let i = w.visibleIndex(of: .looks, in: .right) else { break }
            guard i + 1 < w.visible(in: .right).count else { break }
            w.move(.looks, toColumn: .right, visibleSlot: i + 1)
        }
        XCTAssertEqual(w.right, [.light, .zones, .color, .looks])
    }

    func testMoveClampsANegativeSlotToTheHead() {
        var w = EditorWorkspace.standard
        w.move(.crop, toColumn: .left, visibleSlot: -5)
        XCTAssertEqual(w.left.first, .crop)
    }

    func testIsEmptyTracksVisibleModulesNotStoredOnes() {
        var w = EditorWorkspace.standard
        XCTAssertFalse(w.isEmpty(.left))
        for m in [EditorModule.tools, .histogram, .insights, .history] {
            w.setHidden(m, true)
        }
        XCTAssertTrue(w.isEmpty(.left), "a column of only-hidden cards draws nothing")
        XCTAssertEqual(w.left.count, 4, "but they keep their places")
    }
}
