//
//  ImageViewer.swift
//  Muse
//
//  Phase 0.5 image preview overlay. Loads NSImage on demand, shows
//  fit-to-window with a "100%" scrollable mode toggle and a dismiss
//  on background-click.
//

import SwiftUI
import AppKit

struct ImageViewer: View {
    @EnvironmentObject var appState: AppState
    let file: FileNode

    @State private var image: NSImage?
    @State private var isFullSize: Bool = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { appState.selectedFile = nil }

            if let image {
                if isFullSize {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: image.size.width, height: image.size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 12)
                        .padding(40)
                }
            } else {
                ProgressView().controlSize(.large)
            }

            VStack {
                Spacer()
                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { isFullSize.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isFullSize
                                  ? "arrow.down.right.and.arrow.up.left"
                                  : "arrow.up.left.and.arrow.down.right")
                            Text(isFullSize ? "Fit" : "100%")
                        }
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(20)
                    Spacer()
                }
            }
        }
        .task(id: file.url) {
            isFullSize = false
            image = await loadImage(at: file.url)
        }
    }

    private func loadImage(at url: URL) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            NSImage(contentsOf: url)
        }.value
    }
}
