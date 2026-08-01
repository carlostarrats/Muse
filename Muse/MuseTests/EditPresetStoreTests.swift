import XCTest
@testable import Muse

@MainActor
final class EditPresetStoreTests: XCTestCase {
    /// A preset must never carry geometry: a stored crop ambushes every photo
    /// it's applied to. This is the ONLY group presets exclude — copy/paste,
    /// which is a deliberate one-off, does offer it.
    func testPresetJSONExcludesTheGeometryGroup() throws {
        var stack = EditStack.fresh()
        stack.setTone { $0.exposureEV = 1 }
        stack.setGeometry { $0.crop = CropRect(x: 0, y: 0, w: 0.5, h: 0.5) }
        let decoded = try XCTUnwrap(
            EditStackCodec.decode(EditPresetStore.presetJSON(from: stack)))
        let groups = EditTransfer.adjustedGroups(of: decoded)
        XCTAssertFalse(groups.contains(.geometry))
        XCTAssertTrue(groups.contains(.tone))
    }

    func testPresetJSONKeepsEverythingElse() throws {
        var stack = EditStack.fresh()
        stack.setColor { $0.saturation = 0.4 }
        stack.setPresence { $0.clarity = 0.3 }
        stack.setVignette { $0.amount = -0.2 }
        let decoded = try XCTUnwrap(
            EditStackCodec.decode(EditPresetStore.presetJSON(from: stack)))
        XCTAssertEqual(EditTransfer.adjustedGroups(of: decoded),
                       [.color, .presence, .vignette])
    }

    func testPresetJSONIsCanonicalAndRoundTrips() throws {
        var stack = EditStack.fresh()
        stack.setTone { $0.exposureEV = 0.5 }
        let json = EditPresetStore.presetJSON(from: stack)
        XCTAssertEqual(json, EditPresetStore.presetJSON(from: stack))
        XCTAssertNotNil(EditStackCodec.decode(json))
    }
}

@MainActor
final class EditClipboardTests: XCTestCase {
    override func tearDown() {
        EditClipboard.shared.stack = nil
        EditClipboard.shared.groups = []
        super.tearDown()
    }

    func testEmptyClipboardHasNoContent() {
        XCTAssertFalse(EditClipboard.shared.hasContent)
    }

    func testCopyThenApplyIsCopyByValue() {
        var source = EditStack.fresh()
        source.setTone { $0.exposureEV = 1 }
        EditClipboard.shared.copy(source, groups: [.tone])
        let result = EditClipboard.shared.apply(onto: .fresh())
        XCTAssertEqual(result.toneParams?.exposureEV, 1)
        // Mutating the RESULT must not reach back into the clipboard.
        var mutated = result
        mutated.setTone { $0.exposureEV = 5 }
        XCTAssertEqual(EditClipboard.shared.stack?.toneParams?.exposureEV, 1)
    }

    func testApplyOnlyTransfersTheSelectedGroups() {
        var source = EditStack.fresh()
        source.setTone { $0.exposureEV = 1 }
        source.setColor { $0.saturation = 0.5 }
        EditClipboard.shared.copy(source, groups: [.tone])
        var target = EditStack.fresh()
        target.setColor { $0.saturation = -0.5 }
        let result = EditClipboard.shared.apply(onto: target)
        XCTAssertEqual(result.toneParams?.exposureEV, 1)
        XCTAssertEqual(result.colorParams?.saturation, -0.5, "unselected group kept the target's")
    }

    func testApplyWithNothingCopiedIsANoOp() {
        var target = EditStack.fresh()
        target.setTone { $0.exposureEV = 2 }
        XCTAssertEqual(EditClipboard.shared.apply(onto: target), target)
    }
}
