//
//  ViewerChrome.swift
//  Muse
//
//  Common shell around viewer overlays — dimmed background, close
//  button, escape-to-dismiss. Wraps any viewer body.
//

import SwiftUI

struct ViewerChrome<Content: View>: View {
    @EnvironmentObject var appState: AppState
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { appState.selectedFile = nil }

            content()
                .background(Color(NSColor.windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 12)
                .padding(40)

            HStack(spacing: 8) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    appState.selectedFile = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(20)
        }
    }
}
