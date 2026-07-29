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

    /// Every failure here used to be swallowed — `try?` on the copy, an ignored
    /// coordinator error, and a `defer` that reported SUCCESS no matter what. A
    /// user signed out of iCloud (no container), or a copy that failed on disk,
    /// got the same silent "done" as a real one and their file simply never
    /// appeared. There is no UI to show an error in (the view is 1×1 and the
    /// extension completes immediately), so the honest signal is the system's
    /// own: complete when at least one item landed, and `cancelRequest` — which
    /// surfaces the error to the user — when we were given items and saved none.
    private func handleShare() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        guard let dest = icloudFolder() else {
            finish(saved: 0, attempted: Self.attachmentCount(items),
                   reason: "Muse couldn’t reach its iCloud folder. Check that you’re signed in to iCloud and iCloud Drive is on.")
            return
        }
        var saved = 0
        var attempted = 0
        for item in items {
            for provider in item.attachments ?? [] {
                guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                        || provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                else { continue }
                attempted += 1
                if let url = try? await loadFileURL(provider) {
                    if copyIn(url, to: dest) { saved += 1 }
                } else if let (data, ext) = try? await loadImageData(provider) {
                    // An image shared as in-memory data (no file URL) — e.g. from an
                    // app that doesn't back it with a file. The guard admits these
                    // (Info.plist advertises image activation), so handle them
                    // instead of silently dropping: write the bytes to a file.
                    if writeImageData(data, ext: ext, to: dest) { saved += 1 }
                }
            }
        }
        finish(saved: saved, attempted: attempted,
               reason: "Muse couldn’t save the shared item.")
    }

    private static func attachmentCount(_ items: [NSExtensionItem]) -> Int {
        items.reduce(0) { $0 + ($1.attachments?.count ?? 0) }
    }

    /// Completes once. Reports failure only when we were handed something and
    /// saved none of it — a partial success still completes, so one unreadable
    /// item in a multi-file share doesn't discard the ones that worked.
    private func finish(saved: Int, attempted: Int, reason: String) {
        if attempted > 0 && saved == 0 {
            let error = NSError(domain: "com.tarrats.Muse.share", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: reason])
            extensionContext?.cancelRequest(withError: error)
        } else {
            extensionContext?.completeRequest(returningItems: nil)
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

    /// Load an in-memory image as raw bytes + a filename extension derived from
    /// its most specific registered image type (e.g. public.jpeg → "jpeg").
    private func loadImageData(_ provider: NSItemProvider) async throws -> (Data, String)? {
        guard let typeID = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }), let utType = UTType(typeID) else { return nil }
        let data: Data? = try await withCheckedThrowingContinuation { cont in
            provider.loadDataRepresentation(forTypeIdentifier: typeID) { d, e in
                if let e { cont.resume(throwing: e) } else { cont.resume(returning: d) }
            }
        }
        guard let data, !data.isEmpty else { return nil }
        return (data, utType.preferredFilenameExtension ?? "img")
    }

    @discardableResult
    private func writeImageData(_ data: Data, ext: String, to dest: URL) -> Bool {
        let target = uniqueDestination(for: "Shared Image.\(ext)", in: dest)
        var coordError: NSError?
        var ok = false
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing,
                                       error: &coordError) { writeURL in
            ok = (try? data.write(to: writeURL)) != nil
        }
        return ok && coordError == nil
    }

    @discardableResult
    private func copyIn(_ src: URL, to dest: URL) -> Bool {
        let target = uniqueDestination(for: src.lastPathComponent, in: dest)
        var coordError: NSError?
        var ok = false
        NSFileCoordinator().coordinate(readingItemAt: src, options: [],
                                       writingItemAt: target, options: .forReplacing,
                                       error: &coordError) { readURL, writeURL in
            ok = (try? FileManager.default.copyItem(at: readURL, to: writeURL)) != nil
        }
        return ok && coordError == nil
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
