import XCTest
@testable import Muse

final class TagFallbackNamerLocalizationTests: XCTestCase {
    func testFallbackNameIsLocalizedAndCapitalized() async {
        let namer = TagFallbackNamer(localizer: VocabularyLocalizer(forward: ["beach": "plage"]))
        let name = await namer.name(tagsByFrequency: ["beach", "sand"])
        XCTAssertEqual(name, "Plage")
    }
    func testFallbackUnknownTagPassesThrough() async {
        let namer = TagFallbackNamer(localizer: .identity)
        let name = await namer.name(tagsByFrequency: ["budget"])
        XCTAssertEqual(name, "Budget")
    }
    func testFallbackEmptyTagsReturnsCollection() async {
        let namer = TagFallbackNamer(localizer: .identity)
        let name = await namer.name(tagsByFrequency: [])
        XCTAssertEqual(name, "Collection")
    }
}
