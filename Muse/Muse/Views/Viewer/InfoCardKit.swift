//
//  InfoCardKit.swift
//  Muse
//
//  The hero viewer's card vocabulary, shared so the PREVIEW column and the
//  EDIT panels can't drift apart: one translucent card shell, one small-caps
//  card label, one ＋/− expander button.
//
//  It lives here rather than in ViewerInfoColumn because the editor's left and
//  right panels are the same surface seen in a different mode — the owner's
//  standing note is that Preview and Edit must read as one screen, not two.
//

import SwiftUI

/// Rounded translucent card shell: radius 14, white 0.09 fill, 13/14 padding.
/// The fill is overridable ONLY so the editor can invert it for a light
/// backdrop — the value is the same 0.09 either way.
struct InfoCard<Content: View>: View {
    var fill: Color = .white.opacity(0.09)
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 13)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(fill))
    }
}

struct CardLabel: View {
    let text: String
    var color: Color = .white.opacity(0.42)
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.8)
            .textCase(.uppercase)
            .foregroundStyle(color)
            // Every card title (COLLECTION / TAGS / COLORS / INFO / LIGHT …) is
            // a heading, so VoiceOver's heading rotor can jump between cards.
            .accessibilityAddTraits(.isHeader)
    }
}

struct PlusCircleButton: View {
    let size: CGFloat
    let rotated: Bool
    /// White on a dark surface; the editor inverts it on a light backdrop.
    var ink: Color = .white
    var accessibilityLabel: String = String(localized: "Add")
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: rotated ? "minus" : "plus")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(ink.opacity(hovering ? 1.0 : 0.7))
                .frame(width: size, height: size)
                .background(Circle().fill(ink.opacity(hovering ? 0.28 : 0.14)))
                .contentTransition(.identity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .onHover { hovering = $0 }
    }
}

extension View {
    /// Makes a card's whole heading row toggle the card.
    ///
    /// The ＋/− disc is an 18pt target and was the only one — so a card read as
    /// "click this tiny thing", when the obvious gesture is to click the title.
    /// Buttons inside the row (copy, the disc itself) are hit-tested first, so
    /// they keep their own actions.
    func cardHeaderTap(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}
