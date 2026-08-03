//
//  EditorReorderBar.swift
//  Muse
//
//  The floating control bar for reorder mode — over the photo near the bottom,
//  clear of both columns.
//
//  Two groups, because they are different kinds of thing: the left pair
//  rearranges, the right three end the mode. Cancel throws away whatever either
//  pair did.
//
//  All Left and All Right both exist because dragging is symmetric: the
//  everything-on-the-left state is reachable by hand whether or not a button
//  offers it, so it needs a rule regardless — and the rule is that the chrome
//  row (zoom, the eye, Share, ✕) is not a module and stays pinned top-right.
//  With that settled, both directions are free.
//

import SwiftUI

struct EditorReorderBar: View {
    let ink: PanelContrast.Ink
    var onAllLeft: () -> Void
    var onAllRight: () -> Void
    var onReset: () -> Void
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            button(String(localized: "All Left"), systemName: "arrow.left.to.line",
                   action: onAllLeft)
            button(String(localized: "All Right"), systemName: "arrow.right.to.line",
                   action: onAllRight)

            Rectangle()
                .fill(ink.baseColor.opacity(0.25))
                .frame(width: 1, height: 18)
                .padding(.horizontal, 2)

            // Order and sides only — the hidden set belongs to Customize, and a
            // Reset that silently un-hid four cards would reach across that
            // line. It stays in the mode, so Cancel can still undo it.
            button(String(localized: "Reset"), systemName: "arrow.counterclockwise",
                   action: onReset)
            button(String(localized: "Cancel"), systemName: nil, action: onCancel)
            button(String(localized: "Save"), systemName: nil, prominent: true, action: onSave)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule(style: .continuous).fill(ink.backing.opacity(0.94)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Reorder controls"))
    }

    private func button(_ label: String, systemName: String?,
                        prominent: Bool = false,
                        action: @escaping () -> Void) -> some View {
        ReorderBarButton(label: label, systemName: systemName,
                         prominent: prominent, ink: ink, action: action)
    }
}

/// Its own view so hover state is per-button rather than one flag shared by
/// five of them.
private struct ReorderBarButton: View {
    let label: String
    var systemName: String?
    var prominent: Bool
    let ink: PanelContrast.Ink
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemName {
                    Image(systemName: systemName).font(.system(size: 9, weight: .bold))
                }
                Text(label).font(.system(size: 11, weight: prominent ? .semibold : .medium))
            }
            .foregroundStyle(prominent ? ink.selectionInk : ink.baseColor)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                Capsule(style: .continuous)
                    .fill(prominent ? ink.selectionFill : ink.cardFill)
                    // Hover is a TINT and nothing else — the app's hover
                    // treatment everywhere. The white wash works whichever way
                    // the accent resolves, since PanelContrast can hand this a
                    // light or a dark fill and a hard-coded "brighter" would be
                    // wrong for one of them.
                    .overlay(Capsule(style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.18 : 0))))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(Text(label))
    }
}
