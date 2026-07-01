//
//  VideoPlayerView.swift
//  Muse
//
//  AVKit-backed video player. Auto-plays when shown. Sized by its container to
//  the video's aspect-fit rect (the hero stage), so resizeAspect shows no bars;
//  the layer background is clear so the rounded-corner clip reveals the backdrop.
//

import SwiftUI
import AVKit
import AppKit

struct VideoPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.player = AVPlayer.noNetwork(url: url)
        view.player?.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if (nsView.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            nsView.player?.pause()
            nsView.player = AVPlayer.noNetwork(url: url)
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
