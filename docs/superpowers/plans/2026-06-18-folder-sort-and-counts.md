# Sidebar Folder Sort + Live Counts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a sort control (Manual/Name/Date Modified/Size) at the top of the sidebar and a live per-folder file count on each top-level folder row, with the count swapping for the drag grip on hover in Manual mode.

**Architecture:** A nonisolated `FolderStats.compute` produces a `FolderStat` (immediate + recursive counts, recursive size, recursive latest-mtime) per top-level folder; a `@MainActor` `FolderStatCache` computes these off-main, caches them, and keeps them live via an FSEvents watch over all root paths. A pure `FolderSort.order` comparator orders the rows. `SidebarView` gains the sort menu, sorted display order, the count, and the count→grip hover swap (Manual only); sorted modes are read-only.

**Tech Stack:** SwiftUI, AppKit, CoreServices (FSEvents), XCTest, GRDB (unaffected).

## Global Constraints

- Min macOS **14.6**; `.onChange(of:)` uses the two-parameter (macOS 14) form.
- **No network calls.** Pure filesystem + UserDefaults only.
- GRDB is unaffected by this feature.
- Files are never deleted by this feature; it only reads folder contents.
- The reorder gesture from the prior session (live `DragGesture`, opaque overlay, parting) stays intact and is active **only in Manual mode**.
- "Files the grid shows" = every non-folder entry (packages count as files), via the same enumeration `FolderReader.files` / `FileManager.enumerator` use — NOT filtered by `hasNativeViewer`. The count must reuse that notion so it matches the grid exactly.
- Count follows `AppState.showSubfolders`: off → immediate, on → recursive. Size and Date Modified are always recursive aggregates (toggle-independent).
- SourceKit "Cannot find type" errors during edits are noise — verify with `xcodebuild ... build`.

---

### Task 1: `FolderStat` value type + pure aggregation

**Files:**
- Create: `Muse/Muse/Filesystem/FolderStat.swift`
- Test: `Muse/MuseTests/FolderStatTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces:
  - `struct FolderStat: Equatable { var immediateFileCount: Int; var recursiveFileCount: Int; var totalSize: Int64; var latestModified: Date? }`
  - `enum FolderStats { static func compute(folder: URL, showHidden: Bool = false) -> FolderStat; static func root(containing path: String, in roots: [URL]) -> URL? }`

- [ ] **Step 1: Write the failing tests**

Create `Muse/MuseTests/FolderStatTests.swift`:

```swift
import XCTest
@testable import Muse

