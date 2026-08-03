//
//  EditStack.swift
//  Muse
//
//  The non-destructive edit model. A stack is a DECLARATIVE description of
//  what to do to the original pixels — never pixels, never a reference to a
//  preset, never a click location. It is stored per (file_id, parent_dir)
//  (the tags/notes grain) and mirrored into iCloud sidecars.
//
//  Platform-neutral by rule: this whole folder imports Foundation /
//  CoreGraphics / CoreImage / Metal ONLY, never AppKit
//  (`EditingModuleImportTests` is the enforcement).
//
//  Two invariants that everything downstream leans on:
//
//  1. `Adjustment`'s DECLARATION ORDER is the canonical order, and new cases
//     must always APPEND. `normalized()` sorts by it and drops duplicate
//     cases (last wins), so the canonical JSON bytes — and therefore
//     `stack_hash` — are stable for a given set of parameters. Inserting a
//     case mid-list re-keys every edited thumbnail in every library.
//  2. The RENDERER iterates its OWN fixed chain (`EditRenderer.apply`), never
//     this array's order. Reorderability is deliberately unrepresentable.
//

import Foundation
import CoreGraphics

// MARK: - Provenance

/// Where a stack came from, when it wasn't the user. Lives here rather than
/// beside the importer so `Editing/` stays self-contained (the module-import
/// rule) and an older build can still decode the key away.
nonisolated enum EditOrigin: String, Codable, Sendable {
    case lightroom
}

// MARK: - Stack

nonisolated struct EditStack: Codable, Equatable, Sendable {
    /// Bumped only when the JSON SHAPE changes incompatibly. A stack whose
    /// schemaVersion exceeds ours fails to decode (renders as the original).
    var schemaVersion: Int
    /// Bumped only when the same parameters would produce different PIXELS.
    /// A stack beyond our processVersion still DECODES (so it round-trips
    /// untouched) but `EditRenderer.canRender` is false — the original renders.
    var processVersion: Int
    /// Only what has no encoded-source equivalent. WB/NR/sharpen live in
    /// ColorParams/PresenceParams and are ROUTED per source kind by the
    /// renderer, so copy/paste works across RAW↔JPEG with one model.
    var rawParams: RawParams?
    var adjustments: [Adjustment]
    /// Always `[]` in v1 — a reserved slot that round-trips in the JSON shape
    /// from day one, so adding masks later isn't a schema break.
    var masks: [Mask]
    /// Where this stack came from, when it wasn't the user (Spec 06). It is
    /// PROVENANCE, not data:
    ///
    ///  - nil-omitted by synthesized `Codable`, so every pre-existing stack's
    ///    canonical bytes — and therefore `stack_hash` — are byte-identical.
    ///    `EditStackCodecTests`' pinned hash is the tripwire.
    ///  - never copied by `EditTransfer.apply` (the target keeps its own),
    ///  - stripped at preset save,
    ///  - gone on Reset (a reset writes a fresh neutral stack, which deletes
    ///    the row entirely).
    ///  - an older build decodes it away harmlessly (unknown keys are ignored).
    var origin: EditOrigin?

    static let currentSchemaVersion = 1
    static let currentProcessVersion = 1

    /// The ONLY constructor that stamps the current versions. Decoding must
    /// never bump them (an older stack stays byte-identical on disk).
    static func fresh() -> EditStack {
        EditStack(schemaVersion: currentSchemaVersion,
                  processVersion: currentProcessVersion,
                  rawParams: nil, adjustments: [], masks: [], origin: nil)
    }

    /// True when this stack would render the original pixels. A neutral stack
    /// is stored as the ABSENCE of a row, never as a no-op blob.
    var isNeutral: Bool {
        adjustments.allSatisfy { $0.isNeutralCase } && (rawParams?.isNeutral ?? true)
    }

    /// Canonical form: at most one adjustment per case, in declaration order,
    /// last occurrence winning. Applied on decode and before encode/hash.
    func normalized() -> EditStack {
        var seen: [Int: Adjustment] = [:]
        for adj in adjustments {
            seen[adj.canonicalIndex] = adj
        }
        var copy = self
        copy.adjustments = seen.keys.sorted().compactMap { seen[$0] }
        return copy
    }
}

// MARK: - Typed accessors / mutators

