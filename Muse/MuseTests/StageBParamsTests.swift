//
//  StageBParamsTests.swift
//  MuseTests
//
//  The three appended adjustments — HSL (8), split toning (9), grain (10).
//
//  The canonical-index assertions are the load-bearing ones: `Adjustment`'s
//  declaration order IS the canonical order, `normalized()` sorts by it, and
//  inserting a case mid-list rather than appending re-keys every edited
//  thumbnail's `stack_hash` in every library on earth.
//

import XCTest
@testable import Muse

final class StageBParamsTests: XCTestCase {

    // MARK: - HSL

    func testHSLNeutralIsAllZeroAcrossEightBands() {
        let p = HSLParams.neutral
        XCTAssertEqual(p.hue.count, 8)
        XCTAssertEqual(p.saturation.count, 8)
        XCTAssertEqual(p.luminance.count, 8)
        XCTAssertTrue(p.isNeutral)
    }

    func testHSLCanonicalIndexIsEight() {
        XCTAssertEqual(Adjustment.hsl(.neutral).canonicalIndex, 8)
    }

    /// A short or long array from a hand-edited sidecar must not index out of
    /// bounds in the renderer — `clamped()` normalizes LENGTH as well as
    /// range, exactly as `ToneZoneParams` does and for the same reason.
    func testHSLClampedNormalizesLengthAndRange() {
        let p = HSLParams(hue: [2.0], saturation: [],
                          luminance: Array(repeating: -9.0, count: 40))
        let c = p.clamped()
        XCTAssertEqual(c.hue.count, 8)
        XCTAssertEqual(c.saturation.count, 8)
        XCTAssertEqual(c.luminance.count, 8)
        XCTAssertEqual(c.hue[0], 1.0)          // clamped down from 2.0
        XCTAssertEqual(c.hue[1], 0)            // padded
        XCTAssertEqual(c.luminance[0], -1.0)   // clamped up from -9.0
    }

    func testHSLRoundTripsThroughTheCodec() throws {
        var stack = EditStack.fresh()
        stack.setHSL { $0.saturation[2] = 0.5 }          // yellow band
        let back = EditStackCodec.decode(try EditStackCodec.encode(stack))
        XCTAssertEqual(back?.hslParams?.saturation[2], 0.5)
    }

    func testHSLTransfersAsItsOwnGroup() {
        var source = EditStack.fresh()
        source.setHSL { $0.hue[0] = -0.3 }
        XCTAssertTrue(EditTransfer.adjustedGroups(of: source).contains(.hsl))

        let target = EditTransfer.apply(groups: [.hsl], from: source, onto: .fresh())
        XCTAssertEqual(target.hslParams?.hue[0], -0.3)
    }

    // MARK: - Split toning

    func testSplitToneCanonicalIndexIsNine() {
        XCTAssertEqual(Adjustment.splitTone(.neutral).canonicalIndex, 9)
    }

    /// A hue with no saturation tints nothing, so it must not read as an edit
    /// — otherwise merely opening the card and nudging a hue would persist a
    /// blob that changes no pixels.
    func testSplitToneHueWithoutSaturationIsNeutral() {
        var p = SplitToneParams.neutral
        p.shadowHue = 0.8
        p.highlightHue = 0.2
        XCTAssertTrue(p.isNeutral)

        p.shadowSaturation = 0.3
        XCTAssertFalse(p.isNeutral)
    }

    func testSplitToneClampedBoundsEveryField() {
        let p = SplitToneParams(shadowHue: 5, shadowSaturation: -3,
                                highlightHue: -9, highlightSaturation: 4, balance: 7)
        let c = p.clamped()
        XCTAssertEqual(c.shadowHue, 1)
        XCTAssertEqual(c.shadowSaturation, 0)      // saturation floors at 0
        XCTAssertEqual(c.highlightHue, 0)
        XCTAssertEqual(c.highlightSaturation, 1)
        XCTAssertEqual(c.balance, 1)
    }

    func testSplitToneRoundTripsAndTransfers() throws {
        var stack = EditStack.fresh()
        stack.setSplitTone { $0.shadowHue = 0.6; $0.shadowSaturation = 0.4 }
        let back = EditStackCodec.decode(try EditStackCodec.encode(stack))
        XCTAssertEqual(back?.splitToneParams?.shadowHue, 0.6)
        XCTAssertTrue(EditTransfer.adjustedGroups(of: stack).contains(.splitTone))
    }

    // MARK: - Grain

    func testGrainCanonicalIndexIsTen() {
        XCTAssertEqual(Adjustment.grain(.neutral).canonicalIndex, 10)
    }

    /// Amount is what makes grain real; size and roughness only shape a grain
    /// that is already there.
    func testGrainAmountZeroIsNeutral() {
        var p = GrainParams.neutral
        p.size = 0.9
        p.roughness = 0.7
        XCTAssertTrue(p.isNeutral)
        p.amount = 0.2
        XCTAssertFalse(p.isNeutral)
    }

    func testGrainClampedBoundsEveryField() {
        let c = GrainParams(amount: 3, size: -1, roughness: 9).clamped()
        XCTAssertEqual(c.amount, 1)
        XCTAssertEqual(c.size, 0)
        XCTAssertEqual(c.roughness, 1)
    }

    /// Determinism: the same content hash yields the same seed, a different one
    /// yields a different seed. This is what makes the grid tile, the on-screen
    /// preview and the export agree instead of producing three random fields —
    /// the specific failure Surface shipped.
    func testGrainSeedIsStableForAHashAndDiffersAcrossHashes() {
        let a = GrainParams.seed(forContentHash: "abc123")
        let b = GrainParams.seed(forContentHash: "abc123")
        let c = GrainParams.seed(forContentHash: "def456")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertTrue(a.isFinite)
    }

    func testGrainRoundTripsAndTransfers() throws {
        var stack = EditStack.fresh()
        stack.setGrain { $0.amount = 0.7; $0.size = 0.25 }
        let back = EditStackCodec.decode(try EditStackCodec.encode(stack))
        XCTAssertEqual(back?.grainParams?.amount, 0.7)
        XCTAssertEqual(back?.grainParams?.size, 0.25)
        XCTAssertTrue(EditTransfer.adjustedGroups(of: stack).contains(.grain))
    }

    // MARK: - Ordering across all three

    /// `normalized()` sorts by canonical index, so the three new cases must
    /// land after the eight that shipped — in this exact order.
    func testAllThreeSortAfterTheShippedEight() {
        var stack = EditStack.fresh()
        stack.setGrain { $0.amount = 0.5 }
        stack.setSplitTone { $0.shadowSaturation = 0.5 }
        stack.setHSL { $0.hue[0] = 0.5 }
        stack.setTone { $0.exposureEV = 1 }

        let indices = stack.normalized().adjustments.map(\.canonicalIndex)
        XCTAssertEqual(indices, indices.sorted())
        XCTAssertEqual(indices.suffix(3), [8, 9, 10])
    }

    /// A neutral instance of each must leave the whole stack neutral, so the
    /// editor storing a case the moment a card opens costs nothing.
    func testNeutralInstancesLeaveTheStackNeutral() {
        var stack = EditStack.fresh()
        stack.adjustments = [.hsl(.neutral), .splitTone(.neutral), .grain(.neutral)]
        XCTAssertTrue(stack.isNeutral)
    }
}
