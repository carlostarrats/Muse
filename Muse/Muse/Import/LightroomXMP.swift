//
//  LightroomXMP.swift
//  Muse
//
//  Adobe's `crs:` namespace, read from the same `CGImageMetadata` the keyword
//  reader already opened (zero extra I/O).
//
//  THE IMPORT ENVELOPE IS THE ENUMERATED FIELD LIST BELOW. It is the industry
//  envelope — darktable skips the adaptive operators entirely, Capture One
//  approximates about six global sliders, Luminar disclaims visible
//  differences. Matching that is defensible; exceeding it is not, because
//  Highlights/Shadows/Whites/Blacks/Clarity/Dehaze are IMAGE-DEPENDENT
//  operators whose Adobe implementation is unpublished — "translating" them
//  produces a picture that is confidently wrong.
//
//  Those fields are still PARSE-DETECTED, so the report can say plainly what
//  didn't come across. `unsupported` is a closed, enumerated set — never an
//  open-ended "everything we saw" bag.
//
//  This list may not grow without a change to
//  docs/new-build/muse-photo-foundation.md first.
//

import Foundation
import CoreGraphics
import ImageIO

nonisolated struct LightroomEdits: Equatable, Sendable {
    var hasCrop = false
    var cropLeft: Double?
    var cropTop: Double?
    var cropRight: Double?
    var cropBottom: Double?
    var cropAngle: Double?
    var orientation: Int?
    /// RAW workflow: an absolute target Kelvin + tint.
    var temperatureKelvin: Double?
    var tint: Double?
    /// Encoded (JPEG/TIFF/…) workflow: relative −100…+100 offsets.
    var incrementalTemperature: Double?
    var incrementalTint: Double?
    var exposure2012: Double?
    var contrast2012: Double?
    var vibrance: Double?
    var saturation: Double?
    var toneCurvePV2012: [CGPoint] = []
    var toneCurveRed: [CGPoint] = []
    var toneCurveGreen: [CGPoint] = []
    var toneCurveBlue: [CGPoint] = []
    /// Display names of everything detected but deliberately not translated.
    var unsupported: Set<String> = []
    /// Preset name (`crs:Name`), used only by the preset importer.
    var presetName: String?

    var isEmpty: Bool {
        !hasCrop && orientation == nil && exposure2012 == nil && contrast2012 == nil
            && vibrance == nil && saturation == nil && toneCurvePV2012.isEmpty
            && toneCurveRed.isEmpty && toneCurveGreen.isEmpty && toneCurveBlue.isEmpty
            && incrementalTemperature == nil && incrementalTint == nil
            && temperatureKelvin == nil
    }
}

