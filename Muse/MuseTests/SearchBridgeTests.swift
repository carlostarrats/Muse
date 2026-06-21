import XCTest
@testable import Muse

final class SearchBridgeTests: XCTestCase {
    private func canon(_ t: String) -> String? {
        ["plage": "beach", "chien": "dog"][t.lowercased()]
    }

    func testRawQueryAlwaysIncluded() {
        XCTAssertEqual(SearchBridge.tagSearchTerms(for: "sunset", canonicalize: canon),
                       ["sunset"])
    }
    func testLocalizedQueryAddsCanonical() {
        XCTAssertEqual(SearchBridge.tagSearchTerms(for: "plage", canonicalize: canon),
                       ["plage", "beach"])
    }
    func testPerTokenCanonicalization() {
        XCTAssertEqual(SearchBridge.tagSearchTerms(for: "plage chien", canonicalize: canon),
                       ["plage chien", "beach", "dog"])
    }
    func testDeduplicatesAndPreservesOrder() {
        XCTAssertEqual(SearchBridge.tagSearchTerms(for: "plage plage", canonicalize: canon),
                       ["plage plage", "beach"])
    }
    func testNoCanonicalLeavesRawOnly() {
        XCTAssertEqual(SearchBridge.tagSearchTerms(for: "vacances", canonicalize: canon),
                       ["vacances"])
    }
}
