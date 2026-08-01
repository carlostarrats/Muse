import XCTest
import CoreGraphics
@testable import Muse

// MARK: - ImportReport

final class ImportReportTests: XCTestCase {
    func testDefaultsAreZero() {
        let r = ImportReport(sourceName: "Lightroom")
        XCTAssertEqual(r.filesImported, 0)
        XCTAssertEqual(r.filesTouched, 0)
        XCTAssertEqual(r.keywords, 0)
        XCTAssertTrue(r.labelCounts.isEmpty)
        XCTAssertTrue(r.unsupportedSliders.isEmpty)
        XCTAssertTrue(r.notices.isEmpty)
    }

    func testAccumulationIsPlainAddition() {
        var r = ImportReport(sourceName: "Lightroom")
        r.keywords += 5
        r.keywords += 3
        r.unsupportedSliders["Clarity", default: 0] += 1
        r.unsupportedSliders["Clarity", default: 0] += 1
        XCTAssertEqual(r.keywords, 8)
        XCTAssertEqual(r.unsupportedSliders["Clarity"], 2)
    }

    func testIdentityIsPerInstance() {
        XCTAssertNotEqual(ImportReport(sourceName: "Eagle").id,
                          ImportReport(sourceName: "Eagle").id)
    }
}

// MARK: - XMPGPS

final class XMPGPSTests: XCTestCase {
    func testDecimalMinutesFormatNorth() {
        XCTAssertEqual(XMPGPS.parse("47,20.516N")!, 47.34193333, accuracy: 1e-5)
    }

    func testSouthAndWestAreNegative() {
        XCTAssertLessThan(XMPGPS.parse("47,20.516S")!, 0)
        XCTAssertLessThan(XMPGPS.parse("122,25.100W")!, 0)
    }

    func testDegreesMinutesSecondsFormat() {
        XCTAssertEqual(XMPGPS.parse("47,20,31.0N")!, 47.34194, accuracy: 1e-4)
    }

    func testMalformedStringReturnsNil() {
        XCTAssertNil(XMPGPS.parse("not-a-coordinate"))
        XCTAssertNil(XMPGPS.parse(nil))
        XCTAssertNil(XMPGPS.parse("47,20.516"))     // missing hemisphere
        XCTAssertNil(XMPGPS.parse("47.20.516N"))    // wrong separator
        XCTAssertNil(XMPGPS.parse("nan,00.000N"))
    }

    func testCoordinateRequiresBothAxes() {
        XCTAssertNil(XMPGPS.coordinate(lat: "47,20.516N", lon: nil))
        XCTAssertNil(XMPGPS.coordinate(lat: nil, lon: "122,25.100W"))
        XCTAssertNotNil(XMPGPS.coordinate(lat: "47,20.516N", lon: "122,25.100W"))
    }

    /// The per-AXIS bound: 95° is a legal longitude and an illegal latitude, so
    /// only `coordinate` — which knows which axis it holds — can reject it.
    func testOutOfRangeRejectedPerAxis() {
        XCTAssertNil(XMPGPS.parse("185,00.000E"))
        XCTAssertNil(XMPGPS.coordinate(lat: "95,00.000N", lon: "10,00.000E"))
        XCTAssertNotNil(XMPGPS.coordinate(lat: "10,00.000N", lon: "95,00.000E"))
    }
}

// MARK: - ImportedText

final class ImportedTextTests: XCTestCase {
    func testAllNilReturnsNil() {
        XCTAssertNil(ImportedText.note(title: nil, caption: nil, creator: nil))
    }

    func testAllEmptyStringsReturnNil() {
        XCTAssertNil(ImportedText.note(title: "", caption: "  ", creator: nil))
    }

    func testJoinOrderIsTitleCaptionCreator() {
        XCTAssertEqual(
            ImportedText.note(title: "Sunset", caption: "Over the bay", creator: "Ana"),
            "Sunset\nOver the bay\n© Ana")
    }

    func testCreatorIsPrefixed() {
        XCTAssertEqual(ImportedText.note(title: nil, caption: nil, creator: "Ana"), "© Ana")
    }

