//
//  EditorBackdrop.swift
//  Muse
//
//  A flat neutral field behind the editor canvas.
//
//  Flat and NEUTRAL is the whole point: the app's mood backgrounds are tinted,
//  and judging colour against a tinted surround is how you end up grading
//  every photo slightly the other way. Five fixed levels, right-click to
//  switch, persisted globally (this is a working preference, not a per-photo
//  one).
//

import SwiftUI

enum EditorBackdropLevel: String, CaseIterable, Identifiable {
    case white, light, mid, dark, black

    var id: String { rawValue }

    var brightness: Double {
        switch self {
        case .white: 1.0
        case .light: 0.85
        case .mid: 0.48
        case .dark: 0.18
        case .black: 0.0
        }
    }

    var label: String {
        switch self {
        case .white: String(localized: "White")
        case .light: String(localized: "Light Gray")
        case .mid: String(localized: "Mid Gray")
        case .dark: String(localized: "Dark Gray")
        case .black: String(localized: "Black")
        }
    }

    /// Mid grey — the neutral judgement surface, and the reason it's the
    /// default rather than the app's own background.
    static let `default`: EditorBackdropLevel = .mid

    static func resolve(_ raw: String?) -> EditorBackdropLevel {
        raw.flatMap(EditorBackdropLevel.init(rawValue:)) ?? .default
    }
}

struct EditorBackdrop: View {
    @Binding var level: EditorBackdropLevel

    var body: some View {
        Color(white: level.brightness)
            .ignoresSafeArea()
            .contextMenu {
                ForEach(EditorBackdropLevel.allCases) { option in
                    Button {
                        level = option
                    } label: {
                        if option == level {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            }
            .accessibilityLabel(Text("Editor backdrop"))
            .accessibilityValue(Text(level.label))
    }
}
