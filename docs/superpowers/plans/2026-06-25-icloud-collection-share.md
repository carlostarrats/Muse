# iCloud Collection Share Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-collection "Share to iCloud…" action that consolidates the collection's images into one iCloud Drive folder Muse owns and hands the user Apple's native share sheet, plus a File-menu "Manage iCloud Shares…" list to delete past shares and reclaim space.

**Architecture:** Pure, unit-tested helpers (folder-path building, a JSON-backed share record store, an upload-progress reducer) sit under a `@MainActor` `ICloudShareService` orchestrator that copies members into the app's already-public-scoped iCloud container (`ICloudZone.folderURL()` → `Shared Collections/<name>/`), waits for the OS sync daemon to finish uploading via `NSMetadataQuery`, then presents `NSSharingServicePicker`. UI is two SwiftUI sheets (progress + manage) and one menu command. No network code — the OS daemon and native share sheet do all remote work.

**Tech Stack:** Swift, SwiftUI, AppKit (`NSSharingServicePicker`, `NSMetadataQuery`), Foundation (`FileManager` ubiquity APIs), GRDB (only to read collection membership — already wired via `appState.visibleFiles`), XCTest.

## Global Constraints

- **Min macOS 14.6.** Use only APIs available there.
- **Sandboxed app.** Write only into the app's OWN ubiquity container (`iCloud.com.tarrats.Muse`, already entitled) — no user-selected paths, no other locations.
- **No network code.** Reach for `URLSession` and stop. This feature adds zero network surface; Sparkle stays the only network path.
- **Files are never deleted, only Trashed** — except folders MUSE ITSELF created in its own iCloud container (the share folders), which are removed with `FileManager.removeItem`. Never `removeItem`/`recycle` a user's original source files.
- **iCloud container is data-loss-sensitive.** Only ever write/delete under `Documents/Shared Collections/`. Never touch the rest of the zone (the user's synced Muse folder / sidecars).
- **Debug builds strip iCloud entitlements** (`Muse-Debug.entitlements`). So `ICloudZone.folderURL()` returns nil in Debug → the service surfaces the "sign in to iCloud" path. The copy→upload→share end-to-end is verifiable ONLY in a release-signed build. Unit tests cover pure logic and never touch iCloud.
- **Every new user-facing string is localized.** Wrap literals in `String(localized:)`. `Button`/`Text`/menu titles auto-extract; everything else is hand-wrapped. Run `-exportLocalizations` and fill `fr` before "done."
- **New `.swift` files are auto-included** via the project's synchronized file groups — no `project.pbxproj` editing. Put app code under `Muse/Muse/Sharing/`, tests under `Muse/MuseTests/`.
- **Share set = the collection's currently displayed members** (`appState.visibleFiles`, folders excluded) — identical to the existing PDF share, so an active tag filter narrows the iCloud share the same way.
- **Build:** `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -5`
- **Test one class:** `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/<ClassName> 2>&1 | tail -15`

---

### Task 1: Share folder-path helpers (pure)

**Files:**
- Create: `Muse/Muse/Sharing/ICloudSharePaths.swift`
- Test: `Muse/MuseTests/ICloudSharePathsTests.swift`

**Interfaces:**
- Produces:
  - `enum ICloudSharePaths`
  - `static func sanitizedFolderName(_ raw: String) -> String`
  - `static func shareRoot(zoneDocuments: URL) -> URL` (`<docs>/Shared Collections`)
  - `static func shareFolder(zoneDocuments: URL, collectionName: String) -> URL` (`<docs>/Shared Collections/<sanitized>`)

- [ ] **Step 1: Write the failing test**

```swift
//  ICloudSharePathsTests.swift
import XCTest
@testable import Muse

final class ICloudSharePathsTests: XCTestCase {
    func testSanitizeStripsPathSeparatorsAndTrims() {
        XCTAssertEqual(ICloudSharePaths.sanitizedFolderName("  Spring/Summer 2025  "),
                       "Spring-Summer 2025")
        XCTAssertEqual(ICloudSharePaths.sanitizedFolderName("a:b/c\\d"), "a-b-c-d")
    }

    func testSanitizeEmptyFallsBackToCollection() {
        XCTAssertEqual(ICloudSharePaths.sanitizedFolderName("   "), "Collection")
        XCTAssertEqual(ICloudSharePaths.sanitizedFolderName("///"), "Collection")
    }

    func testShareFolderIsDeterministicUnderSharedCollections() {
        let docs = URL(fileURLWithPath: "/tmp/Documents", isDirectory: true)
        let folder = ICloudSharePaths.shareFolder(zoneDocuments: docs, collectionName: "Kitchen Inspo")
        XCTAssertEqual(folder.path, "/tmp/Documents/Shared Collections/Kitchen Inspo")
        // Same name → same URL (re-share refreshes, never duplicates).
        let again = ICloudSharePaths.shareFolder(zoneDocuments: docs, collectionName: "Kitchen Inspo")
        XCTAssertEqual(folder, again)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/ICloudSharePathsTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'ICloudSharePaths' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
//  ICloudSharePaths.swift
//  Muse
//
//  Pure path math for iCloud collection shares: turn a collection name into
//  a safe, deterministic folder under the app's iCloud zone. No I/O.
//

import Foundation

nonisolated enum ICloudSharePaths {
    static let subfolder = "Shared Collections"

    /// Collection name → a single-path-component folder name: path separators
    /// and reserved characters become hyphens, trimmed, collapsed. Empty →
    /// "Collection" so we never produce a nameless or escaping path.
    static func sanitizedFolderName(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:")
        let mapped = String(raw.unicodeScalars.map { illegal.contains($0) ? "-" : Character($0) })
        let collapsed = mapped
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? String(localized: "Collection") : collapsed
    }

    static func shareRoot(zoneDocuments: URL) -> URL {
        zoneDocuments.appendingPathComponent(subfolder, isDirectory: true)
    }

    static func shareFolder(zoneDocuments: URL, collectionName: String) -> URL {
        shareRoot(zoneDocuments: zoneDocuments)
            .appendingPathComponent(sanitizedFolderName(collectionName), isDirectory: true)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/ICloudSharePathsTests 2>&1 | tail -15`
Expected: PASS (3 tests). Note: `String(localized: "Collection")` resolves to "Collection" in the English test host.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Sharing/ICloudSharePaths.swift Muse/MuseTests/ICloudSharePathsTests.swift
git commit -m "feat: iCloud share folder-path helpers (pure)"
```

---

### Task 2: Share record + JSON store

**Files:**
- Create: `Muse/Muse/Sharing/ICloudShareRecord.swift`
- Test: `Muse/MuseTests/ICloudShareStoreTests.swift`

**Interfaces:**
- Consumes: nothing from prior tasks.
- Produces:
  - `struct ICloudShareRecord: Codable, Identifiable, Equatable` — `id: String`, `collectionName: String`, `folderPath: String`, `itemCount: Int`, `createdAt: Date`.
  - `final class ICloudShareStore` — `init(fileURL: URL)`, `func all() -> [ICloudShareRecord]` (newest first), `func add(_ r: ICloudShareRecord)`, `func remove(id: String)`, `static let `default`: ICloudShareStore` (Application Support/iCloudShares.json).

- [ ] **Step 1: Write the failing test**

```swift
//  ICloudShareStoreTests.swift
import XCTest
@testable import Muse

final class ICloudShareStoreTests: XCTestCase {
    private func tempStore() -> (ICloudShareStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloudshares-\(UUID().uuidString).json")
        return (ICloudShareStore(fileURL: url), url)
    }

    func testAddPersistsAndReloads() {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let r = ICloudShareRecord(id: "1", collectionName: "A", folderPath: "/p/A",
                                  itemCount: 3, createdAt: Date(timeIntervalSince1970: 100))
        store.add(r)
        // A fresh store over the same file sees it (persisted to disk).
        XCTAssertEqual(ICloudShareStore(fileURL: url).all(), [r])
    }

    func testAllReturnsNewestFirst() {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let older = ICloudShareRecord(id: "1", collectionName: "old", folderPath: "/p/old",
                                      itemCount: 1, createdAt: Date(timeIntervalSince1970: 10))
        let newer = ICloudShareRecord(id: "2", collectionName: "new", folderPath: "/p/new",
                                      itemCount: 1, createdAt: Date(timeIntervalSince1970: 99))
        store.add(older); store.add(newer)
        XCTAssertEqual(store.all().map(\.id), ["2", "1"])
    }

    func testRemoveDropsRecord() {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.add(ICloudShareRecord(id: "1", collectionName: "A", folderPath: "/p/A",
                                    itemCount: 1, createdAt: Date()))
        store.remove(id: "1")
        XCTAssertTrue(store.all().isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/ICloudShareStoreTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'ICloudShareStore' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
//  ICloudShareRecord.swift
//  Muse
//
//  A record of one iCloud collection share Muse made (so the user can later
//  delete the folder and reclaim space). JSON-backed list in Application
//  Support — NOT in iCloud, NOT SQLite (corruption trap).
//

import Foundation

struct ICloudShareRecord: Codable, Identifiable, Equatable {
    let id: String
    let collectionName: String
    let folderPath: String
    let itemCount: Int
    let createdAt: Date
}

final class ICloudShareStore {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.tarrats.Muse.icloudShareStore")

    init(fileURL: URL) { self.fileURL = fileURL }

    static let `default`: ICloudShareStore = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Muse", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return ICloudShareStore(fileURL: base.appendingPathComponent("iCloudShares.json"))
    }()

    /// Records newest-first.
    func all() -> [ICloudShareRecord] {
        queue.sync { load().sorted { $0.createdAt > $1.createdAt } }
    }

    func add(_ r: ICloudShareRecord) {
        queue.sync {
            var list = load().filter { $0.id != r.id }
            list.append(r)
            save(list)
        }
    }

    func remove(id: String) {
        queue.sync { save(load().filter { $0.id != id }) }
    }

    private func load() -> [ICloudShareRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder.iso.decode([ICloudShareRecord].self, from: data)
        else { return [] }
        return list
    }

    private func save(_ list: [ICloudShareRecord]) {
        guard let data = try? JSONEncoder.iso.encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}
private extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/ICloudShareStoreTests 2>&1 | tail -15`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Sharing/ICloudShareRecord.swift Muse/MuseTests/ICloudShareStoreTests.swift
git commit -m "feat: JSON-backed iCloud share record store"
```

---

### Task 3: Upload-progress reducer (pure)

**Files:**
- Create: `Muse/Muse/Sharing/UploadTally.swift`
- Test: `Muse/MuseTests/UploadTallyTests.swift`

**Interfaces:**
- Produces:
  - `struct UploadTally: Equatable` — `let uploaded: Int`, `let total: Int`, `var isComplete: Bool`, `var fraction: Double`.
  - `static func tally(uploadedFlags: [Bool]) -> UploadTally`.

- [ ] **Step 1: Write the failing test**

```swift
//  UploadTallyTests.swift
import XCTest
@testable import Muse

final class UploadTallyTests: XCTestCase {
    func testEmptyIsNotComplete() {
        let t = UploadTally.tally(uploadedFlags: [])
        XCTAssertEqual(t, UploadTally(uploaded: 0, total: 0))
        XCTAssertFalse(t.isComplete)
        XCTAssertEqual(t.fraction, 0, accuracy: 0.0001)
    }

    func testPartial() {
        let t = UploadTally.tally(uploadedFlags: [true, false, true, false])
        XCTAssertEqual(t, UploadTally(uploaded: 2, total: 4))
        XCTAssertFalse(t.isComplete)
        XCTAssertEqual(t.fraction, 0.5, accuracy: 0.0001)
    }

    func testAllUploadedIsComplete() {
        let t = UploadTally.tally(uploadedFlags: [true, true])
        XCTAssertTrue(t.isComplete)
        XCTAssertEqual(t.fraction, 1.0, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/UploadTallyTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'UploadTally' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
//  UploadTally.swift
//  Muse
//
//  Pure reducer: how many of N copied files have finished uploading to
//  iCloud. The NSMetadataQuery wrapper feeds it per-item uploaded flags.
//

import Foundation

struct UploadTally: Equatable {
    let uploaded: Int
    let total: Int

    var isComplete: Bool { total > 0 && uploaded == total }
    var fraction: Double { total == 0 ? 0 : Double(uploaded) / Double(total) }

    static func tally(uploadedFlags: [Bool]) -> UploadTally {
        UploadTally(uploaded: uploadedFlags.filter { $0 }.count, total: uploadedFlags.count)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/UploadTallyTests 2>&1 | tail -15`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Sharing/UploadTally.swift Muse/MuseTests/UploadTallyTests.swift
git commit -m "feat: iCloud upload-progress reducer (pure)"
```

---

### Task 4: ICloudShareService orchestrator (integration)

**Files:**
- Create: `Muse/Muse/Sharing/ICloudShareService.swift`

**Interfaces:**
- Consumes: `ICloudSharePaths`, `ICloudShareRecord`/`ICloudShareStore`, `UploadTally`, `ICloudZone.folderURL()`.
- Produces:
  - `@MainActor final class ICloudShareService: ObservableObject`
  - `enum Phase: Equatable` — `.idle`, `.copying`, `.uploading(UploadTally)`, `.ready(URL)`, `.failed(String)`
  - `@Published private(set) var phase: Phase`
  - `func start(title: String, urls: [URL])` — kicks the async pipeline
  - `func cancel()`
  - `func reset()`

This task has no unit test (it does iCloud I/O, which can't run in Debug). It is verified by a successful BUILD here and the manual signed-build checklist in Task 9.

- [ ] **Step 1: Write the implementation**

```swift
//  ICloudShareService.swift
//  Muse
//
//  Orchestrates an iCloud collection share: copy the displayed members into
//  Muse's iCloud zone (Shared Collections/<name>/), wait for the OS daemon to
//  finish uploading, record the share, then let the caller present the native
//  share sheet. No network code — the daemon does the sync.
//

import Foundation
import Combine

@MainActor final class ICloudShareService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case copying
        case uploading(UploadTally)
        case ready(URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private var task: Task<Void, Never>?
    private var query: NSMetadataQuery?
    private let store: ICloudShareStore

    init(store: ICloudShareStore = .default) { self.store = store }

    func reset() {
        cancel()
        phase = .idle
    }

    func cancel() {
        task?.cancel(); task = nil
        stopQuery()
    }

    func start(title: String, urls: [URL]) {
        guard urls.isEmpty == false else {
            phase = .failed(String(localized: "This collection has no images to share."))
            return
        }
        phase = .copying
        task = Task { await run(title: title, urls: urls) }
    }

    private func run(title: String, urls: [URL]) async {
        // Resolve the iCloud zone off the main thread (first access can block).
        guard let docs = await Task.detached(priority: .userInitiated, operation: {
            ICloudZone.folderURL()
        }).value else {
            phase = .failed(String(localized: "Sign in to iCloud and turn on iCloud Drive to share to iCloud."))
            return
        }

        let folder = ICloudSharePaths.shareFolder(zoneDocuments: docs, collectionName: title)
        let copied: [URL]
        do {
            copied = try await Task.detached(priority: .userInitiated) {
                try Self.copyMembers(urls, into: folder)
            }.value
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(String(localized: "Couldn't copy the images into iCloud."))
            return
        }
        if Task.isCancelled { return }
        guard copied.isEmpty == false else {
            phase = .failed(String(localized: "Couldn't copy the images into iCloud."))
            return
        }

        // Record the share now (folder exists); count is what we copied.
        store.add(ICloudShareRecord(id: UUID().uuidString, collectionName: title,
                                    folderPath: folder.path, itemCount: copied.count,
                                    createdAt: Date()))

        phase = .uploading(UploadTally(uploaded: 0, total: copied.count))
        await waitForUpload(of: copied)
        if Task.isCancelled { return }
        phase = .ready(folder)
    }

    /// Refresh the destination (clear + recopy so re-share never piles up
    /// stale files), then copy each member in, downloading dataless sources
    /// first. Returns the destination URLs actually written. Throws on
    /// CancellationError or a fatal filesystem error.
    nonisolated private static func copyMembers(_ urls: [URL], into folder: URL) throws -> [URL] {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var written: [URL] = []
        var usedNames = Set<String>()
        for src in urls {
            if Task.isCancelled { throw CancellationError() }
            // Pull down a not-yet-downloaded iCloud source so the copy has bytes.
            if (try? src.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                .ubiquitousItemDownloadingStatus == .some(.notDownloaded) {
                try? fm.startDownloadingUbiquitousItem(at: src)
                Self.waitUntilDownloaded(src, fm: fm)
            }
            guard fm.fileExists(atPath: src.path) else { continue }
            // De-collide identical basenames within the share folder.
            var name = src.lastPathComponent
            if usedNames.contains(name) {
                let base = src.deletingPathExtension().lastPathComponent
                let ext = src.pathExtension
                var n = 2
                repeat {
                    name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
                    n += 1
                } while usedNames.contains(name)
            }
            usedNames.insert(name)
            let dest = folder.appendingPathComponent(name)
            do { try fm.copyItem(at: src, to: dest); written.append(dest) }
            catch { continue }
        }
        return written
    }

    /// Block (bounded) until a dataless source finishes downloading. Best-effort:
    /// gives up after ~30s and lets the copy attempt proceed/fail.
    nonisolated private static func waitUntilDownloaded(_ url: URL, fm: FileManager) {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                .ubiquitousItemDownloadingStatus
            if status == .current || status == .downloaded { return }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    // MARK: - Upload wait (NSMetadataQuery)

    private func waitForUpload(of copied: [URL]) async {
        let targetPaths = Set(copied.map { $0.standardizedFileURL.path })
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let q = NSMetadataQuery()
            self.query = q
            q.searchScopes = [NSMetadataQueryUbiquitousDataScope]
            q.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
            var resumed = false
            let finish = { [weak self] in
                guard resumed == false else { return }
                resumed = true
                self?.stopQuery()
                cont.resume()
            }
            let onUpdate: (Notification) -> Void = { [weak self] _ in
                guard let self else { return }
                q.disableUpdates()
                var flags: [Bool] = []
                for i in 0..<q.resultCount {
                    guard let item = q.result(at: i) as? NSMetadataItem,
                          let p = (item.value(forAttribute: NSMetadataItemPathKey) as? String),
                          targetPaths.contains(URL(fileURLWithPath: p).standardizedFileURL.path)
                    else { continue }
                    let uploaded = (item.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey) as? Bool) ?? false
                    flags.append(uploaded)
                }
                let tally = UploadTally(uploaded: flags.filter { $0 }.count, total: targetPaths.count)
                self.phase = .uploading(tally)
                q.enableUpdates()
                if tally.isComplete { finish() }
            }
            NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                                   object: q, queue: .main, using: onUpdate)
            NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate,
                                                   object: q, queue: .main, using: onUpdate)
            q.start()
        }
    }

    private func stopQuery() {
        if let q = query {
            q.stop()
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: q)
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: q)
        }
        query = nil
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Muse/Muse/Sharing/ICloudShareService.swift
git commit -m "feat: ICloudShareService — copy, upload-wait, record orchestrator"
```

---

### Task 5: Progress sheet + share-sheet presentation

**Files:**
- Create: `Muse/Muse/Views/ICloudShareProgressView.swift`

**Interfaces:**
- Consumes: `ICloudShareService` (+ its `Phase`).
- Produces: `struct ICloudShareProgressView: View` — `init(service: ICloudShareService, onClose: @escaping () -> Void)`. On `.ready(folder)` it presents `NSSharingServicePicker` for that folder, then calls `onClose`.

- [ ] **Step 1: Write the implementation**

```swift
//  ICloudShareProgressView.swift
//  Muse
//
//  Modal shown while a collection copies + uploads to iCloud. On completion it
//  hands the folder to the native share sheet (Copy Link / AirDrop / Mail).
//

import SwiftUI
import AppKit

struct ICloudShareProgressView: View {
    @ObservedObject var service: ICloudShareService
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch service.phase {
            case .idle, .copying:
                ProgressView().controlSize(.large)
                Text("Copying images…")
            case .uploading(let t):
                ProgressView(value: t.fraction)
                    .frame(width: 220)
                Text("Uploading to iCloud… \(t.uploaded) of \(t.total)")
            case .ready:
                ProgressView().controlSize(.large)
                Text("Opening share…")
            case .failed(let message):
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(message).multilineTextAlignment(.center)
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 320)
        .padding(28)
        .onChange(of: phaseKey) { presentIfReady() }
        .onAppear { presentIfReady() }
        .toolbar {
            if case .uploading = service.phase {
                ToolbarItem { Button("Cancel") { service.cancel(); onClose() } }
            }
        }
    }

    // A cheap value that changes when .ready arrives (onChange can't observe an
    // associated-value enum directly without Equatable conformance on the case).
    private var phaseKey: String {
        if case .ready(let url) = service.phase { return "ready:\(url.path)" }
        return "\(service.phase)"
    }

    private func presentIfReady() {
        guard case .ready(let folder) = service.phase else { return }
        guard let contentView = NSApp.keyWindow?.contentView else { onClose(); return }
        let picker = NSSharingServicePicker(items: [folder])
        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
        onClose()
    }
}
```

Localization note: the interpolated `Text("Uploading to iCloud… \(t.uploaded) of \(t.total)")` extracts as a format key automatically (SwiftUI `Text` with interpolation produces a `String.LocalizationValue`). `"Copying images…"`, `"Opening share…"`, `"Done"`, `"Cancel"` extract as-is.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Muse/Muse/Views/ICloudShareProgressView.swift
git commit -m "feat: iCloud share progress sheet + native share-sheet handoff"
```

---

### Task 6: Wire "Share to iCloud…" into the collection header

**Files:**
- Modify: `Muse/Muse/Views/ShareCollectionButton.swift`

**Interfaces:**
- Consumes: `ICloudShareService`, `ICloudShareProgressView`, existing `exportURLs`.

- [ ] **Step 1: Add the menu item, service state, and sheet**

In `ShareCollectionButton`, add state after `@State private var preparing = false`:

```swift
    @StateObject private var iCloudService = ICloudShareService()
    @State private var showingICloudShare = false
```

Replace the `Menu { … }` content (the two existing buttons) with:

```swift
        Menu {
            Button("Save to…") { Task { await save() } }
            Button("Share") { Task { await share() } }
            Divider()
            Button("Share to iCloud…") { startICloudShare() }
        } label: {
```

Add the sheet modifier on the outer view — attach it right after `.accessibilityLabel("Share collection")`:

```swift
        .accessibilityLabel("Share collection")
        .sheet(isPresented: $showingICloudShare) {
            ICloudShareProgressView(service: iCloudService) {
                showingICloudShare = false
                iCloudService.reset()
            }
        }
```

Add the trigger method (near `share()`):

```swift
    private func startICloudShare() {
        iCloudService.reset()
        showingICloudShare = true
        iCloudService.start(title: title, urls: exportURLs)
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Muse/Muse/Views/ShareCollectionButton.swift
git commit -m "feat: add Share to iCloud… to the collection share menu"
```

---

### Task 7: Manage sheet + File-menu command

**Files:**
- Create: `Muse/Muse/Views/ManageICloudSharesView.swift`
- Modify: `Muse/Muse/Models/AppState.swift` (add one published flag)
- Modify: `Muse/Muse/ContentView.swift` (add one `.sheet`)
- Modify: `Muse/Muse/MuseApp.swift` (add one File-menu button)

**Interfaces:**
- Consumes: `ICloudShareStore`, `ICloudShareRecord`.
- Produces: `struct ManageICloudSharesView: View`; `AppState.iCloudSharesShown: Bool`.

- [ ] **Step 1: Create the manage view**

```swift
//  ManageICloudSharesView.swift
//  Muse
//
//  File-menu "Manage iCloud Shares…" — lists the iCloud collection shares Muse
//  has made and lets the user delete a folder to reclaim iCloud space. The only
//  surface for this list (no in-app navigation entry, by design).
//

import SwiftUI

struct ManageICloudSharesView: View {
    @Environment(\.dismiss) private var dismiss
    private let store = ICloudShareStore.default
    @State private var records: [ICloudShareRecord] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("iCloud Shares").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if records.isEmpty {
                Spacer()
                Text("No iCloud shares yet.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(records) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.collectionName)
                                Text("\(record.itemCount) images · \(record.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { delete(record) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete this iCloud share and free the space")
                            .accessibilityLabel("Delete iCloud share")
                        }
                    }
                }
            }
        }
        .frame(width: 460, height: 360)
        .onAppear { records = store.all() }
    }

    private func delete(_ record: ICloudShareRecord) {
        // Remove the folder Muse created in its own iCloud container; the OS
        // daemon propagates the removal. Then drop the record.
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: record.folderPath))
        store.remove(id: record.id)
        records = store.all()
    }
}
```

- [ ] **Step 2: Add the AppState flag**

In `Muse/Muse/Models/AppState.swift`, beside `@Published var showingCollections = false` (line ~245), add:

```swift
    /// Drives the File-menu "Manage iCloud Shares…" sheet.
    @Published var iCloudSharesShown = false
```

- [ ] **Step 3: Add the ContentView sheet**

In `Muse/Muse/ContentView.swift`, after the existing `.sheet(isPresented: $appState.settingsShown) { … }` (around line 320), add:

```swift
        .sheet(isPresented: $appState.iCloudSharesShown) {
            ManageICloudSharesView()
        }
```

- [ ] **Step 4: Add the File-menu command**

In `Muse/Muse/MuseApp.swift`, inside the `CommandGroup(after: .newItem)` block, after the `Button("Find Duplicates in Folder") { … }` (line ~187), add:

```swift
                Button("Manage iCloud Shares…") {
                    appState.iCloudSharesShown = true
                }
```

- [ ] **Step 5: Build to verify it compiles**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Views/ManageICloudSharesView.swift Muse/Muse/Models/AppState.swift Muse/Muse/ContentView.swift Muse/Muse/MuseApp.swift
git commit -m "feat: Manage iCloud Shares… File-menu command + sheet"
```

---

### Task 8: Localization

**Files:**
- Modify: `Muse/Muse/Localizable.xcstrings` (via export tool, then fill fr)

**Interfaces:** none.

- [ ] **Step 1: Run the localization export**

Run:
```bash
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj \
  -localizationPath /tmp/muse-loc -exportLanguage fr 2>&1 | tail -3
```
Expected: writes every new key into the source `Localizable.xcstrings` (the export does the write-back; a plain build does not).

- [ ] **Step 2: Confirm the new keys are present and untranslated**

Run:
```bash
grep -c "Share to iCloud" Muse/Muse/Localizable.xcstrings
grep -c "Manage iCloud Shares" Muse/Muse/Localizable.xcstrings
```
Expected: each ≥ 1.

- [ ] **Step 3: Fill the French values**

Edit `Muse/Muse/Localizable.xcstrings` and supply `fr` strings for the new keys, then mark them translated. Values:

| Key (English) | French |
|---|---|
| `Share to iCloud…` | `Partager sur iCloud…` |
| `Manage iCloud Shares…` | `Gérer les partages iCloud…` |
| `iCloud Shares` | `Partages iCloud` |
| `No iCloud shares yet.` | `Aucun partage iCloud pour l’instant.` |
| `Copying images…` | `Copie des images…` |
| `Uploading to iCloud… %lld of %lld` | `Téléversement vers iCloud… %lld sur %lld` |
| `Opening share…` | `Ouverture du partage…` |
| `%lld images · %@` | `%lld images · %@` |
| `Sign in to iCloud and turn on iCloud Drive to share to iCloud.` | `Connectez-vous à iCloud et activez iCloud Drive pour partager sur iCloud.` |
| `Couldn't copy the images into iCloud.` | `Impossible de copier les images dans iCloud.` |
| `This collection has no images to share.` | `Cette collection n’a aucune image à partager.` |
| `Delete this iCloud share and free the space` | `Supprimer ce partage iCloud et libérer l’espace` |
| `Delete iCloud share` | `Supprimer le partage iCloud` |
| `Collection` | (already present — leave as-is) |

(The exact interpolation key spelling — e.g. `%lld of %lld` vs `Uploading to iCloud… %lld of %lld` — is whatever the exporter wrote; match the key it produced.)

- [ ] **Step 4: Verify no remaining untranslated count for the new keys**

Run:
```bash
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj \
  -localizationPath /tmp/muse-loc2 -exportLanguage fr 2>&1 | tail -3
```
Expected: reports 0 untranslated for the strings (or only the standing runtime-variable INFO-card keys noted in CLAUDE.md, which are unrelated).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Localizable.xcstrings
git commit -m "i18n: French strings for iCloud collection share"
```

---

### Task 9: Full test suite, docs, manual verification checklist

**Files:**
- Modify: `docs/session-log.md` (new dated entry)
- Modify: `CLAUDE.md` (Implementation-status table row + one durable note)
- Modify: `docs/architecture-map.md` (the new `Sharing/` files)

- [ ] **Step 1: Run the full unit suite (must stay green)**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`. The three new test classes (`ICloudSharePathsTests`, `ICloudShareStoreTests`, `UploadTallyTests`) run with the rest.

- [ ] **Step 2: Document the manual (release-signed) verification checklist**

iCloud I/O can't run in a Debug build (entitlements stripped). Record this checklist in the session-log entry for whoever runs the signed build:

1. Open a collection with a handful of images → share menu → **Share to iCloud…**.
2. Progress sheet shows Copying → Uploading N of N → the macOS share sheet appears anchored to the window.
3. Pick **Copy Link**; paste in a browser → Apple's iCloud Drive folder page renders the images, view/download only.
4. In Finder, `iCloud Drive ▸ Muse ▸ Shared Collections ▸ <collection>` contains the copied images.
5. **File ▸ Manage iCloud Shares…** lists the share (name · count · date).
6. **Delete** in that list removes the Finder folder and the row.
7. Re-share the same collection → reuses the same folder (no duplicate), refreshed contents.
8. With iCloud Drive signed out → **Share to iCloud…** shows the "Sign in to iCloud" message and aborts cleanly.

- [ ] **Step 3: Update the docs**

Add a `docs/session-log.md` entry dated 2026-06-25 ("iCloud collection share") summarizing: the two-backend plan (iCloud now, Drive later), why iCloud can't be the zero-touch path (no public-link API), the container reuse (`ICloudZone`), the `Shared Collections/` subtree, the Debug-can't-test constraint, and the manual checklist from Step 2.

Add a row to the **Implementation status** table in `CLAUDE.md`:

```
| Polish 17 — iCloud collection share (copy collection into the app's iCloud zone → native share sheet for Copy Link; File-menu "Manage iCloud Shares…" to delete/reclaim; pure path/store/upload-tally units, iCloud I/O integration-only) | ✅ built, unmerged | `feat/icloud-collection-share` |
```

Add one durable note under **Durable constraints & gotchas** in `CLAUDE.md`:

> - **iCloud collection share writes ONLY under the app container's `Documents/Shared Collections/`** (via `ICloudZone.folderURL()`). It reuses the existing public-scoped container — no new entitlement. Debug builds strip iCloud, so the copy→upload→share path is verifiable only in a release-signed build; all pure logic (`ICloudSharePaths`, `ICloudShareStore`, `UploadTally`) is unit-tested. The Drive share backend is a separate future feature; the iCloud helper adds NO network code.

Add the new files to `docs/architecture-map.md` under a `Sharing/` heading: `ICloudSharePaths`, `ICloudShareRecord`/`ICloudShareStore`, `UploadTally`, `ICloudShareService`; and the two views (`ICloudShareProgressView`, `ManageICloudSharesView`).

- [ ] **Step 4: Commit**

```bash
git add docs/session-log.md CLAUDE.md docs/architecture-map.md
git commit -m "docs: record iCloud collection share (Polish 17)"
```

---

## Self-Review (completed during planning)

- **Spec coverage:** entry point (Task 6), destination folder + reuse (Tasks 1, 4), copy + dataless download-then-copy (Task 4), upload wait (Tasks 3, 4), native share sheet (Task 5), shared-list record + File-menu management + delete-to-reclaim (Tasks 2, 7), no-network / container-only writes (Global Constraints + Task 4), Debug-can't-test + integration-only (Tasks 4, 9), localization (Task 8). All spec sections map to a task.
- **Placeholder scan:** no TBD/TODO; every code step shows complete code.
- **Type consistency:** `ICloudShareService.Phase` cases, `ICloudShareRecord` fields, `ICloudSharePaths`/`ICloudShareStore`/`UploadTally` signatures are used identically across Tasks 4–7.
