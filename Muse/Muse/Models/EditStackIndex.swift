//
//  EditStackIndex.swift
//  Muse
//
//  The identity of a file's non-destructive edit stack. nil = unedited
//  (original bytes). It is an IDENTITY FUNCTION today — no provider is
//  installed, so every consumer behaves exactly as it did before this type
//  existed. Spec 04 installs the real provider and every consumer
//  (ThumbnailCache, EffectiveDimensions, OutputRender) is already correct.
//
//  Keyed by URL, NOT files.id — an edit stack is per file LOCATION like
//  tags/notes, since files.content_hash is UNIQUE and a column there would
//  force one stack to be shared by the same photo in two folders.
//
//  Read from background decode/layout paths, so the provider slot is
//  lock-guarded rather than actor-isolated: these are hot, synchronous reads
//  inside view bodies and thumbnail workers, and an await here would be a
//  suspension point on the grid's critical path.
//

import Foundation
import CoreGraphics

protocol EditStackProviding: Sendable {
    /// Stable digest of the file's edit stack; nil when unedited.
    func stackHash(for url: URL) -> String?
    /// Post-crop dimensions; nil when the stack has no crop (or no stack).
    func croppedSize(for url: URL) -> CGSize?
}

nonisolated enum EditStackIndex {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var provider: (any EditStackProviding)?

    /// The provider is read UNDER the lock and called OUTSIDE it.
    ///
    /// `NSLock` is not recursive, and the live provider's implementation reads
    /// this same index — holding the lock across the call deadlocks the first
    /// time anything asks an edited file for its hash (which is every grid
    /// tile, on the main thread). Reading the reference is the only part that
    /// needs mutual exclusion.
    private static func currentProvider() -> (any EditStackProviding)? {
        lock.lock(); defer { lock.unlock() }
        return provider
    }

    static func stackHash(for url: URL) -> String? {
        currentProvider()?.stackHash(for: url)
    }

    static func croppedSize(for url: URL) -> CGSize? {
        currentProvider()?.croppedSize(for: url)
    }

    /// Test/Spec-04 seam: install the real provider. Passing nil restores the
    /// identity behaviour (which is what every test tears down to).
    static func installProvider(_ p: (any EditStackProviding)?) {
        lock.lock(); defer { lock.unlock() }
        provider = p
    }

    // MARK: - The index itself

    /// One entry per alive path that carries an edit. Everything the hot
    /// consumers need is PRE-RESOLVED at rebuild time: the provider is called
    /// from view bodies and thumbnail workers, so it must never decode JSON,
    /// touch the database, or open a file.
    private struct Entry {
        let hash: String
        let stack: EditStack?          // nil when the blob wouldn't decode
        let geometry: GeometryParams?
        let renderable: Bool
    }

    /// Guarded by the SAME `lock` as `provider` — one lock, so a rebuild and a
    /// read can't interleave into a half-swapped index.
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]

    /// Replace the whole index. Cheap: an edited file is rare, so this
    /// dictionary is small even in a large library.
    static func rebuild(entries newEntries: [(path: String, stackJSON: String, hash: String)]) {
        var built: [String: Entry] = [:]
        built.reserveCapacity(newEntries.count)
        for e in newEntries {
            built[e.path] = makeEntry(stackJSON: e.stackJSON, hash: e.hash)
        }
        lock.lock(); defer { lock.unlock() }
        entries = built
    }

    /// Merge a subset in, and DROP paths in `scope` that no longer carry an
    /// edit. The scope parameter is what makes a reset visible: without it a
    /// removed row would linger in the index and the file would keep
    /// rendering its old stack until the next full rebuild.
    static func merge(entries newEntries: [(path: String, stackJSON: String, hash: String)],
                      clearingScope scope: [String]) {
        let built = newEntries.map { ($0.path, makeEntry(stackJSON: $0.stackJSON, hash: $0.hash)) }
        lock.lock(); defer { lock.unlock() }
        for path in scope { entries.removeValue(forKey: path) }
        for (path, entry) in built { entries[path] = entry }
    }

    private static func makeEntry(stackJSON: String, hash: String) -> Entry {
        let decoded = EditStackCodec.decode(stackJSON)
        return Entry(hash: hash,
                     stack: decoded,
                     geometry: decoded?.geometryParams,
                     renderable: decoded.map(EditRenderer.canRender) ?? false)
    }

    /// The decoded stack for a path, or nil when unedited / undecodable.
    /// An undecodable blob returns nil deliberately: the original renders,
    /// and the stored blob is left untouched for a build that understands it.
    static func resolvedStack(for url: URL) -> EditStack? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[url.standardizedFileURL.path], entry.renderable
        else { return nil }
        return entry.stack
    }

    fileprivate static func indexedHash(for url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        return entries[url.standardizedFileURL.path]?.hash
    }

    fileprivate static func indexedGeometry(for url: URL) -> GeometryParams? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[url.standardizedFileURL.path], entry.renderable
        else { return nil }
        return entry.geometry
    }
}

/// The real provider. Does NO I/O, ever — every answer is a dictionary lookup
/// against the pre-resolved index, because these are called synchronously from
/// view bodies (per frame of an animating hero flight) and from the off-main
/// thumbnail workers.
struct LiveEditStackProvider: EditStackProviding {
    /// Returned even for an UNRENDERABLE stack: the thumbnail cache key must
    /// still differ from the unedited one, or a build that later learns to
    /// render the stack would serve the original's cached PNG forever.
    func stackHash(for url: URL) -> String? {
        EditStackIndex.indexedHash(for: url)
    }

    func croppedSize(for url: URL) -> CGSize? {
        guard let geometry = EditStackIndex.indexedGeometry(for: url), !geometry.isNeutral,
              let headerSize = ImageHeaderSizeCache.cached(url)
        else { return nil }
        return geometry.appliedDisplaySize(to: headerSize)
    }
}
