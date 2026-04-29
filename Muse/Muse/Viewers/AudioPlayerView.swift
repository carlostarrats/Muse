//
//  AudioPlayerView.swift
//  Muse
//
//  AVKit-backed audio player with file metadata display. Waveform
//  rendering deferred — Phase 8 polish.
//

import SwiftUI
import AVKit
import AVFoundation
import AppKit

struct AudioPlayerView: View {
    let url: URL

    @State private var title: String = ""
    @State private var artist: String = ""
    @State private var artwork: NSImage?

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .frame(width: 280, height: 280)
                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 280, height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 4) {
                Text(title.isEmpty ? url.lastPathComponent : title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if !artist.isEmpty {
                    Text(artist)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            AVKitPlayer(url: url)
                .frame(height: 60)
                .frame(maxWidth: 480)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            await loadMetadata()
        }
    }

    private func loadMetadata() async {
        let asset = AVURLAsset(url: url)
        do {
            let metadata = try await asset.load(.metadata)
            for item in metadata {
                guard let key = item.commonKey else { continue }
                let value = try? await item.load(.value)
                switch key {
                case .commonKeyTitle:
                    if let s = value as? String { await MainActor.run { title = s } }
                case .commonKeyArtist:
                    if let s = value as? String { await MainActor.run { artist = s } }
                case .commonKeyArtwork:
                    if let data = value as? Data, let img = NSImage(data: data) {
                        await MainActor.run { artwork = img }
                    }
                default: break
                }
            }
        } catch {
            // Metadata extraction failure is non-fatal — playback still works.
        }
    }
}

private struct AVKitPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = AVPlayer(url: url)
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if (nsView.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            nsView.player = AVPlayer(url: url)
        }
    }
}
