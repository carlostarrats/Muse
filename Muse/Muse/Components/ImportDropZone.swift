//
//  ImportDropZone.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SwiftUI
import UniformTypeIdentifiers

/// Transparent overlay that accepts image file drops onto the entire window.
/// While the user is dragging image files over the window, a dashed border and
/// instructional label are shown. On drop, the URLs are handed off to
/// `AppState.importManager`.
struct ImportDropZone: View {

    @EnvironmentObject var appState: AppState

    @State private var isDraggingOver: Bool = false

    var body: some View {
        ZStack {
            // Drag-over overlay — only visible while a drag is in progress
            if isDraggingOver {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(Color.accentColor)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(0.06))
                    )
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 32, weight: .light))
                                .foregroundStyle(Color.accentColor)
                            Text("Drop images to import")
                                .font(.headline)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(12)
                    .allowsHitTesting(false)
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [UTType.image, UTType.fileURL], isTargeted: $isDraggingOver) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Drop handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let manager = appState.importManager else { return false }

        var handled = false

        for provider in providers {
            // Try loading as a file URL first (covers all file types including non-image UTIs)
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    importURL(url, using: manager)
                }
                handled = true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                // Fallback: image data directly — less common from Finder but handle gracefully
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                    guard let url = item as? URL else { return }
                    importURL(url, using: manager)
                }
                handled = true
            }
        }

        return handled
    }

    private func importURL(_ url: URL, using manager: ImportManager) {
        Task { @MainActor in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

            if isDirectory.boolValue {
                await manager.importFolder(at: url)
            } else {
                do {
                    _ = try await manager.importFile(at: url)
                } catch {
                    print("[ImportDropZone] Failed to import \(url.lastPathComponent): \(error)")
                }
            }

            await appState.refreshAfterImport()
        }
    }
}
