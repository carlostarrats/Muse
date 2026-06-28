//
//  ModelViewerView.swift
//  Muse
//
//  SceneKit-backed 3D model viewer. Handles .usdz, .obj, .stl, .ply,
//  .dae via SCNScene's URL initializer; falls back to Quick Look for
//  formats SceneKit refuses.
//

import SwiftUI
import SceneKit
import AppKit

struct ModelViewerView: View {
    let url: URL

    private enum LoadState {
        case loading
        case loaded(SCNScene)
        case failed
    }
    @State private var state: LoadState = .loading

    var body: some View {
        // Parse the scene ONCE, off the main thread, keyed by url — never in
        // `body`. The old `try? SCNScene(url:)` in body re-parsed the whole model
        // (heavy I/O + geometry) on every re-render and handed SceneViewWrapper a
        // fresh scene each time, resetting the camera on unrelated UI changes.
        Group {
            switch state {
            case .loading:
                ProgressView().controlSize(.small)
            case .loaded(let scene):
                SceneViewWrapper(scene: scene)
            case .failed:
                QuickLookFallback(url: url)
            }
        }
        .task(id: url) {
            state = .loading
            let target = url
            let scene = await Task.detached(priority: .userInitiated) {
                try? SCNScene(url: target, options: nil)
            }.value
            guard !Task.isCancelled else { return }
            state = scene.map(LoadState.loaded) ?? .failed
        }
    }
}

private struct SceneViewWrapper: NSViewRepresentable {
    let scene: SCNScene

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = NSColor.windowBackgroundColor
        view.antialiasingMode = .multisampling4X
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        if nsView.scene !== scene {
            nsView.scene = scene
        }
    }
}
