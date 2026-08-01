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

// MARK: - Spec 05: toneZone + lut

extension EditStackCodecTests {

    private func fixtureStackWithToneZoneAndLut() -> EditStack {
        var stack = EditStack.fresh()
        var tz = ToneZoneParams.neutral
        tz.gains[0] = -0.6; tz.gains[8] = 0.3
        stack.adjustments = [
            .tone(.neutral), .toneZone(tz),
            .lut(LutParams(lutHash: String(repeating: "ab", count: 32),
                           name: "Kodak 2383", strength: 0.75)),
        ]
        return stack
    }

    func testToneZoneAndLutRoundTrip() throws {
        let json = try EditStackCodec.encode(fixtureStackWithToneZoneAndLut())
        let decoded = try XCTUnwrap(EditStackCodec.decode(json))
        XCTAssertEqual(decoded.toneZoneParams?.gains[0], -0.6)
        XCTAssertEqual(decoded.toneZoneParams?.gains[8], 0.3)
        XCTAssertEqual(decoded.lutParams?.strength, 0.75)
        XCTAssertEqual(decoded.lutParams?.name, "Kodak 2383")
    }

    /// Appending the two cases at the END of the enum must not perturb ANY
    /// pre-existing stack's bytes — the Spec 04 pinned hash above is the real
    /// gate; this re-confirms determinism survived the extension.
    func testPreExistingFixtureHashIsUnchangedByAppendedCases() {
        XCTAssertEqual(EditStackCodec.hash(fixtureStack()), EditStackCodec.hash(fixtureStack()))
    }

    /// Decode does NOT normalize the array — the blob must round-trip
    /// byte-identical. `.clamped()` is the renderer's job, pinned here so a
    /// future refactor can't silently move the responsibility.
    func testWrongLengthGainsDecodeUnchangedAndClampOnDemand() throws {
        let json = """
        {"schemaVersion":\(EditStack.currentSchemaVersion),\
        "processVersion":\(EditStack.currentProcessVersion),\
        "adjustments":[{"type":"toneZone","params":{"gains":[0.2,-0.2]}}],\
        "masks":[]}
        """
        let decoded = try XCTUnwrap(EditStackCodec.decode(json))
        XCTAssertEqual(decoded.toneZoneParams?.gains.count, 2)
        XCTAssertEqual(decoded.toneZoneParams?.clamped().gains.count, ToneZoneParams.zoneCount)
    }

    /// Still the forward-compat mechanism: an unknown type fails the WHOLE
    /// decode so an older build renders the original rather than a partial
    /// stack it only half understands.
    func testUnknownAdjustmentTypeStillFailsWholeStackDecode() {
        let json = """
        {"schemaVersion":\(EditStack.currentSchemaVersion),\
        "processVersion":\(EditStack.currentProcessVersion),\
        "adjustments":[{"type":"futureCase","params":{}}],\
        "masks":[]}
        """
        XCTAssertNil(EditStackCodec.decode(json))
    }

    func testSchemaAndProcessVersionsAreUnchangedBySpec05() {
        // A new enum case is the wrapper's DESIGNED evolution path, not a
        // schema break: bumping either constant would make every older build
        // refuse stacks it can read perfectly well.
        XCTAssertEqual(EditStack.currentSchemaVersion, 1)
        XCTAssertEqual(EditStack.currentProcessVersion, 1)
    }
}
