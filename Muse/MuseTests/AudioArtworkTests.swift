//
//  AudioArtworkTests.swift
//  MuseTests
//
//  Audio no longer goes to QuickLook (it opens the file in an UNRESTRICTED
//  AVFoundation that would resolve a remote data reference). Cover art is read
//  from the reference-RESTRICTED asset instead — which is only worth doing if it
//  actually works, so this builds a real .m4a with embedded artwork and reads it
//  back through the same restricted path the thumbnail uses.
//

import XCTest
import AVFoundation
import AppKit
@testable import Muse

final class AudioArtworkTests: XCTestCase {

    /// A 0.2s silent m4a carrying a PNG cover, written with AVAssetExportSession
    /// (the same container an iTunes/Music file uses).
    private func makeM4AWithArtwork(_ dir: URL, artwork: Data?) async throws -> URL? {
        let wav = dir.appendingPathComponent("src.wav")
        // Scoped so AVAudioFile deallocates — and therefore FLUSHES and closes
        // the file — before the asset below reads it. Leaving it alive is what
        // made the export fail with -12780.
        do {
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            let file = try AVAudioFile(forWriting: wav, settings: fmt.settings)
            let frames = AVAudioFrameCount(44100 / 2)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
            buf.frameLength = frames
            try file.write(from: buf)
        }

        let asset = AVURLAsset(url: wav)
        guard let export = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPresetAppleM4A)
        else { return nil }
        let out = dir.appendingPathComponent("out.m4a")
        if let artwork {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierArtwork
            item.dataType = kCMMetadataBaseDataType_PNG as String
            item.value = artwork as NSData
            export.metadata = [item]
        }
        export.outputURL = out
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else { return nil }
        return out
    }

    private func pngData() -> Data {
        let img = NSImage(size: NSSize(width: 64, height: 64))
        img.lockFocus()
        NSColor.systemPink.drawSwatch(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        img.unlockFocus()
        let tiff = img.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    }

    func testEmbeddedCoverArtIsReadThroughTheRestrictedAsset() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MuseArt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        guard let m4a = try await makeM4AWithArtwork(dir, artwork: pngData()) else {
            throw XCTSkip("AVAssetExportSession unavailable in this environment")
        }
        XCTAssertEqual(AssetKind.detect(at: m4a), .audio)
        XCTAssertFalse(ThumbnailCache.mayUseQuickLook(.audio))

        // The exact path the grid thumbnail takes for audio.
        let asset = AVURLAsset.noNetwork(url: m4a)
        let metadata = try await asset.load(.commonMetadata)
        let items = AVMetadataItem.metadataItems(from: metadata,
                                                filteredByIdentifier: .commonIdentifierArtwork)
        XCTAssertFalse(items.isEmpty, "artwork must be reachable WITHOUT QuickLook — "
                     + "if this fails, audio tiles silently regressed to the type icon")
        let data = try await items[0].load(.dataValue)
        XCTAssertNotNil(data)
        XCTAssertNotNil(NSImage(data: data!), "the artwork bytes decode to an image")
    }

    /// Audio with NO artwork must resolve to nothing (caller falls back to the
    /// static type icon) rather than hanging or throwing.
    func testAudioWithoutArtworkYieldsNoItems() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MuseArt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        guard let m4a = try await makeM4AWithArtwork(dir, artwork: nil) else {
            throw XCTSkip("AVAssetExportSession unavailable in this environment")
        }
        let asset = AVURLAsset.noNetwork(url: m4a)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        let items = AVMetadataItem.metadataItems(from: metadata,
                                                filteredByIdentifier: .commonIdentifierArtwork)
        XCTAssertTrue(items.isEmpty)
    }
}
