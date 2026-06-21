import XCTest
@testable import Muse

final class FileMetadataTests: XCTestCase {

    // MARK: formatTakenDate
    func testTakenDateParsesExifFormat() {
        // EXIF DateTimeOriginal is "yyyy:MM:dd HH:mm:ss".
        let s = FileMetadata.formatTakenDate("2026:06:14 15:42:31")
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("2026"), "expected year in \(s!)")
    }
    func testTakenDateNilOnGarbageOrNil() {
        XCTAssertNil(FileMetadata.formatTakenDate(nil))
        XCTAssertNil(FileMetadata.formatTakenDate("not a date"))
    }

    // MARK: formatExposure
    func testExposureFullTriple() {
        let s = FileMetadata.formatExposure(fNumber: 1.8, exposureTime: 1.0/120.0, iso: 64)
        XCTAssertEqual(s, "ƒ1.8 · 1/120 · ISO 64")
    }
    func testExposurePartial() {
        let s = FileMetadata.formatExposure(fNumber: 2.8, exposureTime: nil, iso: nil)
        XCTAssertEqual(s, "ƒ2.8")
    }
    func testExposureNilWhenEmpty() {
        XCTAssertNil(FileMetadata.formatExposure(fNumber: nil, exposureTime: nil, iso: nil))
    }
    func testExposureLongShutterShownAsSeconds() {
        // 0.5s is shown as "1/2" (reciprocal) — sub-second is the common case.
        let s = FileMetadata.formatExposure(fNumber: nil, exposureTime: 0.5, iso: nil)
        XCTAssertEqual(s, "1/2")
    }

    // MARK: coordinate (with hemisphere refs)
    func testCoordinateAppliesSouthWestSigns() {
        let c = FileMetadata.coordinate(latitude: 37.77, latRef: "S",
                                        longitude: 122.41, longRef: "W")
        XCTAssertEqual(c?.lat ?? 0, -37.77, accuracy: 0.001)
        XCTAssertEqual(c?.long ?? 0, -122.41, accuracy: 0.001)
    }
    func testCoordinateNilWhenMissing() {
        XCTAssertNil(FileMetadata.coordinate(latitude: nil, latRef: "N",
                                             longitude: 1.0, longRef: "E"))
    }

    // MARK: imageMetadata (assembly)
    func testImageMetadataBuildsRowsAndCoordinate() {
        let exif: [String: Any] = [
            "DateTimeOriginal": "2026:06:14 15:42:31",
            "FNumber": 1.8,
            "ExposureTime": 1.0/120.0,
            "ISOSpeedRatings": [64],
            "LensModel": "iPhone 15 Pro back camera 6.86mm f/1.78",
        ]
        let tiff: [String: Any] = ["Make": "Apple", "Model": "iPhone 15 Pro"]
        let gps: [String: Any] = [
            "Latitude": 37.77, "LatitudeRef": "N",
            "Longitude": 122.41, "LongitudeRef": "W",
        ]
        let m = FileMetadata.imageMetadata(exif: exif, tiff: tiff, gps: gps)
        let labels = m.rows.map(\.label)
        XCTAssertEqual(labels, ["Taken", "Camera", "Lens", "Exposure", "Location"])
        XCTAssertEqual(m.rows.first(where: { $0.label == "Camera" })?.value, "Apple iPhone 15 Pro")
        XCTAssertEqual(m.rows.first(where: { $0.label == "Exposure" })?.value, "ƒ1.8 · 1/120 · ISO 64")
        XCTAssertNotNil(m.coordinate)
        XCTAssertEqual(m.coordinate?.long ?? 0, -122.41, accuracy: 0.001)
    }
    func testImageMetadataEmptyDictsYieldEmpty() {
        let m = FileMetadata.imageMetadata(exif: [:], tiff: [:], gps: [:])
        XCTAssertTrue(m.rows.isEmpty)
        XCTAssertNil(m.coordinate)
        XCTAssertEqual(m, FileMetadata.empty)
    }

    // MARK: pdfMetadata
    func testPDFMetadataRowsInOrder() {
        let attrs: [String: Any] = [
            "Title": "Quarterly Report",
            "Author": "Jane Doe",
            "Creator": "Pages",
        ]
        let m = FileMetadata.pdfMetadata(pageCount: 12, attributes: attrs)
        XCTAssertEqual(m.rows.map(\.label), ["Pages", "Title", "Author", "Creator"])
        XCTAssertEqual(m.rows.first?.value, "12")
        XCTAssertNil(m.coordinate)
    }
    func testPDFMetadataPagesOnlyWhenNoAttrs() {
        let m = FileMetadata.pdfMetadata(pageCount: 3, attributes: [:])
        XCTAssertEqual(m.rows.map(\.label), ["Pages"])
    }
    func testPDFMetadataSkipsBlankAttrs() {
        let m = FileMetadata.pdfMetadata(pageCount: 1, attributes: ["Title": "", "Author": "  "])
        XCTAssertEqual(m.rows.map(\.label), ["Pages"])
    }

    // MARK: formatDuration / mediaMetadata
    func testDurationFormatsMinutesSeconds() {
        XCTAssertEqual(FileMetadata.formatDuration(222), "3:42")
        XCTAssertEqual(FileMetadata.formatDuration(5), "0:05")
    }
    func testDurationFormatsHours() {
        XCTAssertEqual(FileMetadata.formatDuration(3661), "1:01:01")
    }
    func testDurationNilOrZero() {
        XCTAssertNil(FileMetadata.formatDuration(nil))
        XCTAssertNil(FileMetadata.formatDuration(0))
    }
    func testMediaMetadataRow() {
        let m = FileMetadata.mediaMetadata(durationSeconds: 222)
        XCTAssertEqual(m.rows, [InfoRow("Duration", "3:42")])
    }
    func testMediaMetadataEmptyWhenNoDuration() {
        XCTAssertEqual(FileMetadata.mediaMetadata(durationSeconds: nil), FileMetadata.empty)
    }

    // MARK: formatModifiedDate
    func testFormatModifiedDateMediumNoTime() {
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 17
        let date = Calendar(identifier: .gregorian).date(from: c)!
        let s = FileMetadata.formatModifiedDate(date)
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("2026"), "expected year in \(s!)")
        // Date-only (timeStyle .none): no AM/PM time component.
        XCTAssertFalse(s!.contains("AM") || s!.contains("PM"), "expected no time in \(s!)")
    }
    func testFormatModifiedDateNil() {
        XCTAssertNil(FileMetadata.formatModifiedDate(nil))
    }

    // MARK: video metadata (feat/next-47)
    func testFrameRateRoundsNearInteger() {
        XCTAssertEqual(FileMetadata.formatFrameRate(30), "30 fps")
        XCTAssertEqual(FileMetadata.formatFrameRate(29.97), "30 fps")
    }
    func testFrameRateNilOrZero() {
        XCTAssertNil(FileMetadata.formatFrameRate(nil))
        XCTAssertNil(FileMetadata.formatFrameRate(0))
    }
    func testRecordedDateHasYear() {
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 1; c.hour = 14; c.minute = 30
        let date = Calendar(identifier: .gregorian).date(from: c)!
        let s = FileMetadata.formatRecordedDate(date)
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("2026"), "expected year in \(s!)")
    }
    func testRecordedDateNil() {
        XCTAssertNil(FileMetadata.formatRecordedDate(nil))
    }
    func testParseISO6709() {
        let c = FileMetadata.parseISO6709("+34.0522-118.2437+096.000/")
        XCTAssertEqual(c, Coordinate(lat: 34.0522, long: -118.2437))
    }
    func testParseISO6709Invalid() {
        XCTAssertNil(FileMetadata.parseISO6709("not a coordinate"))
        XCTAssertNil(FileMetadata.parseISO6709(nil))
    }
    func testVideoMetadataRowsOrder() {
        let m = FileMetadata.videoMetadata(durationSeconds: 222,
                                           dimensions: (width: 1080, height: 1920),
                                           frameRate: 30, recorded: nil, coordinate: nil)
        XCTAssertEqual(m.rows, [InfoRow("Dimensions", "1080 × 1920"),
                                InfoRow("Duration", "3:42"),
                                InfoRow("Frame Rate", "30 fps")])
        XCTAssertNil(m.coordinate)
    }
    func testVideoMetadataOmitsLocationRowButKeepsCoordinate() {
        // No "Location" text row — the coordinate drives the Open in Maps link.
        let coord = Coordinate(lat: 34.0522, long: -118.2437)
        let m = FileMetadata.videoMetadata(durationSeconds: nil, dimensions: nil,
                                           frameRate: nil, recorded: nil, coordinate: coord)
        XCTAssertTrue(m.rows.isEmpty, "expected no rows, got \(m.rows)")
        XCTAssertEqual(m.coordinate, coord)
    }
}
