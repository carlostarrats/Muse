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

    static func stackHash(for url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        return provider?.stackHash(for: url)
    }

    static func croppedSize(for url: URL) -> CGSize? {
        lock.lock(); defer { lock.unlock() }
        return provider?.croppedSize(for: url)
    }

    /// Test/Spec-04 seam: install the real provider. Passing nil restores the
    /// identity behaviour (which is what every test tears down to).
    static func installProvider(_ p: (any EditStackProviding)?) {
        lock.lock(); defer { lock.unlock() }
        provider = p
    }
}
