import XCTest
@testable import Muse

final class EditStackCodecTests: XCTestCase {
    func fixtureStack() -> EditStack {
        var stack = EditStack.fresh()
        var tone = ToneParams.neutral; tone.exposureEV = 0.5; tone.contrast = 0.2
        stack.adjustments = [.tone(tone)]
        return stack
    }

    func testEncodeDecodeRoundTrips() throws {
        let stack = fixtureStack()
        let json = try EditStackCodec.encode(stack)
        let decoded = EditStackCodec.decode(json)
        XCTAssertEqual(decoded, stack.normalized())
    }

    /// The tripwire: this literal is the canonical hash for the fixture above.
    /// If it changes, every edited thumbnail in every library just re-keyed —
    /// which is only acceptable alongside a deliberate schemaVersion bump.
    func testHashIsStablePinnedFixture() throws {
        let hash = EditStackCodec.hash(fixtureStack())
        XCTAssertEqual(hash.count, 64)
        XCTAssertEqual(hash, EditStackCodec.hash(fixtureStack()))
        XCTAssertEqual(hash, EditStackCodecTests.pinnedFixtureHash)
    }

    static let pinnedFixtureHash =
        "349a57c39e0aa139dc06baef4dc690d00d8d6d47b17bb6abb3e565242280356a"

    func testDecodeReturnsNilForNewerSchemaVersion() throws {
        var stack = fixtureStack()
        stack.schemaVersion = EditStack.currentSchemaVersion + 1
        let json = try EditStackCodec.encode(stack)
        XCTAssertNil(EditStackCodec.decode(json))
    }

    func testDecodeReturnsNilForCorruptJSON() {
        XCTAssertNil(EditStackCodec.decode("{not valid json"))
    }

    func testDecodeReturnsNilForUnknownAdjustmentType() {
        // Forward-compatibility mechanism: an unknown case fails the WHOLE
        // decode, so an older build renders the ORIGINAL rather than a
        // partial stack.
        let json = """
        {"adjustments":[{"params":{},"type":"toneZone"}],"masks":[],\
        "processVersion":1,"schemaVersion":1}
        """
        XCTAssertNil(EditStackCodec.decode(json))
    }

    func testDecodeNeverBumpsVersionOnUnchangedStack() throws {
        let stack = fixtureStack()
        let json = try EditStackCodec.encode(stack)
        let decoded = try XCTUnwrap(EditStackCodec.decode(json))
        let reencoded = try EditStackCodec.encode(decoded)
        XCTAssertEqual(json, reencoded)
    }

    func testProcessVersionBeyondCurrentStillDecodes() throws {
        var stack = fixtureStack()
        stack.processVersion = EditStack.currentProcessVersion + 1
        let json = try EditStackCodec.encode(stack)
        let decoded = EditStackCodec.decode(json)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.processVersion, EditStack.currentProcessVersion + 1)
    }

    func testMaskSlotRoundTripsEmpty() throws {
        let stack = fixtureStack()
        XCTAssertEqual(stack.masks, [])
        let json = try EditStackCodec.encode(stack)
        XCTAssertTrue(json.contains("\"masks\""))
        let decoded = try XCTUnwrap(EditStackCodec.decode(json))
        XCTAssertEqual(decoded.masks, [])
    }
}
