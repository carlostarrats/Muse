//
//  OutputRender.swift
//  Muse
//
//  Every path that ships pixels out of the app renders through here. Today it
//  is IDENTITY — originals pass through unrendered — so nothing about export or
//  sharing changes; Spec 04 renders the edit stack when one exists, in this one
//  place, and every call site is already correct.
//
//  `RenderedOutput`'s `fileprivate` init is the enforcement: it can only be
//  constructed inside this file, so a new export/share/publish path physically
//  cannot compile without going through `OutputRender`. That is the whole
//  point — the failure mode this prevents is an export silently shipping
//  unedited pixels because someone passed a bare URL.
//
//  Backup is the ONE deliberate exclusion: it restores originals by content
//  hash, and rendering edits into it would corrupt the restore. See
//  `Backup/BackupBuilder.swift`.
//

import Foundation
import CoreGraphics
import ImageIO

/// Bytes approved for leaving the app. The ONLY way to obtain one is
/// `OutputRender`.
nonisolated struct RenderedOutput: Sendable {
    /// The file to read. The original today; a rendered temp file once an edit
    /// stack exists.
    let url: URL
    /// The edit stack these bytes were rendered from; nil = unedited original.
    let stackHash: String?

    fileprivate init(url: URL, stackHash: String?) {
        self.url = url
        self.stackHash = stackHash
    }
}

nonisolated enum OutputRender {
    /// Rendered temps live here so one sweep can collect them all.
    static let tempDirectoryName = "muse-render"
    /// Anything older than this at launch is abandoned (an interrupted
    /// publish, a crash mid-share) and gets collected.
    static let tempMaxAge: TimeInterval = 24 * 60 * 60

    /// An edited file leaves the app as a RENDERED temp; an unedited one
    /// leaves as its original bytes, untouched. A render failure falls back to
    /// the original rather than aborting: shipping the unedited photo is worse
    /// than shipping nothing only in theory — in practice a failed share is
    /// the worse outcome, and the fallback is visible (the user sees the
    /// original), not silent corruption.
    static func forOutput(_ url: URL) throws -> RenderedOutput {
        try forOutput(url, preferring: nil)
    }

    /// `preferring` overrides the container the render TEMP is written in.
    /// The general export uses it so a 16-bit request renders a 16-bit temp
    /// rather than inflating an 8-bit one and calling it deep — a depth claim
    /// the bytes wouldn't support.
    ///
    /// An ADDED overload, never a bypass: `RenderedOutput`'s init stays
    /// `fileprivate` and this is still the only way to obtain one, so the
    /// choke point (audit `OUT-1`) is intact. `nil` keeps the original
    /// behaviour exactly.
    static func forOutput(_ url: URL, preferring: OutputFormat?) throws -> RenderedOutput {
        guard let hash = EditStackIndex.stackHash(for: url),
              let stack = EditStackIndex.resolvedStack(for: url),
              EditRenderer.canRender(stack)
        else { return RenderedOutput(url: url, stackHash: nil) }

        let format: OutputFormat = preferring
            ?? (EditRenderer.isRawURL(url)
                ? .jpeg                              // RAW can't be written back
                : .matchingSource(url))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(tempDirectoryName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent)
                .appendingPathExtension(format.fileExtension)
            try EditRenderer.exportFile(url: url, stack: stack, to: dest, format: format)
            return RenderedOutput(url: dest, stackHash: hash)
        } catch {
            return RenderedOutput(url: url, stackHash: nil)
        }
    }

    /// Order-preserving — callers index-align these against their own arrays.
    static func forOutput(_ urls: [URL]) throws -> [RenderedOutput] {
        try urls.map { try forOutput($0) }
    }

    /// Decoded, downsampled, orientation-corrected image for a rendering export
    /// (the PDF). Callers keep their own decode-budget guard: this is the
    /// render step, not the safety step.
    ///
    /// `forOutput` already rendered an edited file to a temp, so `out.url`'s
    /// bytes are final and the bounded ImageIO path is correct for both cases.
    static func image(_ out: RenderedOutput, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(out.url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// Delete a rendered temp as soon as its consumer is done with it.
    ///
    /// The launch sweep below is the backstop for an INTERRUPTED export, not
    /// the collector for a successful one: a 1,000-image edited publish used
    /// to leave 1,000 full-resolution renders in `tmp` for a day, and a
    /// session that never relaunches never collected them at all.
    ///
    /// Deliberately a NO-OP for an unrendered output — `out.url` is then the
    /// user's own file, and this must never be able to delete that. BOTH
    /// guards (a non-nil stackHash, and the path living under our own temp
    /// root) are load-bearing; keep both.
    static func discard(_ out: RenderedOutput) {
        guard out.stackHash != nil else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(tempDirectoryName, isDirectory: true)
            .standardizedFileURL.path
        // The per-render UUID directory, not just the file inside it.
        let dir = out.url.standardizedFileURL.deletingLastPathComponent()
        guard dir.path.hasPrefix(root + "/") else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    static func discard(_ outs: [RenderedOutput]) {
        for out in outs { discard(out) }
    }

    /// Launch sweep for abandoned render temps. Age-based, not size-based: a
    /// temp still in use by an in-flight share is minutes old, never a day.
    static func sweepRenderTemps() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(tempDirectoryName,
                                                                isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-tempMaxAge)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified > cutoff { continue }
            try? fm.removeItem(at: entry)
        }
    }
}
