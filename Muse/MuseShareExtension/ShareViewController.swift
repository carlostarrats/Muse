//
//  ShareViewController.swift
//  MuseShareExtension
//
//  "Send to Muse" — copies shared files into the single Muse iCloud folder
//  (the app's ubiquity container `Documents`). The main app's FolderWatcher
//  then indexes/analyzes them and writes the sidecar via the normal pipeline.
//  No network, no compose UI — it copies and completes immediately.
//

import Cocoa
import UniformTypeIdentifiers

final class ShareViewController: NSViewController {
    private let containerID = "iCloud.com.tarrats.Muse"

    // Programmatic, minimal view — no nib. (The template's ShareViewController.xib
    // is unused; the principal class is instantiated directly per Info.plist.)
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        Task { await handleShare() }
    }

    /// The synced "Muse" folder (ubiquity container Documents), created if needed.
    private func icloudFolder() -> URL? {
        guard let container = FileManager.default
                .url(forUbiquityContainerIdentifier: containerID) else { return nil }
        let docs = container.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }

    private func handleShare() async {
        defer { extensionContext?.completeRequest(returningItems: nil) }
        guard let dest = icloudFolder(),
              let items = extensionContext?.inputItems as? [NSExtensionItem] else { return }
        for item in items {
            for provider in item.attachments ?? [] {
                guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                        || provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                else { continue }
                if let url = try? await loadFileURL(provider) {
                    copyIn(url, to: dest)
                }
            }
        }
    }

    private func loadFileURL(_ provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                if let error { cont.resume(throwing: error); return }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    cont.resume(returning: url)
                } else if let url = item as? URL {
                    cont.resume(returning: url)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func copyIn(_ src: URL, to dest: URL) {
        let target = uniqueDestination(for: src.lastPathComponent, in: dest)
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: src, options: [],
                                       writingItemAt: target, options: .forReplacing,
                                       error: &coordError) { readURL, writeURL in
            try? FileManager.default.copyItem(at: readURL, to: writeURL)
        }
    }

    /// Avoid clobbering an existing file: append " 2", " 3", … if needed.
    private func uniqueDestination(for name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            let newName = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = dir.appendingPathComponent(newName)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}
