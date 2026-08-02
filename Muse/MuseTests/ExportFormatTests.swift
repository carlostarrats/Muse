//
//  ExportFormatTests.swift
//  MuseTests
//
//  What the export card is allowed to offer.
//
//  The first test is the important one: the available list is built from what
//  the RUNNING OS reports writable, because ImageIO reads far more formats than
//  it writes. It reads WebP and DNG and writes neither — a hard-coded table
//  would have promised both and failed at the last step.
//

import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Muse

final class ExportFormatTests: XCTestCase {
    private let probe = URL(fileURLWithPath: "/probe.jpg")

    func testAvailableNeverListsATypeImageIOCannotWrite() {
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        XCTAssertFalse(writable.isEmpty, "no writable types at all — the probe itself is broken")
        for format in ExportFormat.available {
            switch format {
            case .sameAsOriginal:
                continue                     // resolves per-file, never written as itself
            case .webp:
                continue                     // libwebp, not ImageIO
            default:
                XCTAssertTrue(writable.contains(format.utType(for: probe).identifier),
                              "\(format) is offered but ImageIO can't write it")
            }
        }
    }

    /// WebP is only offered when an encoder is actually linked. This is what
    /// keeps the card honest before Task 8 lands and if it ever regresses.
    func testWebPIsOfferedOnlyWhenAnEncoderExists() {
        XCTAssertEqual(ExportFormat.available.contains(.webp), WebPEncoder.isAvailable)
    }

    func testAvailableAlwaysIncludesTheUniversalFormats() {
        XCTAssertTrue(ExportFormat.available.contains(.sameAsOriginal))
        XCTAssertTrue(ExportFormat.available.contains(.jpeg))
        XCTAssertTrue(ExportFormat.available.contains(.png))
    }

    func testAvailableIsInMenuOrder() {
        let order = ExportFormat.available
        guard let jpeg = order.firstIndex(of: .jpeg),
              let png = order.firstIndex(of: .png),
              let same = order.firstIndex(of: .sameAsOriginal) else {
            return XCTFail("expected formats missing")
        }
        XCTAssertLessThan(same, jpeg)
        XCTAssertLessThan(jpeg, png)
    }

    func testSameAsOriginalResolvesToTheSourceContainer() {
        XCTAssertEqual(ExportFormat.sameAsOriginal.resolved(for: URL(fileURLWithPath: "/a/b.png")), .png)
        XCTAssertEqual(ExportFormat.sameAsOriginal.resolved(for: URL(fileURLWithPath: "/a/b.TIF")), .tiff)
        XCTAssertEqual(ExportFormat.sameAsOriginal.resolved(for: URL(fileURLWithPath: "/a/b.tiff")), .tiff)
        XCTAssertEqual(ExportFormat.sameAsOriginal.resolved(for: URL(fileURLWithPath: "/a/b.heic")), .heic)
        XCTAssertEqual(ExportFormat.sameAsOriginal.resolved(for: URL(fileURLWithPath: "/a/b.jpg")), .jpeg)
    }

    /// RAW can't be written back, so every RAW resolves to JPEG. This is the
    /// gap the whole feature exists to close.
    func testSameAsOriginalResolvesRawToJPEG() {
        for ext in ["cr2", "CR3", "nef", "arw", "dng", "raf", "orf", "rw2"] {
            XCTAssertEqual(ExportFormat.sameAsOriginal.resolved(for: URL(fileURLWithPath: "/a/b.\(ext)")),
                           .jpeg, "\(ext) should resolve to JPEG")
        }
    }

    func testAConcreteFormatResolvesToItself() {
        let raw = URL(fileURLWithPath: "/a/b.cr2")
        XCTAssertEqual(ExportFormat.png.resolved(for: raw), .png)
        XCTAssertEqual(ExportFormat.tiff.resolved(for: raw), .tiff)
    }

    func testFileExtensions() {
        let jpg = URL(fileURLWithPath: "/a/b.jpg")
        XCTAssertEqual(ExportFormat.jpeg.fileExtension(for: jpg), "jpg")
        XCTAssertEqual(ExportFormat.png.fileExtension(for: jpg), "png")
        XCTAssertEqual(ExportFormat.tiff.fileExtension(for: jpg), "tif")
        XCTAssertEqual(ExportFormat.heic.fileExtension(for: jpg), "heic")
        XCTAssertEqual(ExportFormat.webp.fileExtension(for: jpg), "webp")
        XCTAssertEqual(ExportFormat.sameAsOriginal.fileExtension(for: URL(fileURLWithPath: "/a/b.CR2")), "jpg")
        XCTAssertEqual(ExportFormat.sameAsOriginal.fileExtension(for: URL(fileURLWithPath: "/a/b.png")), "png")
    }

    func testOnlyLossyFormatsCarryQuality() {
        XCTAssertTrue(ExportFormat.jpeg.supportsQuality)
        XCTAssertTrue(ExportFormat.heic.supportsQuality)
        XCTAssertTrue(ExportFormat.webp.supportsQuality)
        XCTAssertFalse(ExportFormat.png.supportsQuality)
        XCTAssertFalse(ExportFormat.tiff.supportsQuality)
    }

    func testOnlyTIFFCarriesBitDepth() {
        XCTAssertTrue(ExportFormat.tiff.supportsBitDepth)
        XCTAssertFalse(ExportFormat.jpeg.supportsBitDepth)
        XCTAssertFalse(ExportFormat.png.supportsBitDepth)
        XCTAssertFalse(ExportFormat.heic.supportsBitDepth)
    }

    /// Flattening a PNG or TIFF would be a silent data loss; JPEG and HEIC have
    /// no usable alpha and must flatten or they composite against black.
    func testAlphaIsKeptOnlyWhereTheContainerCanCarryIt() {
        XCTAssertTrue(ExportFormat.png.keepsAlpha)
        XCTAssertTrue(ExportFormat.tiff.keepsAlpha)
        XCTAssertTrue(ExportFormat.webp.keepsAlpha)
        XCTAssertFalse(ExportFormat.jpeg.keepsAlpha)
        XCTAssertFalse(ExportFormat.heic.keepsAlpha)
    }

    func testDisplayNamesAreNonEmpty() {
        for f in ExportFormat.allCases {
            XCTAssertFalse(f.displayName.isEmpty, "\(f) has no display name")
        }
    }

    func testSettingsRoundTripThroughCodable() throws {
        let s = ExportSettings(format: .tiff, quality: 0.8, tiff16: true,
                               resize: .fitWithin(width: 1200, height: 900),
                               includeEXIF: true, includeLocation: false)
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(ExportSettings.self, from: data), s)
    }
}
