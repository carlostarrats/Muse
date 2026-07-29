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

    // MARK: - File facts (Size / Format / MP)

    func testMegapixels() {
        // A bare number — the row's label carries the "MP" unit.
        XCTAssertEqual(FileMetadata.formatMegapixels(width: 4032, height: 3024), "12")
        // Under 10 MP keeps a decimal — the tenths still separate 6.0 from 6.9.
        XCTAssertEqual(FileMetadata.formatMegapixels(width: 3000, height: 2000), "6.0")
    }
    func testMegapixelsNilForTinyOrDegenerate() {
        XCTAssertNil(FileMetadata.formatMegapixels(width: 200, height: 200))  // 0.04 MP
        XCTAssertNil(FileMetadata.formatMegapixels(width: 0, height: 1000))
        XCTAssertNil(FileMetadata.formatMegapixels(width: -4, height: -4))
    }
    func testMegapixelsDoesNotOverflow() {
        // A hostile/corrupt header can declare dimensions whose Int product traps.
        XCTAssertNotNil(FileMetadata.formatMegapixels(width: .max, height: .max))
    }
    func testFileSizeNilForMissingOrZero() {
        XCTAssertNil(FileMetadata.formatFileSize(nil))
        XCTAssertNil(FileMetadata.formatFileSize(0))
        XCTAssertNotNil(FileMetadata.formatFileSize(1_500_000))
    }
    func testSmallFileDoesNotReadZeroKB() {
        // Capped at KB and up, a 120-byte SVG formats as "0 KB".
        let s = FileMetadata.formatFileSize(120)
        XCTAssertNotNil(s)
        XCTAssertFalse(s?.hasPrefix("0") ?? true, "got \(s ?? "nil")")
    }
    func testFileKindFallsBackToExtension() {
        // No such type is registered, so the bare extension is the answer.
        XCTAssertEqual(FileMetadata.formatFileKind(extension: "zzqq"), "ZZQQ")
        XCTAssertNil(FileMetadata.formatFileKind(extension: ""))
        XCTAssertNil(FileMetadata.formatFileKind(extension: "   "))
    }
    func testFileKindUsesTheRegistryWhenKnown() {
        // Registered types get the system's human name, not the raw extension.
        XCTAssertNotEqual(FileMetadata.formatFileKind(extension: "jpg"), "JPG")
    }

    // MARK: - File-fact splicing

    private func labels(_ rows: [InfoRow]) -> [String] { rows.map(\.label) }

    func testFileFactsSitUnderTheCaptureDateAndAboveCameraRows() {
        let base = [InfoRow("Taken", "Jun 17, 2026"), InfoRow("Camera", "Leica M11")]
        let out = FileMetadata.withFileFacts(base, modified: Date(timeIntervalSince1970: 0),
                                             sizeBytes: 2_400_000, fileExtension: "jpg",
                                             dimensions: (width: 4032, height: 3024))
        XCTAssertEqual(labels(out), ["Taken", "Modified", "Size", "Format",
                                     "Dimensions", "MP", "Camera"])
    }

    func testFileFactsGoToTheTopWhenThereIsNoCaptureDate() {
        let out = FileMetadata.withFileFacts([InfoRow("Pages", "12")],
                                             modified: Date(timeIntervalSince1970: 0),
                                             sizeBytes: 900_000, fileExtension: "pdf",
                                             dimensions: nil)
        XCTAssertEqual(labels(out), ["Modified", "Size", "Format", "Pages"])
    }

    func testFileFactsStayBelowTheCaptureDateWhenThereIsNoModifiedDate() {
        // Anchored on the capture date, not on the Modified row — otherwise a
        // file with no modification date pushes its facts above "Taken".
        let out = FileMetadata.withFileFacts([InfoRow("Taken", "Jun 17, 2026")],
                                             modified: nil, sizeBytes: 1_000_000,
                                             fileExtension: "jpg", dimensions: nil)
        XCTAssertEqual(labels(out), ["Taken", "Size", "Format"])
    }

    func testVideoKeepsOneDimensionsRow() {
        // The video loader already emits Dimensions; passing nil here is what
        // stops it being added a second time.
        let base = FileMetadata.videoMetadata(durationSeconds: 222,
                                              dimensions: (width: 1080, height: 1920),
                                              frameRate: 30,
                                              recorded: Date(timeIntervalSince1970: 0),
                                              coordinate: nil).rows
        let out = FileMetadata.withFileFacts(base, modified: Date(timeIntervalSince1970: 0),
                                             sizeBytes: 50_000_000, fileExtension: "mov",
                                             dimensions: nil)
        XCTAssertEqual(labels(out).filter { $0 == "Dimensions" }.count, 1)
        XCTAssertEqual(labels(out), ["Recorded", "Modified", "Size", "Format",
                                     "Dimensions", "Duration", "Frame Rate"])
    }

    func testFileFactsOmitEveryUnavailableField() {
        // Nothing available → nothing invented (the "if not available don't
        // show it" rule), and an extensionless file gets no Format row.
        let out = FileMetadata.withFileFacts([], modified: nil, sizeBytes: nil,
                                             fileExtension: "", dimensions: nil)
        XCTAssertTrue(out.isEmpty, "expected no rows, got \(labels(out))")
    }

    func testFileFactsSkipDegenerateDimensions() {
        let out = FileMetadata.withFileFacts([], modified: nil, sizeBytes: nil,
                                             fileExtension: "",
                                             dimensions: (width: 0, height: 400))
        XCTAssertTrue(out.isEmpty, "expected no rows, got \(labels(out))")
    }
}
