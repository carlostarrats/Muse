import XCTest
@testable import Muse

final class VocabularyLocalizerTests: XCTestCase {
    private let loc = VocabularyLocalizer(forward: ["beach": "plage", "dog": "chien"])

    // MARK: - forward (display)

    func testForwardDisplaysLocalizedTerm() {
        XCTAssertEqual(loc.display("beach"), "plage")
    }
    func testForwardIsCaseInsensitiveOnCanonical() {
        XCTAssertEqual(loc.display("Beach"), "plage")
    }
    func testUnknownTermPassesThroughUnchanged() {
        XCTAssertEqual(loc.display("Q3 Budget"), "Q3 Budget")
    }
    func testIdentityLocalizerReturnsEnglish() {
        XCTAssertEqual(VocabularyLocalizer.identity.display("beach"), "beach")
    }

    // MARK: - reverse (canonicalize)

    func testReverseMapsLocalizedToCanonical() {
        XCTAssertEqual(loc.canonicalize("plage"), "beach")
    }
    func testReverseIsCaseInsensitive() {
        XCTAssertEqual(loc.canonicalize("PLAGE"), "beach")
    }
    func testReverseUnknownReturnsNil() {
        XCTAssertNil(loc.canonicalize("foobar"))
    }

    // MARK: - table:language: initializer (Task 3 loader shape)

    func testForwardForLanguageBuildsFromNestedTable() {
        let all = ["beach": ["fr": "plage"], "dog": ["fr": "chien", "es": "perro"]]
        let loc = VocabularyLocalizer(table: all, language: "fr")
        XCTAssertEqual(loc.display("beach"), "plage")
        XCTAssertEqual(loc.display("dog"), "chien")
        XCTAssertEqual(loc.canonicalize("plage"), "beach")
    }
    func testEnglishLanguageIsIdentity() {
        let all = ["beach": ["fr": "plage"]]
        let loc = VocabularyLocalizer(table: all, language: "en")
        XCTAssertEqual(loc.display("beach"), "beach")
    }
}
