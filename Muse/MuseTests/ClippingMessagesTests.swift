import XCTest
@testable import Muse

final class ClippingMessagesTests: XCTestCase {

    private func neutral() -> ClippingStats { .none }

    private func highlights(_ messages: [ClippingMessage]) -> ClippingMessage? {
        messages.first { if case .highlightsClipping = $0 { true } else { false } }
    }

    func testBelowFloorProducesNoMessages() {
        var c = neutral(); c.highR = 0.0005
        XCTAssertTrue(ClippingMessages.compose(c).isEmpty)
    }

    func testAtFloorProducesAMessage() {
        var c = neutral(); c.highR = 0.001; c.highG = 0.001; c.highB = 0.001
        XCTAssertFalse(ClippingMessages.compose(c).isEmpty)
    }

    func testDominantSingleChannelNamesIt() throws {
        var c = neutral(); c.highR = 0.03; c.highG = 0.005; c.highB = 0.005
        guard case .highlightsClipping(_, let channel, _)? = highlights(ClippingMessages.compose(c))
        else { return XCTFail("expected a highlightsClipping message") }
        XCTAssertEqual(channel, .red)
    }

    /// Three channels clipping together is ordinary blown highlights — naming
    /// one of them would imply a colour cast that isn't there.
    func testAllChannelsCloseTogetherProducesCombinedMessageWithNilChannel() {
        var c = neutral(); c.highR = 0.02; c.highG = 0.018; c.highB = 0.019
        guard case .highlightsClipping(_, let channel, _)? = highlights(ClippingMessages.compose(c))
        else { return XCTFail("expected a highlightsClipping message") }
        XCTAssertNil(channel)
    }

    func testShadowsCrushedFiresIndependentlyOfHighlights() {
        var c = neutral(); c.low = 0.05
        XCTAssertTrue(ClippingMessages.compose(c)
            .contains { if case .shadowsCrushed = $0 { true } else { false } })
    }

    func testAtMostTwoMessages() {
        var c = neutral(); c.highR = 0.5; c.highG = 0.5; c.highB = 0.5; c.low = 0.5
        XCTAssertLessThanOrEqual(ClippingMessages.compose(c).count, 2)
    }

    func testRegionPhrasingPresentWhenCentroidKnown() {
        var c = neutral(); c.highR = 0.02; c.highG = 0.02; c.highB = 0.02
        c.highMassCenterY = 0.1
        guard case .highlightsClipping(_, _, let region)? = highlights(ClippingMessages.compose(c))
        else { return XCTFail() }
        XCTAssertEqual(region, .top)
    }

    func testRegionPhrasingAbsentWhenCentroidNil() {
        var c = neutral(); c.highR = 0.02; c.highG = 0.02; c.highB = 0.02
        guard case .highlightsClipping(_, _, let region)? = highlights(ClippingMessages.compose(c))
        else { return XCTFail() }
        XCTAssertNil(region)
    }

    func testDisplayTextIsNonEmptyForEveryCase() {
        let cases: [ClippingMessage] = [
            .highlightsClipping(percent: 0.004, channel: .red, region: .top),
            .highlightsClipping(percent: 0.004, channel: nil, region: nil),
            .shadowsCrushed(percent: 0.03, region: .bottom),
            .shadowsCrushed(percent: 0.03, region: nil),
        ]
        for c in cases { XCTAssertFalse(c.displayText.isEmpty) }
    }
}
