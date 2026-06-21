//
//  SidebarReorderSupport.swift
//  Muse
//
//  Reorder plumbing: frame PreferenceKeys, the in-progress environment flag, and the ReorderContext gesture bundle.
//  Extracted verbatim from SidebarView.swift in the 2026-06-20 code-health
//  refactor (file moves only; `private` types became internal so they can live
//  in their own files). Behavior unchanged.
//

import SwiftUI
import AppKit

// MARK: - Root row frame collection

/// Collects each reorderable root row's frame (in `SidebarView.reorderSpace`) so
/// the reorder drag gesture can map a vertical position to an insertion slot.
struct RootFramePreference: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Reorder-in-progress flag

/// True while a folder reorder drag is in progress. Rows read it to suppress
/// their hover fill (and grip) so passing the dragged row over them doesn't light
/// each one up. Propagated via the environment so every nested row sees it.
struct SidebarReorderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var sidebarReordering: Bool {
        get { self[SidebarReorderingKey.self] }
        set { self[SidebarReorderingKey.self] = newValue }
    }
}

// MARK: - Reorder gesture context

/// Reorder drag handlers for a reorderable top-level folder's grip. The grip's
/// DragGesture forwards to these; SidebarView updates the lift offset + insertion
/// slot and commits the move (a live gesture — no pasteboard drag image).
struct ReorderContext {
    let onChanged: (DragGesture.Value) -> Void
    let onEnded: (DragGesture.Value) -> Void
}

// MARK: - Collection row frame collection

/// Collects each collection row's frame (in `SidebarView.reorderSpace`) so the
/// collection reorder drag can map a vertical position to an insertion slot.
struct CollectionFramePreference: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

