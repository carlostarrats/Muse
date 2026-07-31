//
//  PeakingOverlayView.swift
//  Muse
//
//  Thin SwiftUI wrapper: renders the tinted-edge CIImage once per (source,
//  accent) change and hands SwiftUI a plain Image. The CIContext is shared —
//  a fresh one per view would rebuild the GPU pipeline on every toggle.
//

import CoreImage
import SwiftUI

struct PeakingOverlayView: View {
    let source: CGImage
    let accent: Color

    private static let context = CIContext()
    @State private var rendered: CGImage?

    var body: some View {
        Group {
            if let rendered {
                Image(decorative: rendered, scale: 1).resizable()
            } else {
                Color.clear
            }
        }
        .task(id: ObjectIdentifier(source)) { await renderEdges() }
    }

    private func renderEdges() async {
        let ciColor = CIColor(color: NSColor(accent)) ?? CIColor.white
        let input = CIImage(cgImage: source)
        let output = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let edges = PeakingOverlay.render(input, accent: ciColor) else { return nil }
            return Self.context.createCGImage(edges, from: edges.extent)
        }.value
        rendered = output
    }
}
