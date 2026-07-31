//
//  PhotoHeaderReaderTests.swift
//  MuseTests
//
//  Header-only GPS+EXIF extraction for the v13/v14 write pipeline. Mirrors
//  FileMetadata's display-time reader exactly — the two must never diverge,
//  or a viewer shows one camera/location while search indexes another.
//

import XCTest
@testable import Muse

final class PhotoHeaderReaderTests: XCTestCase {

    // MARK: - sanitize

    func testSanitizeAcceptsValidRange() {
        let c = Coordinate(lat: 38.7223, long: -9.1393)
        XCTAssertEqual(PhotoHeaderReader.sanitize(c)?.lat, 38.7223)
        XCTAssertEqual(PhotoHeaderReader.sanitize(c)?.long, -9.1393)
    }

    func testSanitizeRejectsOutOfRangeLatitude() {
        XCTAssertNil(PhotoHeaderReader.sanitize(Coordinate(lat: 91, long: 0)))
        XCTAssertNil(PhotoHeaderReader.sanitize(Coordinate(lat: -91, long: 0)))
    }

    func testSanitizeRejectsOutOfRangeLongitude() {
        XCTAssertNil(PhotoHeaderReader.sanitize(Coordinate(lat: 0, long: 181)))
        XCTAssertNil(PhotoHeaderReader.sanitize(Coordinate(lat: 0, long: -181)))
    }

    func testSanitizeRejectsNonFiniteValues() {
        XCTAssertNil(PhotoHeaderReader.sanitize(Coordinate(lat: .nan, long: 0)))
        XCTAssertNil(PhotoHeaderReader.sanitize(Coordinate(lat: 0, long: .infinity)))
    }

    func testSanitizeAcceptsBoundaryValues() {
        XCTAssertNotNil(PhotoHeaderReader.sanitize(Coordinate(lat: 90, long: 180)))
        XCTAssertNotNil(PhotoHeaderReader.sanitize(Coordinate(lat: -90, long: -180)))
    }

    // MARK: - exifFields (pure mapping, no fixtures on disk)

    func testExifFieldsReadsScalarISO() {
        let fields = PhotoHeaderReader.exifFields(
            exif: ["ISOSpeedRatings": 400, "FNumber": 2.0, "ExposureTime": 0.008,
                   "FocalLength": 23.0, "FocalLenIn35mmFilm": 35, "LensModel": "23mm f/2"],
            tiff: ["Make": "FUJIFILM", "Model": "X100V"])
        XCTAssertEqual(fields.iso, 400)
        XCTAssertEqual(fields.cameraMake, "FUJIFILM")
        XCTAssertEqual(fields.cameraModel, "X100V")
        XCTAssertEqual(fields.lens, "23mm f/2")
        XCTAssertEqual(fields.fNumber, 2.0)
        XCTAssertEqual(fields.exposureSeconds, 0.008)
        XCTAssertEqual(fields.focalLength, 23.0)
        XCTAssertEqual(fields.focalLength35mm, 35)
    }

    func testExifFieldsToleratesArrayISO() {
        // Some encoders write ISOSpeedRatings as a single-element array rather
        // than a bare Int — FileMetadata already tolerates this; so must this.
        let fields = PhotoHeaderReader.exifFields(exif: ["ISOSpeedRatings": [400]], tiff: [:])
        XCTAssertEqual(fields.iso, 400)
    }

    func testExifFieldsMissingKeysAreNil() {
        let fields = PhotoHeaderReader.exifFields(exif: [:], tiff: [:])
        XCTAssertNil(fields.iso)
        XCTAssertNil(fields.cameraMake)
        XCTAssertNil(fields.flashFired)
        XCTAssertNil(fields.captureDate)
    }

    func testExifFieldsTrimsBlankStrings() {
        let fields = PhotoHeaderReader.exifFields(exif: ["LensModel": "   "],
                                                 tiff: ["Make": " Canon "])
        XCTAssertNil(fields.lens)
        XCTAssertEqual(fields.cameraMake, "Canon")
    }

    func testExifFieldsFlashBitZeroFired() {
        // EXIF Flash is a bitfield; bit 0 = fired.
        XCTAssertEqual(PhotoHeaderReader.exifFields(exif: ["Flash": 1], tiff: [:]).flashFired, true)
        XCTAssertEqual(PhotoHeaderReader.exifFields(exif: ["Flash": 0], tiff: [:]).flashFired, false)
        // 0x19 = fired + compulsory mode: bit 0 still set.
        XCTAssertEqual(PhotoHeaderReader.exifFields(exif: ["Flash": 25], tiff: [:]).flashFired, true)
        XCTAssertNil(PhotoHeaderReader.exifFields(exif: [:], tiff: [:]).flashFired)
    }

    // MARK: - parseExifDate

    func testParseExifDateValid() {
        let result = PhotoHeaderReader.parseExifDate("2019:06:21 14:30:00")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.md, "06-21")
    }

    func testParseExifDateGarbageReturnsNil() {
        XCTAssertNil(PhotoHeaderReader.parseExifDate("not a date"))
        XCTAssertNil(PhotoHeaderReader.parseExifDate(nil))
        XCTAssertNil(PhotoHeaderReader.parseExifDate(""))
    }

    func testParseExifDateEpochAndMDAgree() {
        let result = PhotoHeaderReader.parseExifDate("2023:12:31 23:59:59")
        XCTAssertEqual(result?.md, "12-31")
        guard let epoch = result?.epoch else { return XCTFail("no epoch") }
        XCTAssertEqual(PhotoHeaderReader.monthDay(Date(timeIntervalSince1970: TimeInterval(epoch))),
                       "12-31")
    }

    func testExifFieldsCaptureDateFlowsThrough() {
        let fields = PhotoHeaderReader.exifFields(
            exif: ["DateTimeOriginal": "2019:06:21 14:30:00"], tiff: [:])
        XCTAssertEqual(fields.captureMD, "06-21")
        XCTAssertNotNil(fields.captureDate)
    }

    // MARK: - read

    func testReadReturnsEmptyHeaderForUnsupportedKind() async {
        let url = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).txt")
        let header = await PhotoHeaderReader.read(url: url, kind: .text)
        XCTAssertNil(header.coordinate)
        XCTAssertNil(header.exif)
    }

    func testReadReturnsEmptyHeaderForMissingImage() async {
        let url = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).jpg")
        let header = await PhotoHeaderReader.read(url: url, kind: .image)
        XCTAssertNil(header.coordinate)
        XCTAssertNil(header.exif)
    }
}
