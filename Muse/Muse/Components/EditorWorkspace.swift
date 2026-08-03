//
//  EditorWorkspace.swift
//  Muse
//
//  The editor's panel layout, as a value.
//
//  The twelve control cards used to be two hard-coded @ViewBuilder lists in
//  EditorView — which cards, in what order, on which side, was source code. This
//  is the model behind them: an ordered list per column plus the set the user
//  has hidden.
//
//  SINGLE COLUMN IS NOT A MODE. It is the state where one column's list is
//  empty. A "Single Column" menu toggle was designed and rejected: restoring
//  "your last two-column arrangement" on uncheck forces two arrangements to
//  exist at once, one of them always invisible to the user, plus rules for
//  which one a reset applies to. See the spec's §9.
//
//  INVARIANT: every module appears exactly once across `left + right`,
//  INCLUDING hidden ones. Hiding is a flag, not a removal, so position and
//  visibility are independent facts and unhiding returns a card to where it
//  was rather than to the bottom. Every mutating operation here preserves it,
//  and `init(dto:)` repairs a stored workspace that violates it.
//
//  Pure: no SwiftUI, no state, no I/O. Joins GridSelection, MasonryGeometry,
//  ReorderMath and CropDragMath.
//

import Foundation

enum EditorColumn: String, Codable, Sendable, CaseIterable {
    case left, right

    var other: EditorColumn { self == .left ? .right : .left }
}

/// One control card. Raw values are the ids `EditorView.Section` already uses
/// and `AppSettings.editorExpandedSections` already persists — one identity per
/// card, so a card's open/closed state and its position can never disagree
/// about which card they mean.
enum EditorModule: String, CaseIterable, Codable, Identifiable, Sendable {
    case tools, histogram, insights, history
    case looks, light, zones, color, hsl, splitTone, effects, crop

    var id: String { rawValue }

    /// Where this card lives in the default layout. A module added in a later
    /// build with no stored position is appended to the bottom of its home
    /// column — see `EditorWorkspace.init(dto:)`.
    var homeColumn: EditorColumn {
        switch self {
        case .tools, .histogram, .insights, .history: .left
        case .looks, .light, .zones, .color, .hsl, .splitTone, .effects, .crop: .right
        }
    }

    /// Position within `homeColumn` in the default layout.
    var homeIndex: Int {
        switch self {
        case .tools: 0
        case .histogram: 1
        case .insights: 2
        case .history: 3
        case .looks: 0
        case .light: 1
        case .zones: 2
        case .color: 3
        case .hsl: 4
        case .splitTone: 5
        case .effects: 6
        case .crop: 7
        }
    }

    /// The card's heading — the same string the panel draws, so the Customize
    /// list names cards the way the user sees them. Hand-wrapped because an
    /// enum property is not a SwiftUI text-literal position and would
    /// otherwise ship in English.
    var title: String {
        switch self {
        case .tools: String(localized: "TOOLS")
        case .histogram: String(localized: "HISTOGRAM")
        case .insights: String(localized: "INSIGHTS")
        case .history: String(localized: "SNAPSHOTS")
        case .looks: String(localized: "STYLES")
        case .light: String(localized: "LIGHT")
        case .zones: String(localized: "TONE ZONES")
        case .color: String(localized: "COLOR")
        case .hsl: String(localized: "COLOR MIX")
        case .splitTone: String(localized: "SPLIT TONE")
        case .effects: String(localized: "EFFECTS")
        case .crop: String(localized: "CROP & STRAIGHTEN")
        }
    }
}

struct EditorWorkspace: Equatable, Sendable {
    var left: [EditorModule]
    var right: [EditorModule]
    var hidden: Set<EditorModule>

    /// The factory layout: two columns, home order, nothing hidden. What
    /// View ▸ Editor Workspace ▸ Default Layout restores.
    static let standard = EditorWorkspace(
        left: EditorModule.allCases
            .filter { $0.homeColumn == .left }
            .sorted { $0.homeIndex < $1.homeIndex },
        right: EditorModule.allCases
            .filter { $0.homeColumn == .right }
            .sorted { $0.homeIndex < $1.homeIndex },
        hidden: [])

    // MARK: - Reading

    func modules(in column: EditorColumn) -> [EditorModule] {
        column == .left ? left : right
    }

    /// What the panel actually draws.
    func visible(in column: EditorColumn) -> [EditorModule] {
        modules(in: column).filter { !hidden.contains($0) }
    }

    var visibleCount: Int { EditorModule.allCases.count - hidden.count }

    func column(of module: EditorModule) -> EditorColumn? {
        if left.contains(module) { return .left }
        if right.contains(module) { return .right }
        return nil
    }

