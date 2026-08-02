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

    /// Container capability, which is not the same question as the user's
    /// choice — see the `flattens` tests below for where the two meet.
    func testOnlySomeContainersCanCarryAlpha() {
        XCTAssertTrue(ExportFormat.png.canCarryAlpha)
        XCTAssertTrue(ExportFormat.tiff.canCarryAlpha)
        XCTAssertTrue(ExportFormat.webp.canCarryAlpha)
        XCTAssertFalse(ExportFormat.jpeg.canCarryAlpha)
        XCTAssertFalse(ExportFormat.heic.canCarryAlpha)
    }

    func testTransparentIsHonouredOnlyWhereTheContainerAllowsIt() {
        let transparent = ExportSettings(background: .transparent)
        XCTAssertFalse(transparent.flattens(for: .png))
        XCTAssertFalse(transparent.flattens(for: .tiff))
        XCTAssertFalse(transparent.flattens(for: .webp))
        // A JPEG has to land on SOMETHING; an uncomposited alpha channel lands
        // on black, which is the bug this rule exists to prevent.
        XCTAssertTrue(transparent.flattens(for: .jpeg))
        XCTAssertTrue(transparent.flattens(for: .heic))
        XCTAssertEqual(transparent.flattenColor(for: .jpeg), .white)
    }

    func testAnExplicitBackgroundAlwaysFlattens() {
        for background: ExportBackground in [.white, .black] {
            let s = ExportSettings(background: background)
            for format: ExportFormat in [.png, .tiff, .webp, .jpeg, .heic] {
                XCTAssertTrue(s.flattens(for: format), "\(background) on \(format)")
                XCTAssertEqual(s.flattenColor(for: format), background)
            }
        }
    }

    /// A preset written before backgrounds existed must still load. Losing a
    /// saved preset because a field was added is worse than the field's absence.
    func testSettingsFromBeforeBackgroundsStillDecode() throws {
        let old = """
        {"format":"png","quality":0.8,"tiff16":false,\
        "resize":{"original":{}},"includeEXIF":true,"includeLocation":false}
        """
        let decoded = try JSONDecoder().decode(ExportSettings.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.format, .png)
        XCTAssertEqual(decoded.background, .transparent)
        XCTAssertTrue(decoded.includeEXIF)
    }

    func testDisplayNamesAreNonEmpty() {
        for f in ExportFormat.allCases {
            XCTAssertFalse(f.displayName.isEmpty, "\(f) has no display name")
        }
    }

    // MARK: - Quality tiers

    func testTierValuesAscend() {
        let values = QualityTier.allCases.map(\.value)
        XCTAssertEqual(values, values.sorted())
        XCTAssertEqual(Set(values).count, values.count)
        XCTAssertTrue(values.allSatisfy { $0 > 0 && $0 <= 1 })
    }

    func testATierIsRecognisedFromItsOwnValue() {
        for tier in QualityTier.allCases {
            XCTAssertEqual(QualityTier.matching(tier.value), tier)
        }
    }

    /// Between tiers the control says Custom rather than rounding — claiming
    /// "High" at 0.78 would be a label the number on screen contradicts.
    func testAValueBetweenTiersMatchesNothing() {
        XCTAssertNil(QualityTier.matching(0.78))
        XCTAssertNil(QualityTier.matching(0.60))
    }

    // MARK: - WebP lossless

    /// Lossless is a separate encoder, not quality = 100, so it has to survive
    /// a round trip independently of the quality value.
    func testLosslessRoundTripsAndDefaultsOff() throws {
        XCTAssertFalse(ExportSettings().webpLossless)
        let s = ExportSettings(format: .webp, quality: 0.4, webpLossless: true)
        let back = try JSONDecoder().decode(ExportSettings.self,
                                            from: try JSONEncoder().encode(s))
        XCTAssertTrue(back.webpLossless)
        XCTAssertEqual(back.quality, 0.4)
    }

    func testSettingsRoundTripThroughCodable() throws {
        let s = ExportSettings(format: .tiff, quality: 0.8, tiff16: true,
                               resize: .fitWithin(width: 1200, height: 900),
                               includeEXIF: true, includeLocation: false)
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(ExportSettings.self, from: data), s)
    }
}
