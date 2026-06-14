//
//  DeleteCoordinator.swift
//  Muse
//
//  Burn-up delete state machine (polish spec §4): mark the tile burning,
//  let the shader play, then move the file to Trash and surface an Undo
//  toast. Owned by AppState; views observe it DIRECTLY (@ObservedObject) —
//  nested ObservableObjects don't republish through their parent.
//

import Foundation
import SwiftUI
import AppKit

@MainActor
final class DeleteCoordinator: ObservableObject {

    /// Paths currently fading out for a delete (drives the tile's opacity fade).
    @Published var burningPaths: Set<String> = []

    /// Toast shown over the grid. The hero viewer keeps its own toast so
    /// its linger-for-undo machinery stays untouched.
    @Published var toast: ToastData?

    /// Tile fade-out duration before the file is trashed. Tests inject 0.
    var burnDuration: Double = 0.3

    /// AppState wires these to currentFiles mutations.
    var onRemove: (URL) -> Void = { _ in }
    var onRestore: (FileNode) -> Void = { _ in }

    func deleteWithBurn(_ file: FileNode) async {
        let path = file.url.path
        guard !burningPaths.contains(path) else { return }

        // Mark the tile as deleting → TileView fades it to 0 opacity (no burn /
        // fire shader). Then trash the file, remove it (the grid closes the
        // gap), and surface the Undo toast.
        withAnimation(.easeOut(duration: burnDuration)) {
            _ = burningPaths.insert(path)
        }
        if burnDuration > 0 {
            try? await Task.sleep(nanoseconds: UInt64(burnDuration * 1_000_000_000))
        }
        do {
            let ticket = try await TrashManager.trash(file.url)
            withAnimation(.easeIn(duration: 0.2)) {
                onRemove(file.url)
            }
            // Clear the fade flag only after the exit collapse: removing it in
            // the same commit as onRemove would flash the exiting tile back to
            // full opacity. Tests run with burnDuration == 0 (synchronous path).
            if burnDuration > 0 {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    self?.burningPaths.remove(path)
                }
            } else {
                burningPaths.remove(path)
            }
            // Last-wins toast replacement is intentional for v1 single-file
            // deletes (a second delete's toast replaces the first's Undo).
            toast = ToastData(message: "Moved to Trash", actionLabel: "Undo") { [weak self] in
                self?.restore(ticket: ticket, node: file)
            }
        } catch {
            // Restore the still-present tile gracefully.
            withAnimation(.easeOut(duration: 0.3)) {
                _ = burningPaths.remove(path)
            }
            toast = ToastData(message: "Couldn't move to Trash")
        }
    }

    func restore(ticket: TrashManager.Ticket, node: FileNode) {
        do {
            try TrashManager.undo(ticket)
            onRestore(node)
        } catch {
            // Already back at the original path (FSEvents/external move) —
            // the folder reload reconciles; stay quiet.
            guard !FileManager.default.fileExists(atPath: ticket.originalURL.path) else { return }
            toast = ToastData(message: "Couldn't restore — file is in the Trash")
        }
    }
}
