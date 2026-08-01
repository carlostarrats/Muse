//
//  EditTransfer.swift
//  Muse
//
//  The pure semantics behind copy/paste, batch sync, and presets: which
//  adjustment groups a stack actually touches, and how to graft a subset of
//  one stack's groups onto another.
//
//  Two rules that are easy to get wrong and expensive to get wrong:
//
//  - Apply is COPY-BY-VALUE. Nothing ever stores a reference to a preset or
//    to a source stack, so editing the source afterwards never reaches back
//    into the photos it was applied to.
//  - A group ABSENT (or neutral) in the source CLEARS it in the target. "Paste
//    tone" means "make the target's tone match mine", including when mine is
//    untouched — otherwise pasting a neutral look leaves the target's old
//    values in place and the paste appears to have done nothing.
//

import Foundation

nonisolated enum AdjustmentGroup: String, CaseIterable, Codable, Sendable {
    case tone, color, presence, curve, geometry, vignette, raw
    // Spec 05. `raw` stays where it is — it is not an `Adjustment` case, so
    // its position carries no hashing consequence.
    case toneZone, lut
}

nonisolated enum EditTransfer {
    /// The groups this stack actually changes — the auto-selected default for
    /// the copy picker, so the user sees what they'd expect rather than a wall
    /// of unchecked boxes.
    static func adjustedGroups(of stack: EditStack) -> Set<AdjustmentGroup> {
        var groups = Set<AdjustmentGroup>()
        for adj in stack.adjustments where !adj.isNeutralCase {
            groups.insert(adj.group)
        }
        if let raw = stack.rawParams, !raw.isNeutral { groups.insert(.raw) }
        return groups
    }

    /// Graft `groups` from `source` onto `target`. Never mutates either input
    /// (both are value types); the target's schema/process versions are kept,
    /// since the result is the TARGET's stack with some fields replaced.
    static func apply(groups: Set<AdjustmentGroup>, from source: EditStack,
                      onto target: EditStack) -> EditStack {
        var result = target
        // Drop the target's copy of every transferred group first — that's
        // what makes "absent in source" mean "cleared in target".
        var adjustments = result.adjustments.filter { !groups.contains($0.group) }
        for group in groups where group != .raw {
            if let sourceAdj = source.adjustments.first(where: { $0.group == group }) {
                adjustments.append(sourceAdj)
            }
        }
        result.adjustments = adjustments
        if groups.contains(.raw) {
            result.rawParams = source.rawParams
        }
        result.schemaVersion = target.schemaVersion
        result.processVersion = target.processVersion
        // Origin is PROVENANCE, not an adjustment: pasting a Lightroom-imported
        // look onto your own photo doesn't make your photo's edits Lightroom's.
        // The target keeps whatever it already claimed.
        result.origin = target.origin
        return result.normalized()
    }
}

extension Adjustment {
    var group: AdjustmentGroup {
        switch self {
        case .tone: .tone
        case .color: .color
        case .presence: .presence
        case .curve: .curve
        case .geometry: .geometry
        case .vignette: .vignette
        case .toneZone: .toneZone
        case .lut: .lut
        }
    }
}
