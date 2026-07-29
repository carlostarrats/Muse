//
//  ModalButton.swift
//  Muse
//
//  The one button every modal card's footer uses.
//
//  There were three kinds before: a `FooterButton` private to the rules card, a
//  `HoverButton` private to the Drive form (also borrowed by Settings), and
//  stock SwiftUI buttons everywhere else — so a card either lit its buttons on
//  hover or didn't, depending on which one you happened to open. Stock macOS
//  buttons highlight on PRESS only, which is the odd one out in an app whose
//  every other control (toolbar icons, sidebar rows, tag chips) responds to the
//  cursor.
//
//  Disabled state comes from `@Environment(\.isEnabled)`, so a caller's plain
//  `.disabled(…)` dims it — the same reason `moodToolbarIcon` reads that
//  environment value rather than taking a parameter (an explicit
//  `foregroundStyle` overrides SwiftUI's automatic dimming, so it has to be
//  applied by hand).
//
//  `title` is a plain `String`: most call sites build it at runtime, and a
//  `String` is NOT extracted for localization — wrap literals in
//  `String(localized:)` at the call site (CLAUDE.md).
//

import SwiftUI

struct ModalButton: View {
    enum Kind {
        /// Secondary — Cancel, Reset, Copy Link.
        case normal
        /// The card's primary action.
        case prominent
        /// Delete / Replace / Move to Trash — unrecoverable, so it's red.
        case destructive
    }

    let title: String
    var kind: Kind = .normal
    /// Return activates it.
    var isDefault: Bool = false
    /// Escape activates it (Cancel). The modal presenter also dismisses on
    /// Escape, so this is belt-and-braces for cards that need the button's
    /// own side effects to run.
    var isCancel: Bool = false
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: kind == .normal ? .regular : .semibold))
                .foregroundStyle(kind == .normal ? Color.primary : Color.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .onHover { hovering = isEnabled && $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var shortcut: KeyboardShortcut? {
        if isDefault { return .defaultAction }
        if isCancel { return .cancelAction }
        return nil
    }

    /// Filled kinds brighten toward full strength on hover; the secondary one
    /// deepens its neutral wash. Both read as "the cursor is on me" without
    /// changing the button's weight in the layout.
    private var fill: Color {
        switch kind {
        case .normal:      return Color.primary.opacity(hovering ? 0.16 : 0.08)
        case .prominent:   return Color.accentColor.opacity(hovering ? 1.0 : 0.88)
        case .destructive: return Color.red.opacity(hovering ? 1.0 : 0.88)
        }
    }
}
