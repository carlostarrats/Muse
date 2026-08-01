//
//  ScopesPanel.swift
//  Muse
//
//  The Scopes tab, replacing Spec 04's placeholder: the histogram, a luminance
//  toggle, and the plain-English clipping messages.
//
//  The messages are the point. A histogram tells you there is clipping; a
//  sentence tells you how much, in which channel, and roughly where — which is
//  what someone learning to expose actually needs.
//

import SwiftUI

struct ScopesPanel: View {
    @ObservedObject var session: EditSession
    @Environment(\.theme) private var theme
    @State private var showLuminance = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingM) {
            HistogramView(stats: session.stats, showLuminance: showLuminance, session: session)
            Toggle(isOn: $showLuminance) { Text("Luminance") }
                .font(theme.labelFont)
                .toggleStyle(.checkbox)
                .tint(theme.controlAccent)

            if let stats = session.stats {
                let messages = ClippingMessages.compose(stats.clipping)
                if messages.isEmpty {
                    // Silence is the good outcome, but a blank panel reads as
                    // broken — say so once, plainly.
                    Text("Nothing is clipping.")
                        .font(theme.labelFont)
                        .foregroundStyle(theme.textSecondary)
                } else {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                        Text(message.displayText)
                            .font(theme.labelFont)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { session.refreshStats() }
    }
}
