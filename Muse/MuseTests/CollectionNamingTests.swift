import XCTest
@testable import Muse

final class CollectionNamingTests: XCTestCase {
    func testFallbackUsesTopTag() async {
        let n = TagFallbackNamer()
        let name = await n.name(tagsByFrequency: ["dog", "grass", "animal"])
        XCTAssertEqual(name, "Dog")
    }
    func testFallbackEmpty() async {
        let n = TagFallbackNamer()
        let name = await n.name(tagsByFrequency: [])
        XCTAssertEqual(name, "Collection")
    }
}
