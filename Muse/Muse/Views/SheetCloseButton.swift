//
//  SheetCloseButton.swift
//  Muse
//
//  The circular, hover-brightening ✕ used in the app's modal sheets
//  (About / Image Layout). Esc also closes via the cancel-action shortcut.
//  Shared so the close affordance can't drift between sheets.
//

import SwiftUI

struct SheetCloseButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.primary.opacity(hovering ? 0.16 : 0.08)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut(.cancelAction)
        .help("Close")
        .accessibilityLabel("Close")
    }
}
