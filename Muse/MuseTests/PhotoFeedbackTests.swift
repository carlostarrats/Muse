import XCTest
@testable import Muse

/// The curated matrix IS the acceptance test for this feature: the thresholds
/// are tunable, the SHAPE of the diagnosis is not.
final class PhotoFeedbackTests: XCTestCase {

    private func inputs(iso: Int? = nil, exposureSeconds: Double? = nil, fNumber: Double? = nil,
                        focalLength35: Double? = nil, flashFired: Bool? = nil,
                        sharpness: Double? = nil, faceCount: Int? = nil,
                        clipHighR: Double? = nil, clipHighG: Double? = nil,
                        clipHighB: Double? = nil, clipLow: Double? = nil,
                        noiseSigma: Double? = nil) -> PhotoFeedback.Inputs {
        PhotoFeedback.Inputs(iso: iso, exposureSeconds: exposureSeconds, fNumber: fNumber,
                             focalLength35: focalLength35, flashFired: flashFired,
                             sharpness: sharpness, faceCount: faceCount,
                             clipHighR: clipHighR, clipHighG: clipHighG, clipHighB: clipHighB,
                             clipLow: clipLow, noiseSigma: noiseSigma)
    }

    private func contains(_ notes: [PhotoFeedback.Note],
                          _ match: (PhotoFeedback.Note) -> Bool) -> Bool {
        notes.contains(where: match)
    }

    /// A clean, well-exposed photo says NOTHING. Silence is the good outcome.
    func testFastShutterLowISOCleanProducesNoNotes() {
        let i = inputs(iso: 100, exposureSeconds: 1.0 / 500, fNumber: 8, focalLength35: 50,
                       flashFired: false, sharpness: 5.0,
                       clipHighR: 0, clipHighG: 0, clipHighB: 0, clipLow: 0, noiseSigma: 0.5)
        XCTAssertTrue(PhotoFeedback.notes(for: i).isEmpty)
    }

    func testHandheldSlowShutterProducesMotionBlurRisk() {
        let i = inputs(iso: 400, exposureSeconds: 1.0 / 15, fNumber: 4, focalLength35: 50,
                       flashFired: false, sharpness: 3.0, noiseSigma: 1.0)
        XCTAssertTrue(contains(PhotoFeedback.notes(for: i)) {
            if case .motionBlurRisk = $0 { true } else { false }
        })
    }

    /// The flash IS the exposure — a 1/15s frame lit by flash isn't a blur risk.
    func testFlashSuppressesMotionBlurNote() {
        let i = inputs(iso: 400, exposureSeconds: 1.0 / 15, fNumber: 4, focalLength35: 50,
                       flashFired: true, sharpness: 3.0, noiseSigma: 1.0)
        XCTAssertFalse(contains(PhotoFeedback.notes(for: i)) {
            if case .motionBlurRisk = $0 { true } else { false }
        })
    }

    func testHighISOProducesNoiseNote() {
        let i = inputs(iso: 6400, exposureSeconds: 1.0 / 200, fNumber: 4, focalLength35: 50,
                       flashFired: false, sharpness: 4.0, noiseSigma: 8.0)
        guard case .highISONoise(let iso, let wellControlled)? = PhotoFeedback.notes(for: i)
            .first(where: { if case .highISONoise = $0 { true } else { false } })
        else { return XCTFail("expected highISONoise") }
        XCTAssertEqual(iso, 6400)
        XCTAssertFalse(wellControlled)
    }

    /// A modern sensor at ISO 6400 with a low measured sigma earns the
    /// qualifier rather than a warning.
    func testHighISOWithLowNoiseSigmaIsWellControlled() {
        let i = inputs(iso: 6400, exposureSeconds: 1.0 / 200, fNumber: 4, focalLength35: 50,
                       flashFired: false, sharpness: 4.0, noiseSigma: 0.3)
        guard case .highISONoise(_, let wellControlled)? = PhotoFeedback.notes(for: i)
            .first(where: { if case .highISONoise = $0 { true } else { false } })
        else { return XCTFail("expected highISONoise") }
        XCTAssertTrue(wellControlled)
    }

