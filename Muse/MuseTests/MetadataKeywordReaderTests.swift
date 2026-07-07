//
//  MetadataKeywordReaderTests.swift
//  MuseTests
//
//  The import's read half: IPTC keywords/star-rating, embedded XMP
//  (dc:subject + xmp:Rating), and .xmp sidecars (both IMG.xmp and
//  IMG.ext.xmp namings), with sidecar > embedded priority and clean throws
//  for unreadable files. No pixel decode is asserted implicitly: these
//  fixtures are valid images, but the garbage-bytes case must still throw
//  rather than crash.
//

import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Muse

final class MetadataKeywordReaderTests: XCTestCase {

    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
        super.tearDown()
    }

    private func tempURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-import-\(UUID().uuidString)-\(name)")
        tempFiles.append(url)
        return url
    }

    private func makePixels() -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 8, height: 8,
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ctx.makeImage()!
    }

    /// Tiny valid JPEG with optional IPTC keywords/rating baked in.
    private func makeJPEG(name: String = "img.jpg",
                          iptcKeywords: [String]? = nil,
                          iptcRating: Int? = nil) throws -> URL {
        var iptc: [CFString: Any] = [:]
        if let iptcKeywords { iptc[kCGImagePropertyIPTCKeywords] = iptcKeywords }
        if let iptcRating { iptc[kCGImagePropertyIPTCStarRating] = iptcRating }
        let props: [CFString: Any] = iptc.isEmpty ? [:] : [kCGImagePropertyIPTCDictionary: iptc]
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, makePixels(), props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let url = tempURL(name)
        try (data as Data).write(to: url)
        return url
    }

    private func xmpPacket(subjects: [String], rating: Int?) -> String {
        let items = subjects.map { "<rdf:li>\($0)</rdf:li>" }.joined()
        let ratingAttr = rating.map { " xmp:Rating=\"\($0)\"" } ?? ""
        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF \
        xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"\(ratingAttr)>\
        <dc:subject><rdf:Bag>\(items)</rdf:Bag></dc:subject>\
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
    }

    /// JPEG with an embedded XMP packet (dc:subject + xmp:Rating).
    private func makeXMPJPEG(subjects: [String], rating: Int?) throws -> URL {
        let packet = xmpPacket(subjects: subjects, rating: rating)
        let meta = CGImageMetadataCreateFromXMPData(packet.data(using: .utf8)! as CFData)!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImageAndMetadata(dest, makePixels(), meta, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let url = tempURL("xmp.jpg")
        try (data as Data).write(to: url)
        return url
    }

    // MARK: embedded IPTC

    func testReadsIPTCKeywordsAndRating() throws {
        let url = try makeJPEG(iptcKeywords: ["dog", "park"], iptcRating: 3)
        let out = try MetadataKeywordReader.read(url: url)
        XCTAssertEqual(Set(out.keywords), ["dog", "park"])
        XCTAssertEqual(out.rating, 3)
    }

    // MARK: embedded XMP

    func testReadsEmbeddedXMPSubjectsAndRating() throws {
        let url = try makeXMPJPEG(subjects: ["travel", "japan"], rating: 4)
        let out = try MetadataKeywordReader.read(url: url)
        XCTAssertEqual(Set(out.keywords), ["travel", "japan"])
        XCTAssertEqual(out.rating, 4)
    }

    func testXMPRatingClampsThroughNormalize() throws {
        let url = try makeXMPJPEG(subjects: [], rating: 7)
        XCTAssertEqual(try MetadataKeywordReader.read(url: url).rating, 5)
    }

    // MARK: sidecars

    func testSidecarBeatsEmbeddedMetadata() throws {
        // Embedded says one thing; the sidecar (replaced-extension naming,
        // IMG.xmp beside IMG.jpg) says another. Sidecar wins per field.
        let img = try makeJPEG(name: "pic.jpg", iptcKeywords: ["embedded"], iptcRating: 2)
        let sidecar = img.deletingPathExtension().appendingPathExtension("xmp")
        try xmpPacket(subjects: ["sidecar"], rating: 5)
            .write(to: sidecar, atomically: true, encoding: .utf8)
        tempFiles.append(sidecar)
        let out = try MetadataKeywordReader.read(url: img)
        XCTAssertEqual(out.keywords, ["sidecar"])
        XCTAssertEqual(out.rating, 5)
    }

    func testAppendedExtensionSidecarIsFound() throws {
        // Some tools write IMG.jpg.xmp instead of IMG.xmp.
        let img = try makeJPEG(name: "pic2.jpg")
        let sidecar = img.appendingPathExtension("xmp")
        try xmpPacket(subjects: ["appended"], rating: nil)
            .write(to: sidecar, atomically: true, encoding: .utf8)
        tempFiles.append(sidecar)
        XCTAssertEqual(try MetadataKeywordReader.read(url: img).keywords, ["appended"])
    }

    func testSidecarFillsOnlyMissingFields() throws {
        // Sidecar has keywords but no rating → rating falls through to embedded.
        let img = try makeJPEG(name: "pic3.jpg", iptcKeywords: ["embedded"], iptcRating: 2)
        let sidecar = img.deletingPathExtension().appendingPathExtension("xmp")
        try xmpPacket(subjects: ["sidecar"], rating: nil)
            .write(to: sidecar, atomically: true, encoding: .utf8)
        tempFiles.append(sidecar)
        let out = try MetadataKeywordReader.read(url: img)
        XCTAssertEqual(out.keywords, ["sidecar"])
        XCTAssertEqual(out.rating, 2)
    }

    // MARK: nothing / errors

    func testNoMetadataIsEmptyNotError() throws {
        let url = try makeJPEG()
        let out = try MetadataKeywordReader.read(url: url)
        XCTAssertTrue(out.isEmpty)
    }

    func testUnreadableFileThrows() throws {
        let url = tempURL("garbage.jpg")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)
        XCTAssertThrowsError(try MetadataKeywordReader.read(url: url)) { error in
            guard case MetadataKeywordReader.ReadError.unreadable = error else {
                return XCTFail("expected .unreadable, got \(error)")
            }
        }
    }
}