final class FolderStatTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testComputeImmediateRecursiveSizeLatest() throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }

        try Data([1, 2, 3]).write(to: root.appendingPathComponent("a.txt"))   // 3 bytes
        try Data([1, 2]).write(to: root.appendingPathComponent("b.txt"))      // 2 bytes
        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let deep = sub.appendingPathComponent("c.txt")
        try Data([1, 2, 3, 4]).write(to: deep)                                // 4 bytes
        let newest = Date().addingTimeInterval(120)
        try fm.setAttributes([.modificationDate: newest], ofItemAtPath: deep.path)

        let stat = FolderStats.compute(folder: root)
        XCTAssertEqual(stat.immediateFileCount, 2)   // a.txt, b.txt (not sub)
        XCTAssertEqual(stat.recursiveFileCount, 3)   // + c.txt
        XCTAssertEqual(stat.totalSize, 9)
        XCTAssertNotNil(stat.latestModified)
        XCTAssertEqual(stat.latestModified!.timeIntervalSince1970,
                       newest.timeIntervalSince1970, accuracy: 2)
    }

    func testComputeEmptyFolder() throws {
        let fm = FileManager.default
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let stat = FolderStats.compute(folder: root)
        XCTAssertEqual(stat.immediateFileCount, 0)
        XCTAssertEqual(stat.recursiveFileCount, 0)
        XCTAssertEqual(stat.totalSize, 0)
        XCTAssertNil(stat.latestModified)
    }

    func testRootContainingLongestMatch() {
        let a = URL(fileURLWithPath: "/Users/x/Photos")
        let b = URL(fileURLWithPath: "/Users/x/Photos/2024")
        XCTAssertEqual(FolderStats.root(containing: "/Users/x/Photos/2024/img.jpg", in: [a, b]), b)
        XCTAssertEqual(FolderStats.root(containing: "/Users/x/Photos/old.jpg", in: [a, b]), a)
        XCTAssertNil(FolderStats.root(containing: "/Users/y/z.jpg", in: [a, b]))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd "Muse" && xcodebuild -scheme Muse -configuration Debug build-for-testing 2>&1 | tail -5`
Expected: FAIL — `Cannot find 'FolderStats' in scope` / `Cannot find type 'FolderStat'`.

- [ ] **Step 3: Implement `FolderStat.swift`**

Create `Muse/Muse/Filesystem/FolderStat.swift`:

```swift
//
//  FolderStat.swift
//  Muse
//
//  Aggregate stats for a top-level sidebar folder — file counts (immediate +
//  recursive), recursive total size, recursive newest mtime. Pure + nonisolated
//  so it runs off the main thread. Counts mirror the grid's file notion (every
//  non-folder entry; packages count as files, not descended-as-folders), so the
//  sidebar number always matches what the grid would show.
//

import Foundation

nonisolated struct FolderStat: Equatable {
    var immediateFileCount: Int
    var recursiveFileCount: Int
    var totalSize: Int64
    var latestModified: Date?
}

nonisolated enum FolderStats {
    /// Walk `folder` and aggregate counts/size/latest-mtime. Immediate = depth-1
    /// non-folder entries; recursive = all non-folder entries beneath it.
    static func compute(folder: URL, showHidden: Bool = false) -> FolderStat {
        let fm = FileManager.default
        let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]

        var immediate = 0
        if let entries = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: opts
        ) {
            for url in entries where !isPlainDirectory(url) { immediate += 1 }
        }

        var recursive = 0
        var size: Int64 = 0
        var latest: Date?
        if let en = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey
            ],
            options: opts
        ) {
            for case let url as URL in en {
                let v = try? url.resourceValues(forKeys: [
                    .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey
                ])
                let isDir = v?.isDirectory == true
                let isPackage = v?.isPackage == true
                if isDir && !isPackage { continue }          // skip plain folders
                recursive += 1
                size += Int64(v?.fileSize ?? 0)
                if let m = v?.contentModificationDate, latest == nil || m > latest! {
                    latest = m
                }
            }
        }

        return FolderStat(immediateFileCount: immediate,
                          recursiveFileCount: recursive,
                          totalSize: size,
                          latestModified: latest)
    }

    /// Which watched root contains `path` (longest prefix wins, since roots can
    /// nest). Pure → unit-testable for the FSEvents path→root mapping.
    static func root(containing path: String, in roots: [URL]) -> URL? {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        var best: URL?
        var bestLen = -1
        for root in roots {
            let rp = root.standardizedFileURL.path
            if (std == rp || std.hasPrefix(rp + "/")) && rp.count > bestLen {
                best = root
                bestLen = rp.count
            }
        }
        return best
    }

    private static func isPlainDirectory(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return v?.isDirectory == true && v?.isPackage != true
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd "Muse" && xcodebuild -scheme Muse -configuration Debug test -only-testing:MuseTests/FolderStatTests 2>&1 | grep -E "Executed|TEST"`
Expected: `Executed 3 tests, with 0 failures` / `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Filesystem/FolderStat.swift Muse/MuseTests/FolderStatTests.swift
git commit -m "feat: FolderStat + pure folder aggregation (counts/size/mtime)"
```

---

### Task 2: `FolderSortMode` + persistence + pure comparator

**Files:**
- Create: `Muse/Muse/Models/FolderSortMode.swift`
- Modify: `Muse/Muse/Settings/AppSettings.swift`
- Test: `Muse/MuseTests/FolderSortTests.swift`

**Interfaces:**
- Consumes: `FolderStat` (Task 1).
- Produces:
  - `enum FolderSortMode: String, CaseIterable, Identifiable { case manual, name, dateModified, size; var id: String; var label: String }`
  - `enum FolderSort { struct Item: Equatable { let id: UUID; let name: String; let stat: FolderStat? }; static func order(_ items: [Item], by mode: FolderSortMode) -> [UUID] }`
  - `AppSettings.folderSortMode: FolderSortMode { get set }` (+ `folderSortModeKey`)

- [ ] **Step 1: Write the failing tests**

Create `Muse/MuseTests/FolderSortTests.swift`:

```swift
import XCTest
@testable import Muse

final class FolderSortTests: XCTestCase {
    private func item(_ name: String, stat: FolderStat? = nil) -> FolderSort.Item {
        FolderSort.Item(id: UUID(), name: name, stat: stat)
    }
    private func names(_ ids: [UUID], _ items: [FolderSort.Item]) -> [String] {
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.name) })
        return ids.map { byId[$0]! }
    }
    private func stat(size: Int64 = 0, modified: Date? = nil) -> FolderStat {
        FolderStat(immediateFileCount: 0, recursiveFileCount: 0,
                   totalSize: size, latestModified: modified)
    }

    func testManualPreservesOrder() {
        let items = [item("b"), item("a"), item("c")]
        XCTAssertEqual(names(FolderSort.order(items, by: .manual), items), ["b", "a", "c"])
    }

    func testNameLocalizedCaseInsensitiveNumeric() {
        let items = [item("Banana"), item("apple"), item("Cherry"), item("file10"), item("file2")]
        XCTAssertEqual(names(FolderSort.order(items, by: .name), items),
                       ["apple", "Banana", "Cherry", "file2", "file10"])
    }

    func testDateNewestFirstNilLast() {
        let now = Date()
        let items = [
            item("old", stat: stat(modified: now.addingTimeInterval(-100))),
            item("new", stat: stat(modified: now)),
            item("none", stat: nil)
        ]
        XCTAssertEqual(names(FolderSort.order(items, by: .dateModified), items),
                       ["new", "old", "none"])
    }

    func testSizeLargestFirstNilLast() {
        let items = [
            item("small", stat: stat(size: 10)),
            item("big", stat: stat(size: 100)),
            item("none", stat: nil),
            item("mid", stat: stat(size: 50))
        ]
        XCTAssertEqual(names(FolderSort.order(items, by: .size), items),
                       ["big", "mid", "small", "none"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd "Muse" && xcodebuild -scheme Muse -configuration Debug build-for-testing 2>&1 | tail -5`
Expected: FAIL — `Cannot find 'FolderSort' in scope`.

- [ ] **Step 3: Implement `FolderSortMode.swift`**

Create `Muse/Muse/Models/FolderSortMode.swift`:

```swift
//
//  FolderSortMode.swift
//  Muse
//
//  How the sidebar's top-level folders are ordered. Manual = the user's hand
//  arrangement (BookmarkStore.roots order, drag-to-reorder). The other modes are
//  read-only sorted displays. `FolderSort.order` is a pure comparator over names
//  + FolderStat, so it's unit-testable.
//

import Foundation

enum FolderSortMode: String, CaseIterable, Identifiable {
    case manual, name, dateModified, size

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: return "Manual"
        case .name: return "Name"
        case .dateModified: return "Date Modified"
        case .size: return "Size"
        }
    }
}

nonisolated enum FolderSort {
    struct Item: Equatable {
        let id: UUID
        let name: String
        let stat: FolderStat?
    }

    /// Ordered ids for `items` under `mode`. Manual → input order unchanged.
    /// Name A→Z (localized, case-insensitive, numeric-aware); Date newest-first;
    /// Size largest-first. All non-Manual modes break ties by name, and items
    /// missing a stat sort after those that have one.
    static func order(_ items: [Item], by mode: FolderSortMode) -> [UUID] {
        switch mode {
        case .manual:
            return items.map(\.id)
        case .name:
            return items.sorted(by: nameAscending).map(\.id)
        case .dateModified:
            return items.sorted(by: dateNewestFirst).map(\.id)
        case .size:
            return items.sorted(by: sizeLargestFirst).map(\.id)
        }
    }

    private static func nameAscending(_ a: Item, _ b: Item) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    private static func dateNewestFirst(_ a: Item, _ b: Item) -> Bool {
        let da = a.stat?.latestModified
        let db = b.stat?.latestModified
        if let da, let db, da != db { return da > db }
        if (da == nil) != (db == nil) { return da != nil }   // has-date before nil
        return nameAscending(a, b)
    }

    private static func sizeLargestFirst(_ a: Item, _ b: Item) -> Bool {
        let sa = a.stat?.totalSize
        let sb = b.stat?.totalSize
        if let sa, let sb, sa != sb { return sa > sb }
        if (sa == nil) != (sb == nil) { return sa != nil }
        return nameAscending(a, b)
    }
}
```

- [ ] **Step 4: Add persistence to `AppSettings.swift`**

In `Muse/Muse/Settings/AppSettings.swift`, add inside `enum AppSettings` (after the `showFileNames` accessor, before the closing brace):

```swift
    static let folderSortModeKey = "folderSortMode"

    /// Sidebar top-level folder sort mode. Default `.manual`. Unset → manual.
    static var folderSortMode: FolderSortMode {
        get {
            (UserDefaults.standard.string(forKey: folderSortModeKey))
                .flatMap(FolderSortMode.init(rawValue:)) ?? .manual
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: folderSortModeKey) }
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd "Muse" && xcodebuild -scheme Muse -configuration Debug test -only-testing:MuseTests/FolderSortTests 2>&1 | grep -E "Executed|TEST"`
Expected: `Executed 4 tests, with 0 failures` / `TEST SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Models/FolderSortMode.swift Muse/Muse/Settings/AppSettings.swift Muse/MuseTests/FolderSortTests.swift
git commit -m "feat: FolderSortMode + persisted setting + pure comparator"
```

---

### Task 3: `FolderStatCache` (live, cached) + AppState wiring

**Files:**
- Create: `Muse/Muse/Filesystem/FolderStatCache.swift`
- Modify: `Muse/Muse/Filesystem/FolderWatcher.swift` (add a multi-path `watch(urls:)` overload)
- Modify: `Muse/Muse/Models/AppState.swift` (own the cache, drive it, forward its changes)

**Interfaces:**
- Consumes: `FolderStat`, `FolderStats.compute`, `FolderStats.root(containing:in:)` (Task 1); `FolderWatcher` (existing).
- Produces:
  - `@MainActor final class FolderStatCache: ObservableObject { func stat(for url: URL) -> FolderStat?; func update(roots: [URL]) }`
  - `FolderWatcher.watch(urls: [URL], recursive: Bool = false)`
  - `AppState.folderStats: FolderStatCache` (public `let`)

- [ ] **Step 1: Add the multi-path watch overload to `FolderWatcher.swift`**

In `Muse/Muse/Filesystem/FolderWatcher.swift`, replace the existing `func watch(url: URL, recursive: Bool = false) {` signature line and the `let pathsToWatch = [url.path] as CFArray` line by generalizing to a urls array. Concretely, change the method declaration:

```swift
    func watch(url: URL, recursive: Bool = false) {
        watch(urls: [url], recursive: recursive)
    }

    func watch(urls: [URL], recursive: Bool = false) {
```

and change the paths line inside the (now `urls`) method from:

```swift
        let pathsToWatch = [url.path] as CFArray
```

to:

```swift
        let pathsToWatch = urls.map(\.path) as CFArray
        guard !urls.isEmpty else { stop(); return }
```

(The rest of the method body — context, flags, callback, create/start — is unchanged. The `guard !urls.isEmpty` sits right after `stop()` at the top of the `urls` method; move `stop()` to be the first line of `watch(urls:)` if it isn't already.)

- [ ] **Step 2: Verify the watcher still builds**

Run: `cd "Muse" && xcodebuild -scheme Muse -configuration Debug build 2>&1 | grep -E "error:|BUILD" | head`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Implement `FolderStatCache.swift`**

Create `Muse/Muse/Filesystem/FolderStatCache.swift`:

```swift
//
//  FolderStatCache.swift
//  Muse
//
//  Caches a FolderStat per top-level folder for the sidebar's counts + sort.
//  Computes off-main; keeps stats live via an FSEvents watch over ALL root paths
//  (recursive — FSEvents reports descendants), so adds/removes/edits anywhere
//  under a root refresh that root's number. Recomputes are coalesced.
//

import Foundation

@MainActor
final class FolderStatCache: ObservableObject {
    /// Stats keyed by standardized root path.
    @Published private(set) var stats: [String: FolderStat] = [:]

    private var roots: [URL] = []
    private var watcher: FolderWatcher?
    private var pending: Set<String> = []
    private var debounce: DispatchWorkItem?

    func stat(for url: URL) -> FolderStat? {
        stats[url.standardizedFileURL.path]
    }

    /// Point the cache at the current top-level folders: (re)start the watcher,
    /// drop stats for folders that went away, and recompute each root. Safe to
    /// call repeatedly (launch + whenever the roots change).
    func update(roots newRoots: [URL]) {
        roots = newRoots.map { $0.standardizedFileURL }
        let live = Set(roots.map(\.path))
        stats = stats.filter { live.contains($0.key) }

        watcher = FolderWatcher { [weak self] paths in
            self?.handle(paths: paths)   // delivered on main by FolderWatcher.fire
        }
        watcher?.watch(urls: roots)

        for r in roots { recompute(r) }
    }

    private func handle(paths: [String]) {
        let affected = Set(paths.compactMap {
            FolderStats.root(containing: $0, in: roots)?.standardizedFileURL.path
        })
        guard !affected.isEmpty else { return }
        pending.formUnion(affected)
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let todo = self.pending
            self.pending.removeAll()
            for p in todo { self.recompute(URL(fileURLWithPath: p)) }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func recompute(_ root: URL) {
        let key = root.standardizedFileURL.path
        Task.detached(priority: .utility) { [weak self] in
            let stat = FolderStats.compute(folder: root)
            await MainActor.run { self?.stats[key] = stat }
        }
    }
}
```

- [ ] **Step 4: Wire the cache into `AppState`**

In `Muse/Muse/Models/AppState.swift`, add the stored property near the other sidebar stores (next to `bookmarks` / `stars`):

```swift
    /// Live per-top-level-folder stats for the sidebar counts + sort.
    let folderStats = FolderStatCache()
```

Then forward its changes to AppState (mirroring the existing `stars` forwarding) and seed it. Find the `stars` `objectWillChange` forwarding block in `init` (the sink that calls `self.objectWillChange.send()`); immediately after it, add:

```swift
        folderStatsCancellable = folderStats.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
```

Add the cancellable storage near the other `…Cancellable` properties:

```swift
    private var folderStatsCancellable: AnyCancellable?
```

Finally, at the END of `rebuildRootNodes(roots:)` (so the cache always tracks the current top-level nodes — local roots + the iCloud home), add:

```swift
        folderStats.update(roots: rootNodes.map(\.url))
```

(`rebuildRootNodes` is `@MainActor` and already rebuilds `rootNodes`; this runs synchronously after, including from the `bookmarks.$roots` sink, so added/removed roots refresh the cache.)

- [ ] **Step 5: Build + smoke-run**

Run: `cd "Muse" && xcodebuild -scheme Muse -configuration Debug build 2>&1 | grep -E "error:|BUILD" | head`
Expected: `** BUILD SUCCEEDED **`.

Then: `killall Muse 2>/dev/null; open "$HOME/Library/Developer/Xcode/DerivedData/Muse-aahfzalxvatoflcsfioxphwcoqes/Build/Products/Debug/Muse.app"`
Manual check: app launches; no crash. (Counts aren't shown until Task 4 — this task just confirms the cache builds + runs.)

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Filesystem/FolderStatCache.swift Muse/Muse/Filesystem/FolderWatcher.swift Muse/Muse/Models/AppState.swift
git commit -m "feat: FolderStatCache — live, cached folder stats via FSEvents over roots"
```

---

### Task 4: `SidebarView` — sort menu, sorted order, count + hover swap

**Files:**
- Modify: `Muse/Muse/Views/SidebarView.swift`

**Interfaces:**
- Consumes: `FolderSortMode`, `FolderSort.order`, `AppSettings.folderSortMode` (Task 2); `AppState.folderStats` + `FolderStatCache.stat(for:)` (Task 3); `AppState.showSubfolders` (existing).
- Produces: no new cross-file symbols (all internal to `SidebarView`).

- [ ] **Step 1: Add sort-mode state + a setter to `SidebarView`**

In `struct SidebarView`, add near the other `@State` properties:

```swift
    /// Active top-level folder sort mode (persisted via AppSettings).
    @State private var sortMode: FolderSortMode = AppSettings.folderSortMode
```

And add a setter method (place it next to `commitReorder` / `resetDrag`):

```swift
    private func setSortMode(_ mode: FolderSortMode) {
        AppSettings.folderSortMode = mode
        withAnimation(.easeInOut(duration: 0.2)) { sortMode = mode }
    }

    /// Top-level rows in display order: BookmarkStore order for Manual, otherwise
    /// the comparator over name + cached stat.
    private var displayedReorderableNodes: [FolderNode] {
        let nodes = reorderableNodes
        guard sortMode != .manual else { return nodes }
        let items = nodes.map {
            FolderSort.Item(id: $0.id, name: $0.displayName,
                            stat: appState.folderStats.stat(for: $0.url))
        }
        let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        return FolderSort.order(items, by: sortMode).compactMap { byId[$0] }
    }

    /// The toggle-scoped count to display for a top-level folder, or nil if its
    /// stat hasn't been computed yet.
    private func topLevelCount(for node: FolderNode) -> Int? {
        guard let stat = appState.folderStats.stat(for: node.url) else { return nil }
        return appState.showSubfolders ? stat.recursiveFileCount : stat.immediateFileCount
    }
```

- [ ] **Step 2: Add the sort header + use the sorted order in `body`**

In `body`, inside the `else` branch (where the `ScrollView` is), add a header ABOVE the `ScrollView` (so it doesn't scroll). Replace:

```swift
            } else {
                ScrollView {
```

with:

```swift
            } else {
                sortHeader
                ScrollView {
```

Then change the roots `ForEach` to iterate the sorted list. Replace:

```swift
                        ForEach(Array(reorderableNodes.enumerated()),
                                id: \.element.id) { pair in
                            rootRow(pair.element, index: pair.offset)
                        }
```

with:

```swift
                        ForEach(Array(displayedReorderableNodes.enumerated()),
                                id: \.element.id) { pair in
                            rootRow(pair.element, index: pair.offset)
                        }
```

Add the `sortHeader` view (place it next to `emptyState`):

```swift
    private var sortHeader: some View {
        HStack {
            Menu {
                ForEach(FolderSortMode.allCases) { mode in
                    Button { setSortMode(mode) } label: {
                        if sortMode == mode {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Sort: \(sortMode.label)")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
```

- [ ] **Step 3: Gate the drag on Manual mode + pass the count into rows**

In `rootRow(_:index:)`, pass `reorder:` only in Manual mode and pass the count. Replace the `FolderTreeNode(node: node, depth: 0, reorder: ReorderContext(` line and its closure with a computed-context version. Concretely, change the start of the `if let model` branch:

```swift
        if let model = reorderableRoot(for: node) {
            FolderTreeNode(node: node, depth: 0,
                           topLevelCount: topLevelCount(for: node),
                           reorder: sortMode == .manual ? ReorderContext(
                onChanged: { value in
                    if draggingRoot?.id != model.id {
                        guard !rootFrames.isEmpty else { return }
                        draggingRoot = model
                        dragStartFrames = rootFrames
                    }
                    dragOffset = value.translation.height
                    let newTarget = reorderSlot(forY: value.location.y)
                    if newTarget != dropTarget {
                        withAnimation(.easeInOut(duration: 0.16)) { dropTarget = newTarget }
                    }
                },
                onEnded: { _ in commitReorder(moving: model) }
            ) : nil)
```

(The trailing modifiers — `.background(GeometryReader…)`, `.offset`, `.opacity` — stay exactly as they are. In non-Manual mode `reorder` is nil so there is no grip and no drag.)

Also update the iCloud node render and the non-reorderable `else` branch to pass a count. Change line `FolderTreeNode(node: icloud, depth: 0)` to:

```swift
                            FolderTreeNode(node: icloud, depth: 0,
                                           topLevelCount: topLevelCount(for: icloud))
```

and the `else { FolderTreeNode(node: node, depth: 0) }` inside `rootRow` to:

```swift
        } else {
            FolderTreeNode(node: node, depth: 0, topLevelCount: topLevelCount(for: node))
        }
```

- [ ] **Step 4: Add the `topLevelCount` property + count/grip swap to `FolderTreeNode`**

In `struct FolderTreeNode`, add the property (after `let depth: Int`):

```swift
    /// Toggle-scoped file count to show at the trailing edge (top-level rows
    /// only); nil for subfolders or before the stat is computed.
    var topLevelCount: Int? = nil
```

Then, in `row`, replace the existing grip block (the `if let reorder { Image(systemName: "line.3.horizontal") … }` block, including all its modifiers up to `.help("Drag to reorder")` and its closing brace) with a ZStack that holds the count AND the grip in the same trailing slot:

```swift
                // Trailing slot: the file count, which swaps in place for the
                // drag grip on hover (Manual mode only — `reorder` is non-nil only
                // then). During a drag the grip is shown via the floating overlay,
                // so in-list rows fall back to the count.
                if topLevelCount != nil || reorder != nil {
                    let showGrip = reorder != nil && isHovered && !isReordering
                    ZStack(alignment: .trailing) {
                        if let topLevelCount {
                            Text("\(topLevelCount)")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                                .opacity(showGrip ? 0 : 1)
                        }
                        if let reorder {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, height: 22)
                                .opacity(showGrip ? 1 : 0)
                                .contentShape(Rectangle())
                                .allowsHitTesting(isHovered || isReordering)
                                .highPriorityGesture(
                                    DragGesture(minimumDistance: 3,
                                                coordinateSpace: .named(SidebarView.reorderSpace))
                                        .onChanged { reorder.onChanged($0) }
                                        .onEnded { reorder.onEnded($0) }
                                )
                                .onTapGesture { appState.select(folder: node) }
                                .help("Drag to reorder")
                        }
                    }
                }
```

(The grip's gesture/hit-testing/tap are carried over verbatim from the prior implementation — only the count text and the `ZStack` wrapper + `showGrip` opacity gating are new.)

- [ ] **Step 5: Build**

Run: `cd "Muse" && xcodebuild -scheme Muse -configuration Debug build 2>&1 | grep -E "error:|BUILD" | head`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Run + manual verification**

Run: `killall Muse 2>/dev/null; open "$HOME/Library/Developer/Xcode/DerivedData/Muse-aahfzalxvatoflcsfioxphwcoqes/Build/Products/Debug/Muse.app"`

Verify:
- A `Sort: Manual ▾` menu sits at the top of the sidebar; the menu lists Manual / Name / Date Modified / Size with a checkmark on the active one; the choice persists across relaunch.
- Each top-level folder shows a small count at the right; toggling **show-subfolders** flips the count between immediate and recursive.
- In **Manual**, hovering a folder swaps the count for the `≡` grip; dragging reorders (grip stays through the drag); the count returns on release.
- In **Name / Date Modified / Size**, the folders display sorted, there is **no grip**, and dragging does nothing (count stays on hover).
- Add/remove a file in a folder (even a subfolder, or a folder you don't have selected) → its count updates within ~0.5s.

- [ ] **Step 7: Run the full test suite (no regressions)**

Run: `cd "Muse" && xcodebuild -scheme Muse -configuration Debug test 2>&1 | grep -E "Executed [0-9]+ tests|TEST SUCCEEDED|TEST FAILED" | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add Muse/Muse/Views/SidebarView.swift
git commit -m "feat: sidebar folder sort menu + live counts with count/grip hover swap"
```

---

## Self-Review

**Spec coverage:**
- Sort modes (Manual/Name/Date Modified/Size) + labeled menu at top + persistence → Task 2 (mode/comparator/persistence) + Task 4 (menu, sorted order).
- Manual draggable; sorted modes read-only; manual order preserved → Task 4 Step 3 (`reorder:` passed only when `sortMode == .manual`; `displayedReorderableNodes` sorts a copy, never mutates `BookmarkStore.roots`).
- Count follows show-subfolders; size/modified recursive → Task 1 (`FolderStat` fields) + Task 4 (`topLevelCount` picks immediate vs recursive; size/mtime always recursive in the stat).
- Count at far right; hover swaps to grip (Manual only); iCloud count, no grip → Task 4 Step 4 (ZStack swap; iCloud row passes `topLevelCount`, no `reorder`).
- Live updates on add/remove/edit incl. subfolders + unselected roots → Task 3 (`FolderStatCache` FSEvents over all roots, debounced recompute).
- Components (FolderStat/FolderStatCache, FolderSortMode, SidebarView, BookmarkStore unchanged) → Tasks 1–4; BookmarkStore intentionally untouched.
- Testing (comparator, aggregation, persistence-not-required-but-mode round-trips via enum) → Tasks 1 & 2 tests; UI verified by running (Task 4 Step 6).

**Placeholder scan:** none — every step has concrete code or an exact command + expected output.

**Type consistency:** `FolderStat` fields (`immediateFileCount`, `recursiveFileCount`, `totalSize`, `latestModified`) are used identically in Tasks 1/2/3/4. `FolderSort.Item(id:name:stat:)` and `FolderSort.order(_:by:)` match between Task 2 definition and Task 4 use. `FolderStatCache.stat(for:)` / `update(roots:)` match between Task 3 definition and Task 4 use. `FolderWatcher.watch(urls:)` matches between Task 3 Step 1 definition and the cache's use. `topLevelCount` and `reorder` parameter names on `FolderTreeNode` match between Task 4 Steps 3 and 4.

**Note for the implementer:** the DerivedData path in run commands (`Muse-aahfzalxvatoflcsfioxphwcoqes`) is this machine's; if `open` can't find the app, get the path from `xcodebuild -scheme Muse -showBuildSettings 2>/dev/null | grep -m1 TARGET_BUILD_DIR`.
