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

    /// Pale warm tones — skin, peach, salmon — must NOT be called "red".
    /// These drove false "red" tags on portraits and product shots: a light,
    /// low-saturation warm color is perceptually pink/peach, not red.
    func testPaleWarmTonesAreNotRed() {
        // Salmon / peachy skin tones seen in the library's red-tagged files.
        XCTAssertNotEqual(NamedColor.name(forHex: "#eb9d95"), "red")
        XCTAssertNotEqual(NamedColor.name(forHex: "#ec988b"), "red")
        XCTAssertNotEqual(NamedColor.name(forHex: "#e78a79"), "red")
        XCTAssertNotEqual(NamedColor.name(forHex: "#f3cdc6"), "red")
    }

    /// Saturated / deep reds must STILL be red.
    func testTrueRedsStayRed() {
        XCTAssertEqual(NamedColor.name(forHex: "#ff0000"), "red")
        XCTAssertEqual(NamedColor.name(forHex: "#f1251d"), "red")
        XCTAssertEqual(NamedColor.name(forHex: "#d81f2b"), "red")
        XCTAssertEqual(NamedColor.name(forHex: "#821210"), "red") // deep maroon-red
        XCTAssertEqual(NamedColor.name(forHex: "#660000"), "red") // dark but saturated
    }

    /// Muted, low-saturation warm tones read as brown/neutral — not red.
    func testMuddyWarmTonesAreNotRed() {
        XCTAssertNotEqual(NamedColor.name(forHex: "#615654"), "red") // warm-gray
        XCTAssertNotEqual(NamedColor.name(forHex: "#4b2e2a"), "red") // dark taupe
        XCTAssertNotEqual(NamedColor.name(forHex: "#947671"), "red") // mid mauve-taupe
        XCTAssertNotEqual(NamedColor.name(forHex: "#a76772"), "red") // dusty mauve
    }

    /// Near-black charcoals have a hue mathematically, but it's channel noise —
    /// they must read black, NOT blue/purple/etc. (the systemic bug beyond red).
    func testDarkNeutralsAreNotHues() {
        XCTAssertEqual(NamedColor.name(forHex: "#202226"), "black") // was "blue"
        XCTAssertEqual(NamedColor.name(forHex: "#1e2026"), "black") // was "blue"
        XCTAssertEqual(NamedColor.name(forHex: "#282429"), "black") // was "purple"
        XCTAssertEqual(NamedColor.name(forHex: "#141519"), "black")
    }

    /// Dark but genuinely saturated colors keep their hue (navy, deep green).
    func testDarkSaturatedKeepsHue() {
        XCTAssertEqual(NamedColor.name(forHex: "#001a40"), "blue")  // navy
        XCTAssertEqual(NamedColor.name(forHex: "#06320a"), "green") // deep green
    }

    /// Light, low-saturation tints read white/gray, not a hue.
    func testLightNeutrals() {
        XCTAssertEqual(NamedColor.name(forHex: "#f4f4f8"), "white") // faint blue tint
        XCTAssertEqual(NamedColor.name(forHex: "#e6e6e6"), "white")
    }
}