    /// Cause beats symptom: one blur gets one explanation.
    func testSoftFocusSuppressedWhenMotionBlurAlreadyFires() {
        let i = inputs(iso: 400, exposureSeconds: 1.0 / 10, fNumber: 4, focalLength35: 50,
                       flashFired: false, sharpness: 0.5, noiseSigma: 1.0)
        let notes = PhotoFeedback.notes(for: i)
        XCTAssertTrue(contains(notes) { if case .motionBlurRisk = $0 { true } else { false } })
        XCTAssertFalse(contains(notes) { if case .softFocus = $0 { true } else { false } })
    }

    func testSoftFocusFiresAloneWhenNoMotionBlurRisk() {
        let i = inputs(iso: 400, exposureSeconds: 1.0 / 500, fNumber: 4, focalLength35: 50,
                       flashFired: false, sharpness: 0.5, noiseSigma: 1.0)
        XCTAssertTrue(contains(PhotoFeedback.notes(for: i)) {
            if case .softFocus = $0 { true } else { false }
        })
    }

    func testThinFocusPlaneFacesVariant() {
        let i = inputs(iso: 400, exposureSeconds: 1.0 / 500, fNumber: 1.8, focalLength35: 85,
                       flashFired: false, sharpness: 5.0, faceCount: 1, noiseSigma: 1.0)
        guard case .thinFocusPlane(let fNumber, let hasFaces)? = PhotoFeedback.notes(for: i)
            .first(where: { if case .thinFocusPlane = $0 { true } else { false } })
        else { return XCTFail("expected thinFocusPlane") }
        XCTAssertEqual(fNumber, 1.8)
        XCTAssertTrue(hasFaces)
    }

    /// The order is the ranking, so the cap keeps the three most serious.
    func testSeverityOrderPutsClippingFirstAndCapsAtThree() {
        let i = inputs(iso: 6400, exposureSeconds: 1.0 / 8, fNumber: 1.4, focalLength35: 35,
                       flashFired: false, sharpness: 0.3, faceCount: 0,
                       clipHighR: 0.05, clipHighG: 0.01, clipHighB: 0.01,
                       clipLow: 0.1, noiseSigma: 9.0)
        let notes = PhotoFeedback.notes(for: i)
        XCTAssertLessThanOrEqual(notes.count, PhotoFeedback.maxNotes)
        guard case .clippedHighlights = notes[0] else { return XCTFail("clipping ranks first") }
        guard case .crushedShadows = notes[1] else { return XCTFail("shadows rank second") }
        guard case .motionBlurRisk = notes[2] else { return XCTFail("motion blur ranks third") }
    }

    func testMaxNotesCapIsThree() {
        XCTAssertEqual(PhotoFeedback.maxNotes, 3)
    }

    /// Absent columns never fire a rule — an unanalyzed photo gets no card,
    /// not a card full of guesses.
    func testAbsentFieldsNeverFireARule() {
        XCTAssertTrue(PhotoFeedback.notes(for: inputs()).isEmpty)
    }

    func testDisplayTextNonEmptyForEveryNoteCase() {
        let cases: [PhotoFeedback.Note] = [
            .clippedHighlights(percent: 0.004, channel: .red),
            .clippedHighlights(percent: 0.004, channel: nil),
            .crushedShadows(percent: 0.03),
            .motionBlurRisk(shutterSeconds: 1.0 / 15),
            .highISONoise(iso: 6400, wellControlled: false),
            .highISONoise(iso: 6400, wellControlled: true),
            .softFocus,
            .thinFocusPlane(fNumber: 1.8, hasFaces: true),
            .thinFocusPlane(fNumber: 1.8, hasFaces: false),
        ]
        for c in cases { XCTAssertFalse(c.displayText.isEmpty) }
    }
}
