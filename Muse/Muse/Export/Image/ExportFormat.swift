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

    /// Whether the container can carry transparency at all. JPEG and HEIC
    /// can't, so a transparent source has to land on something; PNG, TIFF and
    /// WebP can, and flattening them by default would be a data loss the social
    /// path can afford (it's fitting a photo to a platform) and this one can't
    /// (it's converting a file).
    ///
    /// This is the CONTAINER's capability, not the user's choice — see
    /// `ExportSettings.flattens(for:)`, which is where the two meet.
    var canCarryAlpha: Bool {
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

/// The named quality steps people expect from an export dialog. They set the
/// slider rather than replacing it — the tiers are for choosing quickly, the
/// slider for landing on a specific size once the estimate is on screen.
nonisolated enum QualityTier: String, CaseIterable, Sendable {
    case low, medium, high, best

    var value: Double {
        switch self {
        case .low: 0.5
        case .medium: 0.7
        case .high: 0.85
        case .best: 0.95
        }
    }

    var displayName: String {
        switch self {
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        case .best: String(localized: "Best")
        }
    }

    /// The tier a slider value counts as, so the control can show which one
    /// you're on after dragging. Nil between tiers rather than snapping to the
    /// nearest — claiming "High" at 0.78 would be a lie the number contradicts.
    static func matching(_ value: Double) -> QualityTier? {
        allCases.first { abs($0.value - value) < 0.001 }
    }
}

/// What a transparent pixel becomes. `.transparent` is only honoured by a
/// container that can carry alpha — see `ExportSettings.flattens(for:)`.
nonisolated enum ExportBackground: String, Codable, CaseIterable, Sendable {
    case transparent, white, black

    var displayName: String {
        switch self {
        case .transparent: String(localized: "Transparent")
        case .white: String(localized: "White")
        case .black: String(localized: "Black")
        }
    }
}

/// One export's worth of choices. Codable because a saved preset is exactly
/// this, stored as JSON.
nonisolated struct ExportSettings: Equatable, Codable, Sendable {
    var format: ExportFormat
    var quality: Double
    var tiff16: Bool
    /// WebP only. Lossless is a different ENCODER, not quality = 100 — see
    /// `WebPEncoder.encode`.
    var webpLossless: Bool
    var resize: ExportResize
    var background: ExportBackground
    var includeEXIF: Bool
    var includeLocation: Bool

    init(format: ExportFormat = .jpeg, quality: Double = 0.9, tiff16: Bool = false,
         webpLossless: Bool = false, resize: ExportResize = .original,
         background: ExportBackground = .transparent,
         includeEXIF: Bool = false, includeLocation: Bool = false) {
        self.format = format
        self.quality = quality
        self.tiff16 = tiff16
        self.webpLossless = webpLossless
        self.resize = resize
        self.background = background
        self.includeEXIF = includeEXIF
        self.includeLocation = includeLocation
    }

    /// A preset saved before backgrounds existed decodes with the default
    /// rather than failing — losing a preset because a field was added would be
    /// a worse bug than the field not being there.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(ExportFormat.self, forKey: .format) ?? .jpeg
        quality = try c.decodeIfPresent(Double.self, forKey: .quality) ?? 0.9
        tiff16 = try c.decodeIfPresent(Bool.self, forKey: .tiff16) ?? false
        webpLossless = try c.decodeIfPresent(Bool.self, forKey: .webpLossless) ?? false
        resize = try c.decodeIfPresent(ExportResize.self, forKey: .resize) ?? .original
        background = try c.decodeIfPresent(ExportBackground.self, forKey: .background) ?? .transparent
        includeEXIF = try c.decodeIfPresent(Bool.self, forKey: .includeEXIF) ?? false
        includeLocation = try c.decodeIfPresent(Bool.self, forKey: .includeLocation) ?? false
    }

    /// Whether this export composites onto an opaque colour. TRUE whenever the
    /// user picked one — and also whenever they picked Transparent for a
    /// container that can't carry it, because a JPEG has to land on something
    /// and silently writing black (what an uncomposited alpha channel gives
    /// you) is the bug this replaces.
    func flattens(for resolved: ExportFormat) -> Bool {
        background != .transparent || resolved.canCarryAlpha == false
    }

    /// The colour it lands on when it does flatten. Transparent-on-a-lossy-
    /// container falls back to white, matching every other app's default.
    func flattenColor(for resolved: ExportFormat) -> ExportBackground {
        background == .transparent ? .white : background
    }
}