// `nonisolated`: pure reads/writes over the stack's own value storage. The
// render chain, the thumbnail workers and `EditStackIndex` all reach these
// off-main, and `EditStack` itself is already nonisolated.
nonisolated extension EditStack {
    var toneParams: ToneParams? {
        for case .tone(let p) in adjustments { return p }
        return nil
    }
    var colorParams: ColorParams? {
        for case .color(let p) in adjustments { return p }
        return nil
    }
    var presenceParams: PresenceParams? {
        for case .presence(let p) in adjustments { return p }
        return nil
    }
    var curveParams: CurveParams? {
        for case .curve(let p) in adjustments { return p }
        return nil
    }
    var geometryParams: GeometryParams? {
        for case .geometry(let p) in adjustments { return p }
        return nil
    }
    var vignetteParams: VignetteParams? {
        for case .vignette(let p) in adjustments { return p }
        return nil
    }
    var toneZoneParams: ToneZoneParams? {
        for case .toneZone(let p) in adjustments { return p }
        return nil
    }
    var lutParams: LutParams? {
        for case .lut(let p) in adjustments { return p }
        return nil
    }
    var hslParams: HSLParams? {
        for case .hsl(let p) in adjustments { return p }
        return nil
    }
    var splitToneParams: SplitToneParams? {
        for case .splitTone(let p) in adjustments { return p }
        return nil
    }
    var grainParams: GrainParams? {
        for case .grain(let p) in adjustments { return p }
        return nil
    }

    /// Find-or-insert the matching case, mutate it, write it back. The editor
    /// binds sliders through these, so a first non-neutral write creates the
    /// case and a return to neutral leaves it present-but-neutral (`isNeutral`
    /// is what decides whether anything is stored at all).
    mutating func setTone(_ mutate: (inout ToneParams) -> Void) {
        var p = toneParams ?? .neutral
        mutate(&p)
        replace(.tone(p))
    }
    mutating func setColor(_ mutate: (inout ColorParams) -> Void) {
        var p = colorParams ?? .neutral
        mutate(&p)
        replace(.color(p))
    }
    mutating func setPresence(_ mutate: (inout PresenceParams) -> Void) {
        var p = presenceParams ?? .neutral
        mutate(&p)
        replace(.presence(p))
    }
    mutating func setCurve(_ mutate: (inout CurveParams) -> Void) {
        var p = curveParams ?? .neutral
        mutate(&p)
        replace(.curve(p))
    }
    mutating func setGeometry(_ mutate: (inout GeometryParams) -> Void) {
        var p = geometryParams ?? .neutral
        mutate(&p)
        replace(.geometry(p))
    }
    mutating func setVignette(_ mutate: (inout VignetteParams) -> Void) {
        var p = vignetteParams ?? .neutral
        mutate(&p)
        replace(.vignette(p))
    }
    mutating func setToneZone(_ mutate: (inout ToneZoneParams) -> Void) {
        var p = toneZoneParams ?? .neutral
        mutate(&p)
        replace(.toneZone(p))
    }
    /// Writes (or clears) the single `lut` case. Passing nil REMOVES it —
    /// a stack carries at most one LUT and "no LUT" is the absence of the case,
    /// not a zero-strength one left behind for the codec to encode.
    mutating func setLut(_ params: LutParams?) {
        adjustments.removeAll { if case .lut = $0 { true } else { false } }
        if let params {
            adjustments.append(.lut(params))
            adjustments.sort { $0.canonicalIndex < $1.canonicalIndex }
        }
    }
    mutating func setHSL(_ mutate: (inout HSLParams) -> Void) {
        var p = hslParams ?? .neutral
        mutate(&p)
        replace(.hsl(p))
    }
    mutating func setSplitTone(_ mutate: (inout SplitToneParams) -> Void) {
        var p = splitToneParams ?? .neutral
        mutate(&p)
        replace(.splitTone(p))
    }
    mutating func setGrain(_ mutate: (inout GrainParams) -> Void) {
        var p = grainParams ?? .neutral
        mutate(&p)
        replace(.grain(p))
    }
    mutating func setRaw(_ mutate: (inout RawParams) -> Void) {
        var p = rawParams ?? .neutral
        mutate(&p)
        rawParams = p
    }

    private mutating func replace(_ adj: Adjustment) {
        if let i = adjustments.firstIndex(where: { $0.canonicalIndex == adj.canonicalIndex }) {
            adjustments[i] = adj
        } else {
            adjustments.append(adj)
            adjustments.sort { $0.canonicalIndex < $1.canonicalIndex }
        }
    }
}