    func testCaseInsensitiveDuplicateIsDropped() {
        XCTAssertEqual(ImportedText.note(title: "Sunset", caption: "sunset", creator: nil),
                       "Sunset")
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(ImportedText.note(title: "  Sunset  ", caption: nil, creator: nil),
                       "Sunset")
    }

    func testLengthIsCapped() {
        let huge = String(repeating: "x", count: 5_000)
        XCTAssertEqual(ImportedText.note(title: huge, caption: nil, creator: nil)?.count,
                       ImportedText.maxLength)
    }
}

// MARK: - Labels

final class LabelTagTests: XCTestCase {
    func testIsLabelDetectsPrefix() {
        XCTAssertTrue(LabelTag.isLabel("Label: Red"))
        XCTAssertFalse(LabelTag.isLabel("Red"))
        XCTAssertFalse(LabelTag.isLabel("sunset"))
    }

    func testMakePrefixesAndTrims() {
        XCTAssertEqual(LabelTag.make("  Red  "), "Label: Red")
    }

    func testQueryTargetsLabelsIsCaseInsensitiveSubstring() {
        XCTAssertTrue(LabelTag.queryTargetsLabels("label: red"))
        XCTAssertTrue(LabelTag.queryTargetsLabels("LABEL"))
        XCTAssertFalse(LabelTag.queryTargetsLabels("red"))
    }
}

final class LabelMappingTests: XCTestCase {
    func testSkipResolvesToNil() {
        XCTAssertNil(LabelMapping.resolvedLabel(value: "Red", choice: .skip))
    }

    func testNamespacedResolvesToPrefixedTag() {
        XCTAssertEqual(LabelMapping.resolvedLabel(value: "Red", choice: .namespaced),
                       "Label: Red")
    }

    func testTagChoiceResolvesToTheChosenLabel() {
        XCTAssertEqual(LabelMapping.resolvedLabel(value: "Red", choice: .tag("portfolio")),
                       "portfolio")
    }

    /// A ★-run target would attach a SECOND rating tag and break
    /// `StarRating.resolution`; the refusal lives in the mapper, not in callers.
    func testTagChoiceRefusesARatingGlyphRun() {
        XCTAssertNil(LabelMapping.resolvedLabel(value: "Red", choice: .tag("★★★")))
    }