    /// True when a column draws nothing — what the canvas geometry reads to
    /// give the photo that side's space back. Measured on the VISIBLE modules:
    /// a column holding only hidden cards is an empty column on screen.
    func isEmpty(_ column: EditorColumn) -> Bool { visible(in: column).isEmpty }

    // MARK: - Mutating

    /// Move `module` into `column` at `visibleSlot` — a slot among that
    /// column's VISIBLE modules (0...count), which is what a drag can produce,
    /// since reorder mode only ever draws the visible ones.
    ///
    /// Hidden modules keep their array positions, so an insertion lands just
    /// before the slot-th visible module rather than at a raw array index that
    /// would drift every time something was hidden.
    mutating func move(_ module: EditorModule, toColumn column: EditorColumn,
                       visibleSlot slot: Int) {
        left.removeAll { $0 == module }
        right.removeAll { $0 == module }

        var target = modules(in: column)
        let visibleTargets = target.filter { !hidden.contains($0) }
        let insertAt: Int
        if slot >= visibleTargets.count {
            insertAt = target.count
        } else {
            insertAt = target.firstIndex(of: visibleTargets[max(0, slot)]) ?? target.count
        }
        target.insert(module, at: insertAt)
        write(target, to: column)
    }

    /// Everything to one side, in READING ORDER — the left column's list first,
    /// then the right's, whichever column receives. So All Right gives
    /// TOOLS · HISTOGRAM · … · STYLES · LIGHT · …, matching the single-column
    /// layout the design approved, and All Left gives the same sequence on the
    /// other side. Hidden modules travel too: they keep their flag and their
    /// place in the order, so unhiding one later still lands it sensibly.
    mutating func moveAll(to column: EditorColumn) {
        let merged = left + right
        write(merged, to: column)
        write([], to: column.other)
    }

    /// The last visible module CANNOT be hidden. An editor with no controls,
    /// recoverable only through the menu bar, is a trap — and "show me only the
    /// photo" is already the hide-UI eye's job, done reversibly.
    mutating func setHidden(_ module: EditorModule, _ shouldHide: Bool) {
        if shouldHide {
            guard visibleCount > 1, !hidden.contains(module) else { return }
            hidden.insert(module)
        } else {
            hidden.remove(module)
        }
    }

    private mutating func write(_ modules: [EditorModule], to column: EditorColumn) {
        if column == .left { left = modules } else { right = modules }
    }
}

// MARK: - Storage

/// The on-disk shape. Plain strings, so an id written by a newer build (or one
/// removed by a later one) cannot fail the decode of the WHOLE workspace and
/// throw away a layout the user built. Repair happens in `init(dto:)`.
struct EditorWorkspaceDTO: Codable, Sendable {
    var left: [String]
    var right: [String]
    var hidden: [String]

    init(left: [String], right: [String], hidden: [String]) {
        self.left = left
        self.right = right
        self.hidden = hidden
    }

    init(_ workspace: EditorWorkspace) {
        left = workspace.left.map(\.rawValue)
        right = workspace.right.map(\.rawValue)
        // Sorted so the encoded bytes are stable across launches — an
        // unordered Set would rewrite the preference on every save.
        hidden = workspace.hidden.map(\.rawValue).sorted()
    }
}

extension EditorWorkspace {
    /// Load a stored workspace, repairing the three ways it can disagree with
    /// the running build:
    ///
    /// 1. An UNKNOWN id (a card this build no longer has) is dropped, and the
    ///    rest of the workspace still loads.
    /// 2. A MISSING module (a card this build added) is appended to the bottom
    ///    of its home column, VISIBLE. Never hidden by omission — otherwise
    ///    anyone who had ever opened Customize would silently stop receiving
    ///    new features.
    /// 3. A DUPLICATE id keeps its first occurrence, so the every-module-once
    ///    invariant holds whatever was on disk.
    ///
    /// Plus one safety repair: a workspace with EVERY module hidden is not
    /// reachable through the modal, but a hand-edited or older preferences file
    /// can arrive that way, and it would leave an editor with no controls.
    init(dto: EditorWorkspaceDTO) {
        var seen: Set<EditorModule> = []
        func clean(_ ids: [String]) -> [EditorModule] {
            ids.compactMap { EditorModule(rawValue: $0) }
                .filter { seen.insert($0).inserted }
        }
        var left = clean(dto.left)
        var right = clean(dto.right)

        // Anything this build knows about that the file didn't mention.
        for module in EditorModule.allCases where !seen.contains(module) {
            if module.homeColumn == .left { left.append(module) } else { right.append(module) }
        }

        var hidden = Set(dto.hidden.compactMap { EditorModule(rawValue: $0) })
        if hidden.count >= EditorModule.allCases.count { hidden = [] }

        self.init(left: left, right: right, hidden: hidden)
    }
}
