import XCTest
@testable import Muse

final class ICloudSidebarVisibilityTests: XCTestCase {
    typealias V = ICloudSidebarVisibility

    func testPresenceMapping() {
        XCTAssertEqual(V.presence(configured: false, recursiveFileCount: nil), .notConfigured)
        XCTAssertEqual(V.presence(configured: false, recursiveFileCount: 5), .notConfigured) // not-configured wins
        XCTAssertEqual(V.presence(configured: true, recursiveFileCount: nil), .unknown)
        XCTAssertEqual(V.presence(configured: true, recursiveFileCount: 0), .empty)
        XCTAssertEqual(V.presence(configured: true, recursiveFileCount: 3), .hasFiles)
    }

    func testRowVisibility() {
        // Not configured: never shown, regardless of the toggle.
        XCTAssertFalse(V.rowVisible(.notConfigured, showSetting: true))
        XCTAssertFalse(V.rowVisible(.notConfigured, showSetting: false))
        // Has files: always shown, even with the toggle OFF.
        XCTAssertTrue(V.rowVisible(.hasFiles, showSetting: false))
        XCTAssertTrue(V.rowVisible(.hasFiles, showSetting: true))
        // Empty: follows the toggle.
        XCTAssertTrue(V.rowVisible(.empty, showSetting: true))
        XCTAssertFalse(V.rowVisible(.empty, showSetting: false))
        // Unknown (count not computed yet): shown, so it never flickers out at launch.
        XCTAssertTrue(V.rowVisible(.unknown, showSetting: false))
        XCTAssertTrue(V.rowVisible(.unknown, showSetting: true))
    }

    func testToggleDisabled() {
        XCTAssertTrue(V.toggleDisabled(.hasFiles))   // can't hide a folder with files
        XCTAssertFalse(V.toggleDisabled(.empty))
        XCTAssertFalse(V.toggleDisabled(.notConfigured))
        XCTAssertFalse(V.toggleDisabled(.unknown))
    }
}