    func testChoicesRoundTripThroughPersistence() {
        let key = AppSettings.importLabelChoicesKey
        let saved = UserDefaults.standard.data(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let choices: [String: LabelMapping.Choice] = ["Red": .namespaced,
                                                      "Rouge": .tag("portfolio")]
        LabelMapping.saveChoices(choices)
        XCTAssertEqual(LabelMapping.loadChoices(), choices)
    }

    func testSaveMergesRatherThanReplaces() {
        let key = AppSettings.importLabelChoicesKey
        let saved = UserDefaults.standard.data(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        LabelMapping.saveChoices(["Red": .namespaced])
        LabelMapping.saveChoices(["Blue": .skip])
        XCTAssertEqual(LabelMapping.loadChoices().count, 2)
    }
}

// MARK: - Throttle / estimator

final class ThrottlePolicyTests: XCTestCase {
    func testUserPausedAlwaysWins() {
        XCTAssertEqual(ThrottlePolicy.mode(thermal: .nominal, onBattery: false,
                                           lowPower: false, userPaused: true), .paused)
    }

    func testSeriousAndCriticalThermalPause() {
        XCTAssertEqual(ThrottlePolicy.mode(thermal: .serious, onBattery: false,
                                           lowPower: false, userPaused: false), .paused)
        XCTAssertEqual(ThrottlePolicy.mode(thermal: .critical, onBattery: false,
                                           lowPower: false, userPaused: false), .paused)
    }

    func testFairThermalDoesNotPauseAlone() {
        XCTAssertNotEqual(ThrottlePolicy.mode(thermal: .fair, onBattery: false,
                                              lowPower: false, userPaused: false), .paused)
    }

    func testBatteryAndLowPowerReduce() {
        XCTAssertEqual(ThrottlePolicy.mode(thermal: .nominal, onBattery: true,
                                           lowPower: false, userPaused: false), .reduced)
        XCTAssertEqual(ThrottlePolicy.mode(thermal: .nominal, onBattery: false,
                                           lowPower: true, userPaused: false), .reduced)
    }

    func testNominalIsNormal() {
        XCTAssertEqual(ThrottlePolicy.mode(thermal: .nominal, onBattery: false,
                                           lowPower: false, userPaused: false), .normal)
    }

    func testConcurrencyTable() {
        XCTAssertEqual(ThrottlePolicy.concurrency(.normal), AnalyzePipeline.analyzeConcurrency)
        XCTAssertEqual(ThrottlePolicy.concurrency(.reduced), 1)
        XCTAssertEqual(ThrottlePolicy.concurrency(.paused), 0)
    }

    /// A backfill with its own full-speed width narrows under the same rules —
    /// it must not stay 2- or 4-wide on battery while analysis is down to 1.
    func testScaledKeepsTheCallersWidthOnlyWhenNormal() {
        XCTAssertEqual(ThrottlePolicy.scaled(.normal, normal: 4), 4)
        XCTAssertEqual(ThrottlePolicy.scaled(.reduced, normal: 4), 1)
        XCTAssertEqual(ThrottlePolicy.scaled(.paused, normal: 4), 0)
        XCTAssertEqual(ThrottlePolicy.scaled(.normal, normal: 2), 2)
        XCTAssertEqual(ThrottlePolicy.scaled(.reduced, normal: 2), 1)
    }
}

/// Single-flight with one trailing re-run — the launch chain, imports and the
/// CLIP model install all reach the same passes.
final class BackfillCoordinatorTests: XCTestCase {

    func testSecondCallerDoesNotStartASecondPass() async {
        let coordinator = BackfillCoordinator()
        let counter = Counter()

        let first = Task {
            await coordinator.run("k") {
                await counter.bump()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        // Let the first pass get inside the gate.
        try? await Task.sleep(nanoseconds: 80_000_000)

        // Arrives mid-pass: must not run concurrently, must not block.
        await coordinator.run("k") { await counter.bump() }
        let midCount = await counter.value
        XCTAssertEqual(midCount, 1)

        await first.value
        // …but it IS guaranteed a pass that starts after it asked.
        let finalCount = await counter.value
        XCTAssertEqual(finalCount, 2)
    }

    func testDistinctKeysDoNotBlockEachOther() async {
        let coordinator = BackfillCoordinator()
        let counter = Counter()
        await coordinator.run("a") { await counter.bump() }
        await coordinator.run("b") { await counter.bump() }
        let count = await counter.value
        XCTAssertEqual(count, 2)
    }

    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }
}

final class AnalysisEstimatorTests: XCTestCase {
    func testEstimateIsNilBeforeCalibration() {
        XCTAssertNil(AnalysisEstimator.estimate(pending: 1000, secondsPerFile: 2.0,
                                                completions: 50))
    }

    func testEstimateIsNilWithoutASample() {
        XCTAssertNil(AnalysisEstimator.estimate(pending: 1000, secondsPerFile: nil,
                                                completions: 500))
    }

    func testEstimateExtrapolatesLinearly() {
        XCTAssertEqual(AnalysisEstimator.estimate(pending: 1000, secondsPerFile: 2.0,
                                                  completions: 500), 2000)
    }

    func testShouldOfferBoundaryIsStrictlyGreaterThan() {
        XCTAssertFalse(AnalysisEstimator.shouldOffer(estimate: nil))
        XCTAssertFalse(AnalysisEstimator.shouldOffer(estimate: 60))
        XCTAssertFalse(AnalysisEstimator.shouldOffer(
            estimate: AnalysisEstimator.fyiThresholdSeconds))
        XCTAssertTrue(AnalysisEstimator.shouldOffer(
            estimate: AnalysisEstimator.fyiThresholdSeconds + 1))
    }
}

// MARK: - Takeout

final class TakeoutJSONTests: XCTestCase {
    func testCandidateRule1CurrentTakeoutFormat() {
        XCTAssertEqual(TakeoutJSON.jsonCandidates(for: "IMG_0001.jpg").first,
                       "IMG_0001.jpg.supplemental-metadata.json")
    }

    func testCandidateRule2OlderTakeoutFormat() {
        XCTAssertTrue(TakeoutJSON.jsonCandidates(for: "IMG_0001.jpg")
            .contains("IMG_0001.jpg.json"))
    }

    func testCandidateRule3DuplicateCounterSwap() {
        XCTAssertTrue(TakeoutJSON.jsonCandidates(for: "IMG(1).jpg")
            .contains("IMG.jpg(1).json"))
    }

    func testCandidateRule4EditedSuffixStrip() {
        XCTAssertTrue(TakeoutJSON.jsonCandidates(for: "IMG_0001-edited.jpg")
            .contains { $0.hasPrefix("IMG_0001.jpg") })
    }

    func testCandidateRule4LocalizedEditedSuffixVariants() {
        XCTAssertTrue(TakeoutJSON.jsonCandidates(for: "IMG_0001-bearbeitet.jpg")
            .contains { $0.hasPrefix("IMG_0001.jpg") })
        XCTAssertTrue(TakeoutJSON.jsonCandidates(for: "IMG_0001-modifié.jpg")
            .contains { $0.hasPrefix("IMG_0001.jpg") })
    }

    func testCandidateRule5TruncationReDerive() {
        let longName = String(repeating: "a", count: 60) + ".jpg"
        let candidates = TakeoutJSON.jsonCandidates(for: longName)
        let truncated = String(longName.prefix(TakeoutJSON.truncationLimit))
        XCTAssertTrue(candidates.contains(truncated + ".json"))
    }

    func testParsePhotoTakenTimeIsStringEpoch() {
        let json = #"{"photoTakenTime":{"timestamp":"1609459200"}}"#.data(using: .utf8)!
        XCTAssertEqual(TakeoutJSON.parse(json)?.photoTakenTime, 1_609_459_200)
    }

    func testParseGeoDataFallsBackToGeoDataExif() {
        let json = #"{"geoData":{"latitude":0,"longitude":0},"geoDataExif":{"latitude":47.5,"longitude":-122.3}}"#
            .data(using: .utf8)!
        let meta = TakeoutJSON.parse(json)
        XCTAssertEqual(meta?.lat, 47.5)
        XCTAssertEqual(meta?.lon, -122.3)
    }

    func testZeroZeroGeoDataIsAbsent() {
        let json = #"{"geoData":{"latitude":0,"longitude":0}}"#.data(using: .utf8)!
        XCTAssertNil(TakeoutJSON.parse(json)?.lat)
    }

    func testFavoritedPeopleDescription() {
        let json = #"{"description":"  A sunset  ","favorited":true,"people":[{"name":"Ana"},{"name":"Ben"}]}"#
            .data(using: .utf8)!
        let meta = TakeoutJSON.parse(json)
        XCTAssertEqual(meta?.description, "A sunset")
        XCTAssertTrue(meta?.favorited ?? false)
        XCTAssertEqual(meta?.people, ["Ana", "Ben"])
    }

    func testEmptyDescriptionBecomesNil() {
        XCTAssertNil(TakeoutJSON.parse(#"{"description":"   "}"#.data(using: .utf8)!)?.description)
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(TakeoutJSON.parse("not json".data(using: .utf8)!))
    }
}

// MARK: - Collision naming

final class ImportCollisionNamingTests: XCTestCase {
    func testApplePhotosLadderAppendsNumericSuffix() {
        XCTAssertEqual(
            ApplePhotosImportModel.collisionName(base: "IMG_0001", ext: "jpg",
                                                 existing: ["IMG_0001.jpg"]),
            "IMG_0001 2.jpg")
    }

    func testApplePhotosLadderIsCaseInsensitive() {
        XCTAssertEqual(
            ApplePhotosImportModel.collisionName(base: "IMG_0001", ext: "JPG",
                                                 existing: ["img_0001.jpg"]),
            "IMG_0001 2.JPG")
    }

    func testEagleLadderAppendsNumericSuffix() {
        XCTAssertEqual(EagleImportModel.uniqueName("photo.jpg", used: ["photo.jpg"]),
                       "photo 2.jpg")
        XCTAssertEqual(EagleImportModel.uniqueName("photo.jpg", used: []), "photo.jpg")
    }

    func testPresetNameLadder() {
        XCTAssertEqual(EditPresetStore.uniqueName("Moody", existing: []), "Moody")
        XCTAssertEqual(EditPresetStore.uniqueName("Moody", existing: ["moody"]), "Moody 2")
        XCTAssertEqual(EditPresetStore.uniqueName("Moody", existing: ["moody", "moody 2"]),
                       "Moody 3")
    }
}

// MARK: - Eagle folder flattening

final class EagleLibraryTests: XCTestCase {
    func testFlattenedNamesJoinsNestedFolders() {
        let folders = [
            EagleFolder(id: "p", name: "Parent", childIDs: ["c"]),
            EagleFolder(id: "c", name: "Child", childIDs: []),
        ]
        let flat = EagleLibrary.flattenedNames(folders)
        XCTAssertEqual(flat["c"], "Parent – Child")
        XCTAssertEqual(flat["p"], "Parent")
    }

    func testMissingParentStopsTheWalk() {
        let folders = [EagleFolder(id: "orphan", name: "Orphan", childIDs: [])]
        XCTAssertEqual(EagleLibrary.flattenedNames(folders)["orphan"], "Orphan")
    }

    /// A hand-built library on disk: the reader is tolerant per item, so the
    /// deliberately corrupt one is skipped rather than failing the whole read.
    func testReadSkipsCorruptItemsWithoutThrowing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eagle-\(UUID().uuidString).library")
        let images = root.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try #"{"folders":[{"id":"p","name":"Parent","children":[{"id":"c","name":"Child","children":[]}]}]}"#
            .write(to: root.appendingPathComponent("metadata.json"),
                   atomically: true, encoding: .utf8)

        let good = images.appendingPathComponent("good.info")
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try #"{"id":"good","name":"shot","ext":"jpg","tags":["beach"],"star":4,"annotation":"note","folders":["c"]}"#
            .write(to: good.appendingPathComponent("metadata.json"),
                   atomically: true, encoding: .utf8)
        try Data([0xFF, 0xD8]).write(to: good.appendingPathComponent("shot.jpg"))

        let bad = images.appendingPathComponent("bad.info")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try "{ not json".write(to: bad.appendingPathComponent("metadata.json"),
                               atomically: true, encoding: .utf8)

        let (items, folders) = try EagleLibrary.read(at: root)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.tags, ["beach"])
        XCTAssertEqual(items.first?.star, 4)
        XCTAssertEqual(items.first?.annotation, "note")
        XCTAssertEqual(items.first?.folderIDs, ["c"])
        XCTAssertEqual(folders.count, 2)
    }
}

// MARK: - Bounded metadata reads

/// The import-side twin of the decode budget: a sidecar is user input, and
/// `Data(contentsOf:)` on a huge one would be read into RAM in full.
final class BoundedReadTests: XCTestCase {

    private func writeTemp(_ bytes: Int, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-\(name)-\(UUID().uuidString).xmp")
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    func testReadsASmallFile() throws {
        let url = try writeTemp(1024, name: "small")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(BoundedRead.metadata(at: url)?.count, 1024)
    }

    func testSkipsAFileOverTheLimit() throws {
        let url = try writeTemp(4096, name: "big")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(BoundedRead.metadata(at: url, limit: 1024))
    }

    func testAcceptsExactlyTheLimit() throws {
        let url = try writeTemp(1024, name: "exact")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNotNil(BoundedRead.metadata(at: url, limit: 1024))
    }

    func testSkipsAnEmptyOrMissingFile() throws {
        let empty = try writeTemp(0, name: "empty")
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertNil(BoundedRead.metadata(at: empty))
        XCTAssertNil(BoundedRead.metadata(
            at: URL(fileURLWithPath: "/tmp/definitely-not-there-\(UUID().uuidString).xmp")))
    }
}
