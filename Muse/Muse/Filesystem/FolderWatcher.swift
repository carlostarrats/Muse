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

/// Pure helpers for turning a raw FSEvents path list into the set of media
/// files inside a folder that actually warrant a refresh. Kept separate +
/// nonisolated so it's unit-testable without an FSEvents stream.
nonisolated enum FolderEventFilter {
    /// Keep only paths that are (a) directly inside `folder` (or, when
    /// `recursive`, anywhere beneath it), (b) not hidden and not inside a
    /// dotfile directory like `.muse` (sidecar writes must not trigger a
    /// content refresh), and (c) a kind Muse can view. Returns standardized
    /// paths, de-duplicated.
    static func mediaChanges(paths: [String], folder: URL,
                             recursive: Bool) -> [String] {
        let folderPath = folder.standardizedFileURL.path
        var seen = Set<String>()
        var out: [String] = []
        for raw in paths {
            let std = URL(fileURLWithPath: raw).standardizedFileURL.path
            guard std.hasPrefix(folderPath + "/") else { continue }
            let relative = String(std.dropFirst(folderPath.count + 1))
            let components = relative.split(separator: "/")
            // Any hidden component (the file itself or an ancestor like
            // `.muse`) → ignore. Sidecars + thumbnails live behind dotdirs.
            if components.contains(where: { $0.hasPrefix(".") }) { continue }
            // Non-recursive watch: only direct children count.
            if !recursive && components.count != 1 { continue }
            guard AssetKind.detect(at: URL(fileURLWithPath: std)).hasNativeViewer
            else { continue }
            if seen.insert(std).inserted { out.append(std) }
        }
        return out
    }
}

final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void
    private let queue: DispatchQueue

    init(onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        self.queue = DispatchQueue(label: "muse.folderwatcher", qos: .utility)
    }

    func watch(url: URL, recursive: Bool = false) {
        watch(urls: [url], recursive: recursive)
    }

    func watch(urls: [URL], recursive: Bool = false) {
        stop()
        guard !urls.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let pathsToWatch = urls.map(\.path) as CFArray
        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot |
            // REQUIRED for the eventPaths cast below: without this flag the
            // framework delivers eventPaths as a raw C `char**`, and
            // reinterpreting that as an NSArray is undefined behavior (crash /
            // garbage). With it, eventPaths is a CFArray of CFString (toll-free
            // bridged to NSArray), so the unsafeBitCast is valid.
            kFSEventStreamCreateFlagUseCFTypes
        )
        let interval: CFTimeInterval = 0.3 // coalesce changes for 300ms

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            // kFSEventStreamCreateFlagUseCFTypes guarantees a CFArray of
            // CFString here (toll-free bridged to NSArray of String).
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            _ = numEvents
            watcher.fire(paths: paths)
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

    private func fire(paths: [String]) {
        DispatchQueue.main.async { [onChange] in
            onChange(paths)
        }
    }

    deinit { stop() }
}
