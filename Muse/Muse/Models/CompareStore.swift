//
//  CompareStore.swift
//  Muse
//
//  Side-by-side compare workbench state (Pattern B: its own @MainActor
//  singleton, observed directly, no AppState @Published surface).
//
//  Compare and the hero viewer never coexist — `open(urls:)` is only ever
//  called from the grid, where `appState.selectedFile == nil` holds by
//  construction; every call site still guards on it explicitly.
//

import CoreGraphics
import Foundation

@MainActor final class CompareStore: ObservableObject {
    static let shared = CompareStore()
    static let maxPanes = 4

    @Published private(set) var urls: [URL]?
    @Published private(set) var focusedIndex = 0
    @Published var zoom: CGFloat = 1
    @Published var center = CGPoint(x: 0.5, y: 0.5)
    @Published var peaking = false

    var isActive: Bool { urls != nil }

    func open(urls incoming: [URL]) {
        guard incoming.count >= 2 else { return }
        urls = Array(incoming.prefix(Self.maxPanes))
        focusedIndex = 0
        zoom = 1
        center = CGPoint(x: 0.5, y: 0.5)
        peaking = false
    }

    func close() {
        urls = nil
        focusedIndex = 0
        zoom = 1
        center = CGPoint(x: 0.5, y: 0.5)
        peaking = false
    }

    func focus(_ index: Int) {
        guard let urls, !urls.isEmpty else { return }
        focusedIndex = min(max(index, 0), urls.count - 1)
    }

    func replaceFocused(with url: URL) {
        guard var urls, urls.indices.contains(focusedIndex) else { return }
        urls[focusedIndex] = url
        self.urls = urls
    }
}
