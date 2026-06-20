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
}