// MARK: - Masks (reserved)

/// v1 carries no masks; the type exists so the JSON shape is stable.
nonisolated struct Mask: Codable, Equatable, Sendable {
    var id: String
    var kind: String
}

// MARK: - Adjustment

nonisolated enum Adjustment: Equatable, Sendable {
    case tone(ToneParams)
    case color(ColorParams)
    case presence(PresenceParams)
    case curve(CurveParams)
    case geometry(GeometryParams)
    case vignette(VignetteParams)
    // Spec 05 — APPENDED after vignette. Inserting either of these mid-list
    // would re-key every pre-existing edited thumbnail's `stack_hash`.
    case toneZone(ToneZoneParams)
    case lut(LutParams)
    // Stage B — APPENDED after lut, same rule.
    case hsl(HSLParams)
    case splitTone(SplitToneParams)
    case grain(GrainParams)

    /// Declaration order. NEW CASES APPEND — never insert.
    var canonicalIndex: Int {
        switch self {
        case .tone: 0
        case .color: 1
        case .presence: 2
        case .curve: 3
        case .geometry: 4
        case .vignette: 5
        case .toneZone: 6
        case .lut: 7
        case .hsl: 8
        case .splitTone: 9
        case .grain: 10
        }
    }

    var isNeutralCase: Bool {
        switch self {
        case .tone(let p): p.isNeutral
        case .color(let p): p.isNeutral
        case .presence(let p): p.isNeutral
        case .curve(let p): p.isNeutral
        case .geometry(let p): p.isNeutral
        case .vignette(let p): p.isNeutral
        case .toneZone(let p): p.isNeutral
        case .lut(let p): p.isNeutral
        case .hsl(let p): p.isNeutral
        case .splitTone(let p): p.isNeutral
        case .grain(let p): p.isNeutral
        }
    }
}

extension Adjustment: Codable {
    private enum CodingKeys: String, CodingKey { case type, params }
    private enum Kind: String, Codable {
        case tone, color, presence, curve, geometry, vignette, toneZone, lut
        case hsl, splitTone, grain
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown `type` throws here, failing the WHOLE stack decode —
        // deliberately. That is the forward-compatibility mechanism: an older
        // build renders a new-case stack as the ORIGINAL, blob preserved,
        // detectably. It must never silently drop the unknown case and render
        // a partial stack.
        switch try c.decode(Kind.self, forKey: .type) {
        case .tone: self = .tone(try c.decode(ToneParams.self, forKey: .params))
        case .color: self = .color(try c.decode(ColorParams.self, forKey: .params))
        case .presence: self = .presence(try c.decode(PresenceParams.self, forKey: .params))
        case .curve: self = .curve(try c.decode(CurveParams.self, forKey: .params))
        case .geometry: self = .geometry(try c.decode(GeometryParams.self, forKey: .params))
        case .vignette: self = .vignette(try c.decode(VignetteParams.self, forKey: .params))
        case .toneZone: self = .toneZone(try c.decode(ToneZoneParams.self, forKey: .params))
        case .lut: self = .lut(try c.decode(LutParams.self, forKey: .params))
        case .hsl: self = .hsl(try c.decode(HSLParams.self, forKey: .params))
        case .splitTone: self = .splitTone(try c.decode(SplitToneParams.self, forKey: .params))
        case .grain: self = .grain(try c.decode(GrainParams.self, forKey: .params))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tone(let p):
            try c.encode(Kind.tone, forKey: .type); try c.encode(p, forKey: .params)
        case .color(let p):
            try c.encode(Kind.color, forKey: .type); try c.encode(p, forKey: .params)
        case .presence(let p):
            try c.encode(Kind.presence, forKey: .type); try c.encode(p, forKey: .params)
        case .curve(let p):
            try c.encode(Kind.curve, forKey: .type); try c.encode(p, forKey: .params)
        case .geometry(let p):
            try c.encode(Kind.geometry, forKey: .type); try c.encode(p, forKey: .params)
        case .vignette(let p):
            try c.encode(Kind.vignette, forKey: .type); try c.encode(p, forKey: .params)
        case .toneZone(let p):
            try c.encode(Kind.toneZone, forKey: .type); try c.encode(p, forKey: .params)
        case .lut(let p):
            try c.encode(Kind.lut, forKey: .type); try c.encode(p, forKey: .params)
        case .hsl(let p):
            try c.encode(Kind.hsl, forKey: .type); try c.encode(p, forKey: .params)
        case .splitTone(let p):
            try c.encode(Kind.splitTone, forKey: .type); try c.encode(p, forKey: .params)
        case .grain(let p):
            try c.encode(Kind.grain, forKey: .type); try c.encode(p, forKey: .params)
        }
    }
}