nonisolated enum LightroomXMP {

    /// The closed unsupported list: XMP key → the name shown in the report.
    /// Adding a row here means Muse detects one more thing it won't translate;
    /// it never means Muse translates one more thing.
    static let unsupportedFields: [(key: String, display: String)] = [
        ("Highlights2012", "Highlights"),
        ("Shadows2012", "Shadows"),
        ("Whites2012", "Whites"),
        ("Blacks2012", "Blacks"),
        ("Clarity2012", "Clarity"),
        ("Texture", "Texture"),
        ("Dehaze", "Dehaze"),
        ("GrainAmount", "Grain"),
        ("PostCropVignetteAmount", "Post-crop vignette"),
    ]

    static let legacyProcessVersionNote = "Legacy process version"
    static let localAdjustmentsNote = "Local adjustments"
    static let retouchNote = "Retouching"
    static let profileLookNote = "Profile / look"

    static func read(_ meta: CGImageMetadata) -> LightroomEdits {
        var out = LightroomEdits()

        // Geometry — the only EXACT part of the envelope (pure geometry has no
        // Adobe base look mixed into it).
        out.cropLeft = double(meta, "crs:CropLeft")
        out.cropTop = double(meta, "crs:CropTop")
        out.cropRight = double(meta, "crs:CropRight")
        out.cropBottom = double(meta, "crs:CropBottom")
        out.cropAngle = double(meta, "crs:CropAngle")
        out.hasCrop = (bool(meta, "crs:HasCrop") ?? false)
            || (out.cropLeft != nil && out.cropRight != nil)
        out.orientation = int(meta, "tiff:Orientation") ?? int(meta, "crs:Orientation")

        // White balance — two mutually-exclusive workflows.
        out.temperatureKelvin = double(meta, "crs:Temperature")
        out.tint = double(meta, "crs:Tint")
        out.incrementalTemperature = double(meta, "crs:IncrementalTemperature")
        out.incrementalTint = double(meta, "crs:IncrementalTint")

        // Tone/color — the four directional sliders.
        out.exposure2012 = double(meta, "crs:Exposure2012")
        out.contrast2012 = double(meta, "crs:Contrast2012")
        out.vibrance = double(meta, "crs:Vibrance")
        out.saturation = double(meta, "crs:Saturation")

        // Curves are portable as curves (with the documented caveat that
        // Lightroom applies them over its own base render).
        out.toneCurvePV2012 = curve(meta, "crs:ToneCurvePV2012")
        out.toneCurveRed = curve(meta, "crs:ToneCurvePV2012Red")
        out.toneCurveGreen = curve(meta, "crs:ToneCurvePV2012Green")
        out.toneCurveBlue = curve(meta, "crs:ToneCurvePV2012Blue")

        out.presetName = string(meta, "crs:Name")

        // Detection only, for the report.
        for field in unsupportedFields {
            guard let value = double(meta, "crs:" + field.key), value != 0 else { continue }
            out.unsupported.insert(field.display)
        }
        if hasAny(meta, "crs:MaskGroupBasedCorrections") || hasAny(meta, "crs:CircularGradientBasedCorrections")
            || hasAny(meta, "crs:GradientBasedCorrections") || hasAny(meta, "crs:PaintBasedCorrections") {
            out.unsupported.insert(localAdjustmentsNote)
        }
        if hasAny(meta, "crs:RetouchAreas") || hasAny(meta, "crs:RetouchInfo") {
            out.unsupported.insert(retouchNote)
        }
        if let look = string(meta, "crs:LookName"), !look.isEmpty {
            out.unsupported.insert(profileLookNote)
        }

        // The PV gate is KEY PRESENCE, not `crs:ProcessVersion` parsing: a file
        // whose 2012 keys are absent was developed under an older process whose
        // slider semantics don't map, so it yields geometry only.
        let hasAny2012 = out.exposure2012 != nil || out.contrast2012 != nil
            || !out.toneCurvePV2012.isEmpty
        if !hasAny2012, tag(meta, "crs:ProcessVersion") != nil {
            out.unsupported.insert(legacyProcessVersionNote)
        }
        return out
    }

    // MARK: - Tag access

    private static func tag(_ meta: CGImageMetadata, _ path: String) -> CGImageMetadataTag? {
        CGImageMetadataCopyTagWithPath(meta, nil, path as CFString)
    }

    private static func value(_ meta: CGImageMetadata, _ path: String) -> Any? {
        guard let tag = tag(meta, path) else { return nil }
        return CGImageMetadataTagCopyValue(tag)
    }

    /// Lightroom writes signed decimals as "+0.85" — `Double("+0.85")` handles
    /// the leading plus, but a stray "%" or whitespace does not, so trim first.
    static func parseNumber(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    private static func double(_ meta: CGImageMetadata, _ path: String) -> Double? {
        switch value(meta, path) {
        case let s as String: return parseNumber(s)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }

    private static func int(_ meta: CGImageMetadata, _ path: String) -> Int? {
        double(meta, path).map { Int($0.rounded()) }
    }

    private static func bool(_ meta: CGImageMetadata, _ path: String) -> Bool? {
        switch value(meta, path) {
        case let s as String:
            let lowered = s.lowercased()
            if lowered == "true" { return true }
            if lowered == "false" { return false }
            return nil
        case let n as NSNumber: return n.boolValue
        default: return nil
        }
    }

    private static func string(_ meta: CGImageMetadata, _ path: String) -> String? {
        switch value(meta, path) {
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        case let items as [Any]:
            // An Alt/Seq array: take the first entry (same shape as dc:title).
            for item in items {
                let ref = item as CFTypeRef
                if CFGetTypeID(ref) == CGImageMetadataTagGetTypeID() {
                    let itemTag = unsafeDowncast(ref as AnyObject, to: CGImageMetadataTag.self)
                    if let s = CGImageMetadataTagCopyValue(itemTag) as? String,
                       !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return s.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } else if let s = item as? String,
                          !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return s.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return nil
        default: return nil
        }
    }

    private static func hasAny(_ meta: CGImageMetadata, _ path: String) -> Bool {
        guard let raw = value(meta, path) else { return false }
        if let items = raw as? [Any] { return !items.isEmpty }
        if let s = raw as? String { return !s.isEmpty }
        return true
    }

    /// `crs:ToneCurvePV2012` is a Seq of "x, y" strings in 0…255.
    private static func curve(_ meta: CGImageMetadata, _ path: String) -> [CGPoint] {
        guard let raw = value(meta, path) else { return [] }
        let strings: [String]
        if let items = raw as? [Any] {
            strings = items.compactMap { item in
                let ref = item as CFTypeRef
                if CFGetTypeID(ref) == CGImageMetadataTagGetTypeID() {
                    let itemTag = unsafeDowncast(ref as AnyObject, to: CGImageMetadataTag.self)
                    return CGImageMetadataTagCopyValue(itemTag) as? String
                }
                return item as? String
            }
        } else if let single = raw as? String {
            strings = [single]
        } else {
            return []
        }
        return strings.compactMap { entry in
            let parts = entry.split(separator: ",").map(String.init)
            guard parts.count == 2,
                  let x = parseNumber(parts[0]), let y = parseNumber(parts[1]) else { return nil }
            return CGPoint(x: x, y: y)
        }
    }
}
