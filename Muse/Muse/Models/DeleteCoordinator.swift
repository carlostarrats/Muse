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

@MainActor
final class DeleteCoordinator: ObservableObject {

    /// Paths currently playing the burn-up shader.
    @Published var burningPaths: Set<String> = []

    /// Toast shown over the grid. The hero viewer keeps its own toast so
    /// its linger-for-undo machinery stays untouched.
    @Published var toast: ToastData?

    /// Spec: ~0.8s char. Tests inject 0.
    var burnDuration: Double = 0.85

    /// AppState wires these to currentFiles mutations.
    var onRemove: (URL) -> Void = { _ in }
    var onRestore: (FileNode) -> Void = { _ in }

    func deleteWithBurn(_ file: FileNode) async {
        let path = file.url.path
        guard !burningPaths.contains(path) else { return }
        // withAnimation drives BurnUpModifier.animatableData 0→1.
        withAnimation(.linear(duration: burnDuration)) {
            _ = burningPaths.insert(path)
        }
        if burnDuration > 0 {
            try? await Task.sleep(nanoseconds: UInt64(burnDuration * 1_000_000_000))
        }
        burningPaths.remove(path)
        do {
            let ticket = try TrashManager.trash(file.url)
            withAnimation(.easeIn(duration: 0.2)) {
                onRemove(file.url)
            }
            // Last-wins toast replacement is intentional for v1 single-file deletes.
            toast = ToastData(message: "Moved to Trash", actionLabel: "Undo") { [weak self] in
                self?.restore(ticket: ticket, node: file)
            }
        } catch {
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