// MARK: - Params

/// Exposure is stored in REAL EV; every other scalar in this file is a
/// normalized −1…+1 (or 0…1) slider value the renderer maps to its own units.
nonisolated struct ToneParams: Codable, Equatable, Sendable {
    var exposureEV: Double = 0        // −5…+5
    var contrast: Double = 0          // −1…+1
    var highlights: Double = 0        // −1…+1
    var shadows: Double = 0           // −1…+1
    var whites: Double = 0            // −1…+1
    var blacks: Double = 0            // −1…+1

    static let neutral = ToneParams()
    static let exposureRange: ClosedRange<Double> = -5...5

    var isNeutral: Bool { self == .neutral }

    func clamped() -> ToneParams {
        ToneParams(exposureEV: min(max(exposureEV, -5), 5),
                   contrast: unitClamp(contrast),
                   highlights: unitClamp(highlights),
                   shadows: unitClamp(shadows),
                   whites: unitClamp(whites),
                   blacks: unitClamp(blacks))
    }
}

/// Temperature/tint are slider values, mapped in MIRED (never raw Kelvin) by
/// `MiredMapping`, and routed to `CIRAWFilter` at demosaic for RAW sources.
nonisolated struct ColorParams: Codable, Equatable, Sendable {
    var temperature: Double = 0       // −1…+1 (positive = warmer)
    var tint: Double = 0              // −1…+1 (positive = magenta)
    var vibrance: Double = 0          // −1…+1
    var saturation: Double = 0        // −1…+1

    static let neutral = ColorParams()

    var isNeutral: Bool { self == .neutral }

    func clamped() -> ColorParams {
        ColorParams(temperature: unitClamp(temperature), tint: unitClamp(tint),
                    vibrance: unitClamp(vibrance), saturation: unitClamp(saturation))
    }
}

nonisolated struct PresenceParams: Codable, Equatable, Sendable {
    var clarity: Double = 0           // −1…+1
    var texture: Double = 0           // −1…+1
    var sharpen: Double = 0           // 0…1
    var noiseReduction: Double = 0    // 0…1

    static let neutral = PresenceParams()

    var isNeutral: Bool { self == .neutral }

    func clamped() -> PresenceParams {
        PresenceParams(clarity: unitClamp(clarity), texture: unitClamp(texture),
                       sharpen: min(max(sharpen, 0), 1),
                       noiseReduction: min(max(noiseReduction, 0), 1))
    }
}

/// The deliberate display-referred exception in an otherwise scene-referred
/// chain. Points are strictly increasing in x; `CurveLUT` does not re-sort.
nonisolated struct CurveParams: Codable, Equatable, Sendable {
    nonisolated struct Point: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    var rgb: [Point] = []
    var red: [Point] = []
    var green: [Point] = []
    var blue: [Point] = []

    static let neutral = CurveParams()
    static let maxPoints = 16

    var isNeutral: Bool { self == .neutral }

    func clamped() -> CurveParams {
        CurveParams(rgb: Self.clampChannel(rgb), red: Self.clampChannel(red),
                    green: Self.clampChannel(green), blue: Self.clampChannel(blue))
    }

    private static func clampChannel(_ pts: [Point]) -> [Point] {
        Array(pts.map { Point(x: min(max($0.x, 0), 1), y: min(max($0.y, 0), 1)) }
                 .sorted { $0.x < $1.x }
                 .prefix(maxPoints))
    }
}

/// A normalized unit rect in display-oriented, straightened coordinates.
nonisolated struct CropRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
    static let full = CropRect(x: 0, y: 0, w: 1, h: 1)
    var isFull: Bool { self == .full }
}

