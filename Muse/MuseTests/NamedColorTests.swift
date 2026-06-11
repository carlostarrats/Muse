import XCTest
@testable import Muse

final class NamedColorTests: XCTestCase {
    func testPrimaryHues() {
        XCTAssertEqual(NamedColor.name(forHex: "#ff0000"), "red")
        XCTAssertEqual(NamedColor.name(forHex: "#00ff00"), "green")
        XCTAssertEqual(NamedColor.name(forHex: "#0000ff"), "blue")
        XCTAssertEqual(NamedColor.name(forHex: "#ffa500"), "orange")
        XCTAssertEqual(NamedColor.name(forHex: "#ffff00"), "yellow")
        XCTAssertEqual(NamedColor.name(forHex: "#800080"), "purple")
        XCTAssertEqual(NamedColor.name(forHex: "#ffc0cb"), "pink")
        XCTAssertEqual(NamedColor.name(forHex: "#008080"), "teal")
    }
    func testNeutrals() {
        XCTAssertEqual(NamedColor.name(forHex: "#000000"), "black")
        XCTAssertEqual(NamedColor.name(forHex: "#ffffff"), "white")
        XCTAssertEqual(NamedColor.name(forHex: "#808080"), "gray")
        XCTAssertEqual(NamedColor.name(forHex: "#8b5a2b"), "brown")
        XCTAssertEqual(NamedColor.name(forHex: "#e8d5c0"), "beige")
    }
    func testInvalidHexReturnsNil() {
        XCTAssertNil(NamedColor.name(forHex: "nope"))
        XCTAssertNil(NamedColor.name(forHex: ""))
    }
}
