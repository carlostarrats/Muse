//
//  ExportFormat.swift
//  Muse
//
//  What a general export can produce, and how big. Pure data — the render lives
//  in ImageExportRender.
//
//  The available list is built from what the RUNNING OS reports writable, never
//  from a hard-coded table: ImageIO reads far more formats than it writes (it
//  reads WebP and DNG and writes neither — verified, 22 writable types on macOS
//  26.5), and a card that offers an output the machine can't produce is a card
//  that fails at the last step. WebP is the one entry that doesn't come from
//  ImageIO; it's ours, via libwebp.
//
//  Platform-neutral: Foundation / CoreGraphics / ImageIO / UTType only.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ExportFormat: String, CaseIterable, Codable, Sendable {
    case sameAsOriginal, jpeg, png, tiff, heic, webp

    /// NOT auto-extracted — a computed `String` is invisible to the compiler's
    /// literal scan, so each of these is hand-wrapped or it ships in English.
    var displayName: String {
        switch self {
        case .sameAsOriginal: String(localized: "Same as original")
        case .jpeg: String(localized: "JPEG")
        case .png: String(localized: "PNG")
        case .tiff: String(localized: "TIFF")
        case .heic: String(localized: "HEIC")
        case .webp: String(localized: "WebP")
        }
    }

    var supportsQuality: Bool {
        switch self {
        case .jpeg, .heic, .webp: true
        case .sameAsOriginal, .png, .tiff: false
        }
    }

    var supportsBitDepth: Bool { self == .tiff }

    /// JPEG and HEIC have no usable alpha, so those exports flatten onto white.
    /// PNG, TIFF and WebP keep it — flattening them would be a data loss the
    /// social path can afford (it's fitting a photo to a platform) and this one
    /// can't (it's converting a file).
    var keepsAlpha: Bool {
        switch self {
        case .jpeg, .heic: false
        case .png, .tiff, .webp: true
        // Resolve before asking; `.sameAsOriginal` is never encoded as itself.
        case .sameAsOriginal: true
        }
    }

    /// RAW extensions resolve to JPEG: a RAW cannot be written back, so "same
    /// as original" has to mean something, and JPEG is what `EditRenderer`
    /// already produces for a RAW on every other path out of the app.
    private static let rawExtensions: Set<String> = [
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
        "rw2", "pef", "dng", "raw", "dcr", "kdc", "erf", "mrw", "3fr", "iiq",
        "mos", "x3f", "srw", "gpr", "ari", "fff",
    ]

    /// The concrete format this one means for a given source. Identity for
    /// everything except `.sameAsOriginal`.
    func resolved(for url: URL) -> ExportFormat {
        guard self == .sameAsOriginal else { return self }
        let ext = url.pathExtension.lowercased()
        if Self.rawExtensions.contains(ext) { return .jpeg }
        switch ext {
        case "png": return .png
        case "tif", "tiff": return .tiff
        case "heic", "heif": return .heic
        default: return .jpeg
        }
    }

    func fileExtension(for url: URL) -> String {
        switch resolved(for: url) {
        case .png: "png"
        case .tiff: "tif"
        case .heic: "heic"
        case .webp: "webp"
        case .jpeg, .sameAsOriginal: "jpg"
        }
    }

    func utType(for url: URL) -> UTType {
        switch resolved(for: url) {
        case .png: .png
        case .tiff: .tiff
        case .heic: UTType("public.heic") ?? .jpeg
        case .webp: UTType("org.webmproject.webp") ?? .png
        case .jpeg, .sameAsOriginal: .jpeg
        }
    }

    /// Formats this machine can actually write, in menu order.
    /// `.sameAsOriginal` is always offered — it resolves to a concrete format
    /// per file, and JPEG, its fallback, is always writable.
    static var available: [ExportFormat] {
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        let probe = URL(fileURLWithPath: "/probe.jpg")
        return [.sameAsOriginal, .jpeg, .png, .tiff, .heic, .webp].filter { format in
            switch format {
            case .sameAsOriginal: true
            case .webp: WebPEncoder.isAvailable
            default: writable.contains(format.utType(for: probe).identifier)
            }
        }
    }
}

/// How big the export comes out. NEVER upscales, in any mode.
nonisolated enum ExportResize: Equatable, Codable, Sendable {
    case original
    case longEdge(Int)
    case fitWithin(width: Int, height: Int)

    /// The output size for a source. A source smaller than the target exports
    /// at its own size — the same global rule `SocialRender` holds. Enlarging a
    /// photo to hit a typed number produces a bigger file that looks worse.
    func targetSize(for source: CGSize) -> CGSize {
        // A corrupt header can report zero; clamp rather than divide by it.
        let w = max(1, source.width.isFinite ? source.width : 1)
        let h = max(1, source.height.isFinite ? source.height : 1)
        let safe = CGSize(width: w, height: h)
        switch self {
        case .original:
            return safe
        case .longEdge(let cap):
            let factor = min(1, CGFloat(max(1, cap)) / max(w, h))
            guard factor < 1 else { return safe }
            return CGSize(width: max(1, (w * factor).rounded()),
                          height: max(1, (h * factor).rounded()))
        case .fitWithin(let bw, let bh):
            let factor = min(1, min(CGFloat(max(1, bw)) / w, CGFloat(max(1, bh)) / h))
            guard factor < 1 else { return safe }
            return CGSize(width: max(1, (w * factor).rounded()),
                          height: max(1, (h * factor).rounded()))
        }
    }
}

/// One export's worth of choices. Codable because a saved preset is exactly
/// this, stored as JSON.
nonisolated struct ExportSettings: Equatable, Codable, Sendable {
    var format: ExportFormat
    var quality: Double
    var tiff16: Bool
    var resize: ExportResize
    var includeEXIF: Bool
    var includeLocation: Bool

    init(format: ExportFormat = .jpeg, quality: Double = 0.9, tiff16: Bool = false,
         resize: ExportResize = .original, includeEXIF: Bool = false,
         includeLocation: Bool = false) {
        self.format = format
        self.quality = quality
        self.tiff16 = tiff16
        self.resize = resize
        self.includeEXIF = includeEXIF
        self.includeLocation = includeLocation
    }
}
