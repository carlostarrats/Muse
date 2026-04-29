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

    var body: some View {
        if let scene = try? SCNScene(url: url, options: nil) {
            SceneViewWrapper(scene: scene)
        } else {
            QuickLookFallback(url: url)
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
