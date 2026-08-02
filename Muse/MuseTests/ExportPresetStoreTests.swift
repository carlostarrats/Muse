//
//  ExportPresetStoreTests.swift
//  MuseTests
//
//  Saved export settings. The last test is the one that matters: a corrupt
//  defaults blob must degrade to an empty list rather than throwing, because
//  losing your shortcuts is recoverable and being unable to export is not.
//

import XCTest
@testable import Muse

@MainActor
final class ExportPresetStoreTests: XCTestCase {
    private let key = "exportPresets"

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: key)
        ExportPresetStore.shared.reload()
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: key)
        ExportPresetStore.shared.reload()
    }

    func testStartsEmpty() {
        XCTAssertTrue(ExportPresetStore.shared.presets.isEmpty)
    }

    func testSaveThenReloadRoundTrips() {
        let settings = ExportSettings(format: .tiff, quality: 0.5, tiff16: true,
                                      resize: .longEdge(2048),
                                      includeEXIF: true, includeLocation: true)
        ExportPresetStore.shared.save(name: "Archive", settings: settings)
        // Reload from defaults, so this proves persistence and not just memory.
        ExportPresetStore.shared.reload()
        XCTAssertEqual(ExportPresetStore.shared.presets.count, 1)
        XCTAssertEqual(ExportPresetStore.shared.presets[0].name, "Archive")
        XCTAssertEqual(ExportPresetStore.shared.presets[0].settings, settings)
    }

    func testEveryResizeModeSurvivesTheRoundTrip() {
        for resize: ExportResize in [.original, .longEdge(1024), .fitWithin(width: 640, height: 480)] {
            UserDefaults.standard.removeObject(forKey: key)
            ExportPresetStore.shared.reload()
            ExportPresetStore.shared.save(name: "r", settings: ExportSettings(resize: resize))
            ExportPresetStore.shared.reload()
            XCTAssertEqual(ExportPresetStore.shared.presets.first?.settings.resize, resize)
        }
    }

    func testSavingTheSameNameTwiceKeepsBothWithDistinctIDs() {
        ExportPresetStore.shared.save(name: "Web", settings: ExportSettings())
        ExportPresetStore.shared.save(name: "Web", settings: ExportSettings(format: .png))
        XCTAssertEqual(ExportPresetStore.shared.presets.count, 2)
        XCTAssertNotEqual(ExportPresetStore.shared.presets[0].id,
                          ExportPresetStore.shared.presets[1].id)
    }

    func testDeleteRemovesOnlyThatPreset() {
        ExportPresetStore.shared.save(name: "A", settings: ExportSettings())
        ExportPresetStore.shared.save(name: "B", settings: ExportSettings(format: .png))
        let target = try? XCTUnwrap(ExportPresetStore.shared.presets.first { $0.name == "A" }?.id)
        ExportPresetStore.shared.delete(id: try! XCTUnwrap(target))
        XCTAssertEqual(ExportPresetStore.shared.presets.map(\.name), ["B"])
    }

    func testDeletingAnUnknownIDIsANoOp() {
        ExportPresetStore.shared.save(name: "A", settings: ExportSettings())
        ExportPresetStore.shared.delete(id: UUID())
        XCTAssertEqual(ExportPresetStore.shared.presets.count, 1)
    }

    func testRename() {
        ExportPresetStore.shared.save(name: "Old", settings: ExportSettings())
        let id = ExportPresetStore.shared.presets[0].id
        ExportPresetStore.shared.rename(id: id, to: "New")
        XCTAssertEqual(ExportPresetStore.shared.presets[0].name, "New")
        ExportPresetStore.shared.reload()
        XCTAssertEqual(ExportPresetStore.shared.presets[0].name, "New")
    }

    func testPresetsAreSortedCaseInsensitively() {
        ExportPresetStore.shared.save(name: "zeta", settings: ExportSettings())
        ExportPresetStore.shared.save(name: "Alpha", settings: ExportSettings())
        ExportPresetStore.shared.save(name: "middle", settings: ExportSettings())
        XCTAssertEqual(ExportPresetStore.shared.presets.map(\.name), ["Alpha", "middle", "zeta"])
    }

    /// Someone whose presets can't decode should still be able to export.
    func testCorruptBlobDegradesToEmpty() {
        UserDefaults.standard.set(Data("not json at all".utf8), forKey: key)
        ExportPresetStore.shared.reload()
        XCTAssertTrue(ExportPresetStore.shared.presets.isEmpty)
    }

    /// And a corrupt blob must not block the next save from working.
    func testSaveRecoversFromACorruptBlob() {
        UserDefaults.standard.set(Data("garbage".utf8), forKey: key)
        ExportPresetStore.shared.reload()
        ExportPresetStore.shared.save(name: "Fresh", settings: ExportSettings())
        ExportPresetStore.shared.reload()
        XCTAssertEqual(ExportPresetStore.shared.presets.map(\.name), ["Fresh"])
    }
}
