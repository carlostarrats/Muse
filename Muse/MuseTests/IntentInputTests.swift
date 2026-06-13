import XCTest
@testable import Muse

final class IntentInputTests: XCTestCase {
    func testIsScreenshotTrueWhenVisionKindScreenshotTagPresent() {
        let tags = [
            IntelTag(label: "computer screen", confidence: 0.7, source: "vision"),
            IntelTag(label: "screenshot", confidence: nil, source: "vision-kind"),
        ]
        XCTAssertTrue(IntentInput.isScreenshot(tags: tags))
    }

    func testIsScreenshotFalseForOtherKinds() {
        let tags = [
            IntelTag(label: "dog", confidence: 0.9, source: "vision"),
            IntelTag(label: "photo", confidence: nil, source: "vision-kind"),
        ]
        XCTAssertFalse(IntentInput.isScreenshot(tags: tags))
    }

    func testVisionLabelsKeepsOnlyVisionSource() {
        let tags = [
            IntelTag(label: "computer screen", confidence: 0.7, source: "vision"),
            IntelTag(label: "blue", confidence: nil, source: "vision-color"),
            IntelTag(label: "screenshot", confidence: nil, source: "vision-kind"),
        ]
        XCTAssertEqual(IntentInput.visionLabels(tags: tags), ["computer screen"])
    }

    func testOcrSnippetTruncates() {
        let long = String(repeating: "a", count: 1000)
        XCTAssertEqual(IntentInput.ocrSnippet(long).count, 600)
    }
}
