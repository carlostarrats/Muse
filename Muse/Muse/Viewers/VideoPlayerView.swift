//
//  VideoPlayerView.swift
//  Muse
//
//  AVKit-backed video player. Auto-plays when shown.
//

import SwiftUI
import AVKit

struct VideoPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = AVPlayer(url: url)
        view.player?.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if (nsView.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            nsView.player?.pause()
            nsView.player = AVPlayer(url: url)
            nsView.player?.play()
        }
    }

    // AppKit does not auto-pause an AVPlayer when its view leaves the
    // hierarchy. Without this, closing the viewer leaves audio playing
    // from an invisible player until it eventually deallocs.
    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}