nonisolated struct GeometryParams: Codable, Equatable, Sendable {
    var crop: CropRect?
    var quarterTurns: Int = 0         // 0…3, clockwise
    var flipH: Bool = false
    var flipV: Bool = false
    var straightenDegrees: Double = 0 // −45…+45

    static let neutral = GeometryParams()

    var isNeutral: Bool {
        (crop == nil || crop!.isFull) && quarterTurns % 4 == 0
            && !flipH && !flipV && straightenDegrees == 0
    }

    func clamped() -> GeometryParams {
        GeometryParams(crop: crop, quarterTurns: ((quarterTurns % 4) + 4) % 4,
                       flipH: flipH, flipV: flipV,
                       straightenDegrees: min(max(straightenDegrees, -45), 45))
    }

    /// The pure post-geometry size layout consumes (`EffectiveDimensions` →
    /// grid aspect, hero flight, the Info card). Crop first, then quarter
    /// turns; flips never change size, and straighten is applied inside the
    /// crop so it doesn't either.
    func appliedDisplaySize(to source: CGSize) -> CGSize {
        var size = source
        if let crop, !crop.isFull {
            size = CGSize(width: size.width * crop.w, height: size.height * crop.h)
        }
        if ((quarterTurns % 4) + 4) % 4 % 2 == 1 {
            size = CGSize(width: size.height, height: size.width)
        }
        return size
    }
}

nonisolated struct VignetteParams: Codable, Equatable, Sendable {
    var amount: Double = 0            // −1…+1 (negative darkens)
    var midpoint: Double = 0.5        // 0…1
    var feather: Double = 0.5         // 0…1

    static let neutral = VignetteParams()

    var isNeutral: Bool { amount == 0 }

    func clamped() -> VignetteParams {
        VignetteParams(amount: unitClamp(amount),
                       midpoint: min(max(midpoint, 0), 1),
                       feather: min(max(feather, 0), 1))
    }
}

/// Nine zones, one photographic stop each, covering −8…0 EV relative to
/// diffuse white (darktable's tone-equalizer range). `gains[0]` is the deepest
/// shadows, `gains[8]` the highlights. The EV mapping is renderer-side
/// (`ToneZoneMath.maxZoneEV`), so this struct stores only the −1…+1 slider
/// value — the same shape every other params type uses.
nonisolated struct ToneZoneParams: Codable, Equatable, Sendable {
    static let zoneCount = 9

    var gains: [Double]

    init(gains: [Double]) { self.gains = gains }

    static let neutral = ToneZoneParams(gains: .init(repeating: 0, count: zoneCount))

    var isNeutral: Bool { gains.allSatisfy { $0 == 0 } }

    /// Clamps each gain to −1…+1 and normalizes the array LENGTH: short pads
    /// with 0, long truncates. Decoding deliberately does NOT do this (the
    /// blob round-trips byte-identical); the renderer calls it before use, so
    /// a hand-edited or future-shaped sidecar can't index out of bounds.
    func clamped() -> ToneZoneParams {
        var padded = gains
        if padded.count < Self.zoneCount {
            padded += Array(repeating: 0, count: Self.zoneCount - padded.count)
        } else if padded.count > Self.zoneCount {
            padded = Array(padded.prefix(Self.zoneCount))
        }
        return ToneZoneParams(gains: padded.map { min(max($0, -1), 1) })
    }
}

/// References an `edit_luts` row by CONTENT HASH — never embedded data. A 64³
/// table is ~3 MB, and the stack rides iCloud sidecars and is hashed on every
/// edit. `name` exists only as the display fallback when the row is missing on
/// this device.
nonisolated struct LutParams: Codable, Equatable, Sendable {
    var lutHash: String
    var name: String
    var strength: Double        // 0…1; the UI shows 0–100

    init(lutHash: String, name: String, strength: Double = 1) {
        self.lutHash = lutHash
        self.name = name
        self.strength = strength
    }

    var isNeutral: Bool { strength == 0 }

    func clamped() -> LutParams {
        LutParams(lutHash: lutHash, name: name, strength: min(max(strength, 0), 1))
    }
}

