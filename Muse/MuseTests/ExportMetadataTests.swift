//
//  ExportMetadataTests.swift
//  MuseTests
//

import XCTest
import ImageIO
@testable import Muse

final class ExportMetadataTests: XCTestCase {
    private func fixtureSourceProperties() -> CFDictionary {
        [
            kCGImagePropertyOrientation as String: 6,
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifLensMake as String: "Fujifilm",
                kCGImagePropertyExifApertureValue as String: 2.8,
                kCGImagePropertyExifMakerNote as String: "makerNoteBlob",
            ],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Fujifilm",
                kCGImagePropertyTIFFModel as String: "X100V",
                kCGImagePropertyTIFFOrientation as String: 6,
            ],
            kCGImagePropertyIPTCDictionary as String: [
                kCGImagePropertyIPTCCredit as String: "Jane Doe",
                kCGImagePropertyIPTCCopyrightNotice as String: "© Jane Doe",
            ],
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 37.0,
                kCGImagePropertyGPSLongitude as String: 122.0,
            ],
            kCGImagePropertyMakerAppleDictionary as String: ["some": "makerNoteBlob"],
        ] as CFDictionary
    }

    private func output(includeLocation: Bool) -> [String: Any] {
        ExportMetadata.outputProperties(source: fixtureSourceProperties(),
                                        includeLocation: includeLocation) as! [String: Any]
    }

    func testExifOnKeepsCameraAndIPTCDropsGPSByDefault() {
        let dict = output(includeLocation: false)
        let tiff = dict[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake as String] as? String, "Fujifilm")
        XCTAssertNotNil(dict[kCGImagePropertyExifDictionary as String])
        let iptc = dict[kCGImagePropertyIPTCDictionary as String] as? [String: Any]
        XCTAssertEqual(iptc?[kCGImagePropertyIPTCCredit as String] as? String, "Jane Doe")
        XCTAssertNil(dict[kCGImagePropertyGPSDictionary as String])
    }

    func testExifOnAlwaysDropsOrientationKeys() {
        let dict = output(includeLocation: false)
        XCTAssertNil(dict[kCGImagePropertyOrientation as String])
        let tiff = dict[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFOrientation as String])
    }

    func testExifOnAlwaysDropsMakerNotes() {
        let dict = output(includeLocation: false)
        XCTAssertNil(dict[kCGImagePropertyMakerAppleDictionary as String])
        let exif = dict[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifMakerNote as String])
    }

    func testIncludeLocationKeepsGPS() {
        let gps = output(includeLocation: true)[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        XCTAssertEqual(gps?[kCGImagePropertyGPSLatitude as String] as? Double, 37.0)
    }
}
