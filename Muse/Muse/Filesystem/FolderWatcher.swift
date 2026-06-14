//
//  FolderWatcher.swift
//  Muse
//
//  FSEvents-backed file system watcher. Coalesced, kernel-backed —
//  same API every serious macOS file manager uses (Finder, Bridge,
//  Photos). Watches a single folder by default; `recursive` flag
//  available for the optional "show subfolders" mode.
//

import Foundation
import CoreServices

final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private let queue: DispatchQueue

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        self.queue = DispatchQueue(label: "muse.folderwatcher", qos: .utility)
    }

    func watch(url: URL, recursive: Bool = false) {
        stop()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let pathsToWatch = [url.path] as CFArray
        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )
        let interval: CFTimeInterval = 0.3 // coalesce changes for 300ms

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.fire()
        }

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            interval,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
        _ = recursive // FSEvents always reports descendants by default; flag reserved for future shallow filtering
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        // The callback context is passUnretained(self); a coalesced event
        // block may already be queued on `queue`. Drain it before we return
        // so no in-flight callback dereferences a deallocating watcher
        // (stop() runs from deinit). The block dispatches to main and returns
        // immediately, so this barrier is cheap. Callbacks never retain self,
        // so deinit cannot be running on `queue` — no self-deadlock.
        queue.sync { }
        FSEventStreamRelease(s)
        stream = nil
    }

    private func fire() {
        DispatchQueue.main.async { [onChange] in
            onChange()
        }
    }

    deinit { stop() }
}
