//
//  ErrorRedactionTests.swift
//  MuseTests
//
//  Written against a REAL FileManager error, not a hand-built NSError. The
//  whole finding was that Foundation puts more in `userInfo` than the code
//  logging it expects, so a fixture that only contains what the test author
//  thought of would pass on the bug.
//

import XCTest
@testable import Muse

final class ErrorRedactionTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-redaction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A distinctive name, so a leak is unambiguous rather than a judgement
    /// call about what counts as identifying.
    private static let secretName = "Holiday in Tuscany 2019.jpg"

    private func realMoveFailure() -> Error {
        let source = dir.appendingPathComponent(Self.secretName)
        FileManager.default.createFile(atPath: source.path, contents: Data("x".utf8))
        do {
            // Destination folder does not exist — a real, ordinary failure.
            try FileManager.default.moveItem(
                at: source, to: dir.appendingPathComponent("Missing/Private Album.jpg"))
            XCTFail("the move was supposed to fail")
        } catch {
            return error
        }
        return CocoaError(.fileNoSuchFile)
    }

    func testSummaryCarriesNoFileName() {
        let summary = ErrorRedaction.summary(of: realMoveFailure())
        XCTAssertFalse(summary.contains(Self.secretName), "the file's name reached the log")
        XCTAssertFalse(summary.contains("Private Album"), "the destination name reached the log")
        XCTAssertFalse(summary.contains(dir.path), "the containing folder reached the log")
        XCTAssertFalse(summary.contains("/"), "no path component of any kind belongs in a log line")
    }

    /// The counterpart: this is what the three NSLog sites used to pass, and it
    /// fails the same assertions. Without this the test above proves only that
    /// SOME string is clean, not that the redaction is doing the work.
    func testTheUnredactedFormDoesLeak() {
        let raw = String(describing: realMoveFailure())
        XCTAssertTrue(raw.contains(Self.secretName),
                      "if Foundation ever stops naming the file here, the finding is moot "
                      + "and this test should be revisited rather than deleted")
    }

    func testSummaryKeepsWhatMakesAReportActionable() {
        let summary = ErrorRedaction.summary(of: realMoveFailure())
        XCTAssertTrue(summary.contains("NSCocoaErrorDomain"))
        XCTAssertTrue(summary.contains("NSPOSIXErrorDomain"),
                      "the underlying code is how disk-full is told from permission-denied")
    }

    func testAPlainErrorWithNoUnderlyingCauseStillSummarizes() {
        let summary = ErrorRedaction.summary(of: CocoaError(.fileWriteOutOfSpace))
        XCTAssertEqual(summary, "NSCocoaErrorDomain(640)")
    }
}