/// Eight fixed hue bands — red, orange, yellow, green, aqua, blue, purple,
/// magenta — Lightroom's model, because it is the one people have already
/// seen. Three parallel arrays rather than eight structs so the renderer hands
/// the kernel three flat runs of floats.
nonisolated struct HSLParams: Codable, Equatable, Sendable {
    static let bandCount = 8

    var hue: [Double]
    var saturation: [Double]
    var luminance: [Double]

    init(hue: [Double], saturation: [Double], luminance: [Double]) {
        self.hue = hue; self.saturation = saturation; self.luminance = luminance
    }

    static let neutral = HSLParams(
        hue: .init(repeating: 0, count: bandCount),
        saturation: .init(repeating: 0, count: bandCount),
        luminance: .init(repeating: 0, count: bandCount))

    var isNeutral: Bool {
        hue.allSatisfy { $0 == 0 } && saturation.allSatisfy { $0 == 0 }
            && luminance.allSatisfy { $0 == 0 }
    }

    /// Clamps range AND normalizes LENGTH, for the same reason `ToneZoneParams`
    /// does: decoding round-trips the blob byte-identically, so a hand-edited
    /// or future-shaped sidecar reaches the renderer and must not index out of
    /// bounds.
    func clamped() -> HSLParams {
        HSLParams(hue: Self.fit(hue), saturation: Self.fit(saturation),
                  luminance: Self.fit(luminance))
    }

    private static func fit(_ a: [Double]) -> [Double] {
        var v = a
        if v.count < bandCount {
            v += Array(repeating: 0, count: bandCount - v.count)
        } else if v.count > bandCount {
            v = Array(v.prefix(bandCount))
        }
        return v.map { min(max($0, -1), 1) }
    }
}

/// Shadow and highlight tinting. Hue is 0…1 around the wheel, saturation 0…1,
/// balance shifts the crossover. Display-referred — the renderer applies it
/// after the curve and the LUT, because that is the encoding the user is
/// judging the grade in.
nonisolated struct SplitToneParams: Codable, Equatable, Sendable {
    var shadowHue: Double = 0
    var shadowSaturation: Double = 0
    var highlightHue: Double = 0
    var highlightSaturation: Double = 0
    var balance: Double = 0           // −1…+1

    static let neutral = SplitToneParams()

    /// A hue with no saturation tints nothing, so it is NOT an edit — opening
    /// the card and sliding a hue must not persist a blob that moves no pixels.
    var isNeutral: Bool { shadowSaturation == 0 && highlightSaturation == 0 }

    func clamped() -> SplitToneParams {
        SplitToneParams(shadowHue: min(max(shadowHue, 0), 1),
                        shadowSaturation: min(max(shadowSaturation, 0), 1),
                        highlightHue: min(max(highlightHue, 0), 1),
                        highlightSaturation: min(max(highlightSaturation, 0), 1),
                        balance: min(max(balance, -1), 1))
    }
}

/// Film grain. `amount` is the only field that makes it real; size and
/// roughness shape a grain that is otherwise absent.
nonisolated struct GrainParams: Codable, Equatable, Sendable {
    var amount: Double = 0            // 0…1
    var size: Double = 0.5            // 0…1
    var roughness: Double = 0.5       // 0…1

    init(amount: Double = 0, size: Double = 0.5, roughness: Double = 0.5) {
        self.amount = amount; self.size = size; self.roughness = roughness
    }

    static let neutral = GrainParams()

    var isNeutral: Bool { amount == 0 }

    func clamped() -> GrainParams {
        GrainParams(amount: min(max(amount, 0), 1),
                    size: min(max(size, 0), 1),
                    roughness: min(max(roughness, 0), 1))
    }

    /// Deterministic per-photo seed. The same photo MUST grain identically at
    /// thumbnail, screen and export — Surface shipped a preview that dropped
    /// grain entirely, and Muse cannot do that because the grid IS the product.
    /// Derived from the content hash, never from time or position alone.
    static func seed(forContentHash hash: String) -> Float {
        Float(SeededRandom.fnv1a([hash]) % 100_000) / 100_000
    }
}

/// Only what has NO encoded-source equivalent. The decoder version is pinned
/// at first edit so a later OS can't silently re-render the same stack
/// differently; when the pinned version is gone it's substituted, not hidden.
nonisolated struct RawParams: Codable, Equatable, Sendable {
    var lensCorrection: Bool = true
    var decoderVersion: String? = nil

    init(lensCorrection: Bool = true, decoderVersion: String? = nil) {
        self.lensCorrection = lensCorrection
        self.decoderVersion = decoderVersion
    }

    static let neutral = RawParams()

    var isNeutral: Bool { lensCorrection == true }
}

// Pure arithmetic, called from every `clamped()` on these nonisolated
// param structs — so it must be nonisolated too.
nonisolated private func unitClamp(_ v: Double) -> Double { min(max(v, -1), 1) }
