//
//  CollectionsOverlay.swift
//  Muse
//
//  ⌘K all-collections overlay: dimmed material backdrop + adaptive grid
//  of CollectionCards. Arrow keys move focus, return opens the focused
//  collection, esc (or backdrop click) dismisses. Selecting a card both
//  activates the collection filter and closes the overlay.
//

import SwiftUI
import AppKit

struct CollectionsOverlay: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var engine = CollectionsEngine.shared
    @State private var focusedIndex = 0

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture { appState.collectionsOverlayVisible = false }
            VStack(alignment: .leading, spacing: 12) {
                Text("ALL COLLECTIONS — arrows to move · return to open · esc to close")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)],
                              spacing: 14) {
                        ForEach(Array(engine.collections.enumerated()), id: \.element.collection.id) { i, loaded in
                            CollectionCard(loaded: loaded, onSelect: { open(loaded) })
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 10)
                                    .fill(i == focusedIndex ? Color.accentColor.opacity(0.22) : .clear))
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, maxHeight: 520)
            .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
                .shadow(radius: 40))
        }
        .onExitCommand { appState.collectionsOverlayVisible = false }
        .background(KeyCaptureView(
            onLeft: { focusedIndex = max(0, focusedIndex - 1) },
            onRight: { focusedIndex = min(max(0, engine.collections.count - 1), focusedIndex + 1) },
            onReturn: {
                if engine.collections.indices.contains(focusedIndex) {
                    open(engine.collections[focusedIndex])
                }
            }))
    }

    private func open(_ loaded: CollectionStore.Loaded) {
        appState.setActiveCollection(loaded.collection.id)
        appState.collectionsOverlayVisible = false
    }
}

/// Minimal NSView key capture for arrows/return inside the overlay.
struct KeyCaptureView: NSViewRepresentable {
    var onLeft: () -> Void
    var onRight: () -> Void
    var onReturn: () -> Void

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        v.onLeft = onLeft; v.onRight = onRight; v.onReturn = onReturn
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onLeft = onLeft; nsView.onRight = onRight; nsView.onReturn = onReturn
    }

    final class KeyView: NSView {
        var onLeft: (() -> Void)?
        var onRight: (() -> Void)?
        var onReturn: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 123: onLeft?()
            case 124: onRight?()
            case 36:  onReturn?()
            default:  super.keyDown(with: event)
            }
        }
    }
}
