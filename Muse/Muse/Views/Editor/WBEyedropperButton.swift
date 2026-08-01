//
//  WBEyedropperButton.swift
//  Muse
//
//  The eyedropper toggle beside Temperature.
//
//  This file used to hold `EditPresetsTab`, the Looks tab's name-row list.
//  Spec 05 replaced that view with `LooksBrowserView` (live thumbnails of every
//  look on the CURRENT photo); the preset STORE and the copy-by-value
//  semantics are unchanged, so that was a view swap, not a data one.
//

import SwiftUI

/// The eyedropper toggle beside Temperature.
struct WBEyedropperButton: View {
    @ObservedObject var session: EditSession
    @Environment(\.theme) private var theme
    @State private var armed = false

    var body: some View {
        Button {
            armed.toggle()
            session.eyedropperArmed = armed
        } label: {
            Image(systemName: "eyedropper")
                .foregroundStyle(armed ? theme.controlAccent : theme.textSecondary)
        }
        .buttonStyle(.plain)
        .help(Text("Click a neutral gray area to set white balance"))
        .accessibilityLabel(Text("White balance eyedropper"))
        .onChange(of: session.eyedropperArmed) { _, value in armed = value }
    }
}
