//
//  EditCopyFlow.swift
//  Muse
//
//  Edit-a-Copy: bake the Muse edits into a new file beside the original and
//  hand THAT to the external app.
//
//  Ordered and FAIL-CLOSED: render → metadata → move → index. A failure at
//  render or move writes nothing at all (the render lands in a temp first, so
//  a half-written file never appears in the user's folder). A failure after
//  the move leaves a real file on disk that simply hasn't been reconciled yet
//  — the next pass finds it. Neither outcome loses data.
//
//  The copy is a FRESH asset: no inherited stack, normal analysis, and later
//  external saves to it are ordinary edit-in-place.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum EditCopyFlow {
    enum FlowError: Error {
        case noStack
        case renderFailed
        case moveFailed
    }

    static func run(originalURL: URL) async throws -> URL {
        guard let stack = EditStackIndex.resolvedStack(for: originalURL),
              EditRenderer.canRender(stack)
        else { throw FlowError.noStack }

        let folder = originalURL.deletingLastPathComponent()
        let stem = originalURL.deletingPathExtension().lastPathComponent
        let isRaw = EditRenderer.isRawURL(originalURL)
        let targetExt = EditCopyNaming.targetExtension(for: originalURL, isRaw: isRaw)
        let existing = Set((try? FileManager.default
            .contentsOfDirectory(atPath: folder.path)) ?? [])
        let filename = EditCopyNaming.candidate(stem: stem, ext: targetExt, existing: existing)
        let destURL = folder.appendingPathComponent(filename)

        // Render to a TEMP first: a failure mid-encode must not leave a
        // truncated file sitting in the user's library.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-editcopy-\(UUID().uuidString)")
            .appendingPathExtension(targetExt)
        do {
            try EditRenderer.exportFile(url: originalURL, stack: stack, to: tempURL,
                                        format: isRaw ? .tiff16
                                                      : .matchingSource(originalURL))
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw FlowError.renderFailed
        }

        // Carry the original's EXIF/IPTC minus ORIENTATION (the render already
        // applied it; keeping the tag would rotate it twice). Metadata
        // stripping is a Drive-SHARE rule, not a local one — a copy the user
        // is about to edit should keep its capture data.
        try? EditCopyMetadata.copyMetadata(from: originalURL, to: tempURL)

        do {
            try FileManager.default.moveItem(at: tempURL, to: destURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw FlowError.moveFailed
        }

        // Index deterministically rather than waiting for FSEvents — the
        // caller opens the file immediately, and an unindexed file has no
        // identity to hang tags or a later edit off.
        _ = await Indexer.shared.indexFile(at: destURL,
                                           kind: AssetKind.detect(at: destURL))
        return destURL
    }
}

/// Forward the original's metadata onto a rendered copy, dropping only the
/// orientation tag.
nonisolated enum EditCopyMetadata {
    enum MetadataError: Error { case unreadable, unwritable }

    static func copyMetadata(from source: URL, to dest: URL) throws {
        guard let sourceSrc = CGImageSourceCreateWithURL(source as CFURL, nil),
              let sourceProps = CGImageSourceCopyPropertiesAtIndex(sourceSrc, 0, nil)
                  as? [CFString: Any],
              let destSrc = CGImageSourceCreateWithURL(dest as CFURL, nil),
              let type = CGImageSourceGetType(destSrc)
        else { throw MetadataError.unreadable }

        var props = sourceProps
        // The render already baked orientation into the pixels; leaving the
        // tag would have a viewer rotate them a second time.
        props.removeValue(forKey: kCGImagePropertyOrientation)
        props[kCGImagePropertyTIFFDictionary] =
            (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
                .map { var d = $0; d.removeValue(forKey: kCGImagePropertyTIFFOrientation); return d }

        let tempURL = dest.deletingLastPathComponent()
            .appendingPathComponent("meta-\(UUID().uuidString)-\(dest.lastPathComponent)")
        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL, type, 1, nil)
        else { throw MetadataError.unwritable }
        CGImageDestinationAddImageFromSource(destination, destSrc, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw MetadataError.unwritable
        }
        do {
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: tempURL)
        } catch {
            // The swap has to happen on the same volume as `dest`, so this
            // temp sits beside it; a silent failure would strand it there.
            try? FileManager.default.removeItem(at: tempURL)
            throw MetadataError.unwritable
        }
    }
}
