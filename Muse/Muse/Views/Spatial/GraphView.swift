//
//  GraphView.swift
//  Muse
//
//  Spec §3 graph view (replaces GlobeView): zoomed out, collections as
//  labeled thumbnail clusters on a flat plane with shared-tag lines;
//  zooming into a cluster spreads its images in 3D by visual similarity.
//

import SwiftUI
import SceneKit
import AppKit

struct GraphView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var engine = CollectionsEngine.shared

    var body: some View {
        ZStack {
            Color(red: 0.066, green: 0.066, blue: 0.078).ignoresSafeArea() // Ink
            if engine.collections.isEmpty {
                emptyState
            } else {
                Text("Graph loading…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No collections yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Run Analyze (✨) on a folder of images to build collections.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
