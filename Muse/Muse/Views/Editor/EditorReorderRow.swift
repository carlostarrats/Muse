//
//  EditorReorderRow.swift
//  Muse
//
//  One module, while you are rearranging the editor's panels.
//
//  This is NOT an EditorSection with its content hidden — it is a different
//  view entirely. That is what makes "nothing inside a card is reachable"
//  structurally true instead of a list of guards on every slider: there is no
//  inside. It also means `AppSettings.editorExpandedSections` is never written,
//  so every card returns to its previous open/closed state on exit for free.
//
//  The wiggle is the iOS home-screen tell. Without it a panel of collapsed bars
//  reads as broken rather than as a mode.
//

import SwiftUI
import AppKit

struct EditorReorderRow: View {
    let module: EditorModule
    let ink: PanelContrast.Ink
    /// Hidden in place while it is the one being dragged — its slot stays so
    /// the others can part around it, and an opaque copy follows the cursor
    /// instead (see `EditorView.draggedModuleOverlay`), which keeps it above
    /// every bar it passes without per-row zIndex juggling.
    var isDragging: Bool = false
    /// Phase offset so the twelve bars do not wiggle in lockstep, which reads
    /// as one shaking slab rather than twelve loose cards.
    var wigglePhase: Double = 0
    /// The floating copy under the cursor does not wiggle and does not claim
    /// the cursor — it is a picture of a bar, not a bar.
    var isFloatingCopy: Bool = false
    /// Keyboard/VoiceOver equivalents of the drag. Without these the mode is
    /// mouse-only, and the hint below promises a gesture such a user cannot
    /// perform — the same reason `EditorToolRow`'s press-and-hold row carries
    /// an `accessibilityAction`: VoiceOver cannot hold a button down, and it
    /// cannot drag one either.
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
    var onMoveAcross: (() -> Void)? = nil

    /// The bar's height. Public because the drag's parting pitch is derived
    /// from it, and a hard-coded 34 in two places would drift.
    static let height: CGFloat = 34

    @State private var wiggling = false
    @State private var hovering = false
    @State private var pushed = false

    var body: some View {
        HStack(spacing: 8) {
            Text(module.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink.labelText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            // The grab bar takes the ＋/−'s place. There is nothing to expand
            // in this mode, and a disclosure control that did nothing would be
            // a promise the mode does not keep.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink.baseColor.opacity(0.8))
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(ink.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(ink.baseColor.opacity(hovering && !isFloatingCopy ? 0.25 : 0),
                          lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .rotationEffect(.degrees(wiggle))
        .opacity(isDragging ? 0 : 1)
        .onAppear { if !isFloatingCopy { wiggling = true } }
        .onHover { hovering = $0; syncCursor() }
        .onChange(of: isDragging) { _, _ in syncCursor() }
        .onDisappear { clearCursor() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(module.title))
        .accessibilityHint(Text("Drag to move this card, or use the actions. Save or cancel with the buttons over the photo."))
        .accessibilityAction(named: Text("Move Up")) { onMoveUp?() }
        .accessibilityAction(named: Text("Move Down")) { onMoveDown?() }
        .accessibilityAction(named: Text("Move to Other Column")) { onMoveAcross?() }
    }

    /// A small alternating tilt. The floating copy under the cursor holds
    /// still — a wobbling thing pinned to the pointer reads as a glitch.
    private var wiggle: Double {
        guard !isFloatingCopy else { return 0 }
        return wiggling && !isDragging ? 0.7 : -0.7
    }

    // The open-hand / closed-fist discipline the editor already uses for
    // panning. A bare `.set()` is clobbered by AppKit's per-mouse-move cursor
    // recalculation, and mismatched push/pop corrupts the stack for the WHOLE
    // app — so the push is tracked and popped exactly once. The closed fist is
    // pushed by EditorView's gesture, which is the only thing that knows a drag
    // has actually begun.
    private func syncCursor() {
        let want = hovering && !isDragging && !isFloatingCopy
        if want && !pushed {
            pushed = true
            NSCursor.openHand.push()
        } else if !want && pushed {
            pushed = false
            NSCursor.pop()
        }
    }

    private func clearCursor() {
        if pushed { pushed = false; NSCursor.pop() }
    }
}

/// Each module bar's frame in `EditorView.reorderSpace`, so the drag can map a
/// position to a column and an insertion slot. Mirrors the sidebar's
/// `RootFramePreference`.
struct EditorModuleFramePreference: PreferenceKey {
    static let defaultValue: [EditorModule: CGRect] = [:]
    static func reduce(value: inout [EditorModule: CGRect],
                       nextValue: () -> [EditorModule: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
