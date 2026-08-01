//
//  LutRegistry.swift
//  Muse
//
//  RENDER-PATH ONLY. A miss is one synchronous `queue.read` of a multi-MB
//  blob, so this must never be called on the main thread.
//
//  Decoded cubes are MB-scale, so they are never library-resident: an LRU of
//  `cacheLimit` entries covers the looks a session actually touches. A missing
//  id means the referencing stack is UNRENDERABLE (see `EditRenderer.canRender`)
//  — the original renders everywhere, never a partial stack.
//

import Foundation
import GRDB

nonisolated enum LutRegistry {
    static let cacheLimit = 8

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (size: Int, data: Data)] = [:]
    nonisolated(unsafe) private static var lruOrder: [String] = []

    /// RGBA float32 cube data ready for `CIColorCubeWithColorSpace` (the stored
    /// blob is RGB; alpha is appended here rather than on disk, since the
    /// content hash is taken over the RGB bytes the `.cube` file declared).
    /// `queue` is injectable so tests can use an isolated in-memory database.
    static func rgbaCube(for id: String,
                         queue: DatabaseQueue? = Database.shared.dbQueue) -> (size: Int, data: Data)? {
        lock.lock()
        if let hit = cache[id] {
            lruOrder.removeAll { $0 == id }
            lruOrder.append(id)
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let queue,
              let row = try? queue.read({ db in try EditLutRow.fetchOne(db, key: id) }) ?? nil
        else { return nil }

        let rgb: [Float] = row.data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        var rgba = [Float]()
        rgba.reserveCapacity(rgb.count / 3 * 4)
        var i = 0
        while i + 2 < rgb.count {
            rgba.append(rgb[i]); rgba.append(rgb[i + 1]); rgba.append(rgb[i + 2]); rgba.append(1)
            i += 3
        }
        let entry = (size: row.size, data: rgba.withUnsafeBufferPointer { Data(buffer: $0) })

        lock.lock()
        cache[id] = entry
        // Dedupe before appending, exactly as `preload` does. The read above
        // releases the lock while it hits the database, so two threads can miss
        // on the same id and both land here — appending blind would put the id
        // in `lruOrder` twice, and the eviction below would then drop the live
        // cache entry on the first copy while the second lingered as a phantom.
        lruOrder.removeAll { $0 == id }
        lruOrder.append(id)
        while lruOrder.count > cacheLimit {
            let evicted = lruOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        lock.unlock()
        return entry
    }

    /// Seed the cache from data already in hand — the import path has just
    /// parsed the cube, so making the next render read it back off disk is
    /// pure waste. Takes the RGB floats the `.cube` declared (what the hash
    /// covers); the alpha is appended here, exactly as on the read path.
    static func preload(id: String, size: Int, rgb: [Float]) {
        var rgba = [Float]()
        rgba.reserveCapacity(rgb.count / 3 * 4)
        var i = 0
        while i + 2 < rgb.count {
            rgba.append(rgb[i]); rgba.append(rgb[i + 1]); rgba.append(rgb[i + 2]); rgba.append(1)
            i += 3
        }
        let entry = (size: size, data: rgba.withUnsafeBufferPointer { Data(buffer: $0) })
        lock.lock()
        cache[id] = entry
        lruOrder.removeAll { $0 == id }
        lruOrder.append(id)
        while lruOrder.count > cacheLimit {
            let evicted = lruOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        lock.unlock()
    }

    /// Called on delete. A row is immutable, so this is only ever about the
    /// row's EXISTENCE changing, never its contents.
    static func invalidate(_ id: String) {
        lock.lock()
        cache.removeValue(forKey: id)
        lruOrder.removeAll { $0 == id }
        lock.unlock()
    }
}
