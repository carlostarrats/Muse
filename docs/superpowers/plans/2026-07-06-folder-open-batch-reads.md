# Folder-open batched reads (P4 + P6) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse the per-file DB read on folder open into one chunked `IN (...)` fetch per folder (P4), and fold the path→fileID N+1 in the analyze pass into the same batching pattern (P6) — with zero change to the per-file decision matrix or the reconcile write path.

**Architecture:** Extract the current per-file discovery decision (`isUnchanged` + the loop's dataless/force pre-checks) into ONE pure, side-effect-free function `Indexer.decideIndexAction(...)`. Both the retained single-file wrapper `isUnchanged` and the new batched discovery in `indexBatch` call it, so they cannot diverge. The batched discovery reads all stored identities for the folder in ~800-path chunks, diffs in memory, and batches the `last_seen` touch into one write. P6 adds a batched path→fileID resolver used by the analyze pass and the sidecar re-export.

**Tech Stack:** Swift, GRDB (async `queue.read`/`queue.write`), XCTest. Chunked `IN (...)` reads via `databaseQuestionMarks(count:)` + `stride(from:to:by:800)` (existing repo pattern).

## Global Constraints

- Min macOS 14.6; Swift; GRDB. GRDB reads/writes are async in async contexts (`try await queue.read/write`); the `indexBatch` discovery runs on the `Indexer` actor and uses SYNCHRONOUS `queue.read`/`queue.write` (matching the current `isUnchanged`, which is called from the actor).
- **iCloud change detection = content hash, NOT size/mtime.** The size/mtime fast path is LOCAL-ONLY (`isUbiquitous == false`). An iCloud file is trusted as unchanged on its stored hash alone. Re-introducing a size/mtime path for iCloud re-hashes the whole folder every visit (shipped bug).
- **NULL `content_hash` → re-hash**, checked BEFORE the iCloud-trust branch.
- **Dataless files are never hashed and never read for bytes** — `Indexer.isDataless` stays a per-file FS check, evaluated first.
- **Zero-byte-hash guard** in `HashService.sha256` stays untouched.
- **`reconcile` is UNTOUCHED.** `IndexerReconcileTests` (8 tests) must pass with zero edits.
- **Dedup-by-file-id** in the analyze pass: `seen` set + first-seen URL order preserved verbatim.
- Chunk size **800** (matches existing repo chunking).
- `xcodebuild -scheme Muse test` (503+ tests) must stay green.
- Verify in the running app after the code lands (repo rule): a fully-indexed folder (local AND iCloud) shows NO indexing pill on reopen.

---

### Task 1: Extract the pure decision function + refactor `isUnchanged` to delegate

**Files:**
- Modify: `Muse/Muse/Indexing/Indexer.swift:493–535` (add `IndexDecision`, `StoredIdentity`, `decideIndexAction`; rewrite `isUnchanged`)
- Test: `Muse/MuseTests/IndexerDecisionTests.swift` (new — pure, no DB)
- Test: `Muse/MuseTests/IndexerFastPathTests.swift` (new — DB-backed wrapper)

**Interfaces:**
- Produces:
  - `enum IndexDecision: Equatable { case unchanged, needsHashing, skipDataless }`
  - `struct Indexer.StoredIdentity: Equatable { let fileID: String; let contentHash: String?; let size: Int64?; let mtime: Int64?; let lastSeen: Int64 }`
  - `static func Indexer.decideIndexAction(isDataless: Bool, force: Bool, isUbiquitous: Bool, stored: StoredIdentity?, onDiskSize: Int64?, onDiskMtime: Int64?) -> IndexDecision`
  - `isUnchanged(absPath:sizeBytes:modifiedAt:isUbiquitous:now:queue:) -> Bool` (signature unchanged; now delegates to `decideIndexAction`)

- [ ] **Step 1: Write the failing pure-decision test**

Create `Muse/MuseTests/IndexerDecisionTests.swift`:

```swift
//
//  IndexerDecisionTests.swift
//  MuseTests
//
//  Exhaustive truth-table coverage for the folder-open discovery decision.
//  Pure function, no database — one assertion per branch of decideIndexAction.
//

import XCTest
@testable import Muse

final class IndexerDecisionTests: XCTestCase {

    private func stored(hash: String? = "h1", size: Int64? = 100, mtime: Int64? = 50,
                        lastSeen: Int64 = 0) -> Indexer.StoredIdentity {
        Indexer.StoredIdentity(fileID: "f1", contentHash: hash, size: size,
                               mtime: mtime, lastSeen: lastSeen)
    }

    // Row 1: dataless wins over everything, incl. force.
    func testDatalessSkipsEvenUnderForce() {
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: true, force: false,
            isUbiquitous: false, stored: nil, onDiskSize: 1, onDiskMtime: 1), .skipDataless)
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: true, force: true,
            isUbiquitous: true, stored: stored(), onDiskSize: 100, onDiskMtime: 50), .skipDataless)
    }

    // Row 2: force hashes regardless of stored metadata.
    func testForceNeedsHashing() {
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: false, force: true,
            isUbiquitous: false, stored: stored(), onDiskSize: 100, onDiskMtime: 50), .needsHashing)
    }

    // Row 3: no stored identity → hash.
    func testUnknownPathNeedsHashing() {
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: false, force: false,
            isUbiquitous: false, stored: nil, onDiskSize: 100, onDiskMtime: 50), .needsHashing)
    }

    // Row 4: NULL content_hash → hash, even for iCloud (checked before the trust branch).
    func testNullHashNeedsHashingIncludingICloud() {
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: false, force: false,
            isUbiquitous: false, stored: stored(hash: nil), onDiskSize: 100, onDiskMtime: 50), .needsHashing)
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: false, force: false,
            isUbiquitous: true, stored: stored(hash: nil), onDiskSize: 100, onDiskMtime: 50), .needsHashing)
    }

    // Row 5: iCloud trusts the stored hash and IGNORES size/mtime (deliberately mismatched).
    func testICloudTrustsHashIgnoresMetadata() {
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: false, force: false,
            isUbiquitous: true, stored: stored(size: 100, mtime: 50),
            onDiskSize: 999, onDiskMtime: 999), .unchanged)
    }

    // Row 6: local, exact size + mtime match → unchanged.
    func testLocalMatchUnchanged() {
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: false, force: false,
            isUbiquitous: false, stored: stored(size: 100, mtime: 50),
            onDiskSize: 100, onDiskMtime: 50), .unchanged)
    }

    // Rows 7–8: local, size OR mtime mismatch → hash.
    func testLocalSizeMismatchNeedsHashing() {
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: false, force: false,
            isUbiquitous: false, stored: stored(size: 100, mtime: 50),
            onDiskSize: 101, onDiskMtime: 50), .needsHashing)
    }
    func testLocalMtimeMismatchNeedsHashing() {
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: false, force: false,
            isUbiquitous: false, stored: stored(size: 100, mtime: 50),
            onDiskSize: 100, onDiskMtime: 51), .needsHashing)
    }

    // Nil-optional equality quirk: nil == nil → unchanged (preserves current behavior).
    func testLocalNilSizeEqualityUnchanged() {
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: false, force: false,
            isUbiquitous: false, stored: stored(size: nil, mtime: 50),
            onDiskSize: nil, onDiskMtime: 50), .unchanged)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/IndexerDecisionTests 2>&1 | tail -20`
Expected: COMPILE FAILURE — `IndexDecision` / `Indexer.StoredIdentity` / `decideIndexAction` do not exist yet.

- [ ] **Step 3: Add the enum, struct, and pure function**

In `Muse/Muse/Indexing/Indexer.swift`, insert immediately above the `// MARK: - Fast-path helpers` line (currently `Indexer.swift:480`):

```swift
    // MARK: - Discovery decision (pure)

    /// The discovery-time decision for a single enumerated file. There is
    /// deliberately no `.changed` case — whether edited bytes are genuinely new
    /// content is not knowable at discovery (it needs the hash); that belongs to
    /// `reconcile`, AFTER hashing. Discovery is skip / hash / skip-dataless only.
    enum IndexDecision: Equatable {
        case unchanged      // known + alive + hash present + (iCloud OR local size&mtime match) → no hashing
        case needsHashing   // unknown path / missing file row / NULL content_hash / local size|mtime mismatch → hash
        case skipDataless   // dataless iCloud placeholder — no local bytes to hash yet
    }

    /// The stored identity of an alive path, read from the DB. Packaged as a
    /// pure value so `decideIndexAction` needs no queue and is exhaustively
    /// unit-testable. A `nil` StoredIdentity means "no alive path / null
    /// file_id / missing file row" — the old read guards that returned nil.
    struct StoredIdentity: Equatable {
        let fileID: String
        let contentHash: String?
        let size: Int64?
        let mtime: Int64?
        let lastSeen: Int64
    }

    /// Pure discovery decision — replicates the old `isUnchanged` + the
    /// discovery loop's dataless/force pre-checks EXACTLY, with NO side effects
    /// (the `last_seen` touch is handled by the caller so it can be batched).
    ///
    /// Ordering is load-bearing:
    ///   1. dataless FIRST (skipped before force, before any compare)
    ///   2. force → hash (ignores stored metadata)
    ///   3. no stored identity → hash
    ///   4. NULL content_hash → hash (iCloud AND local, BEFORE the iCloud trust)
    ///   5. iCloud (isUbiquitous) → trust the stored hash; size/mtime IGNORED
    ///   6. local → require EXACT size AND mtime match, else hash
    static func decideIndexAction(
        isDataless: Bool,
        force: Bool,
        isUbiquitous: Bool,
        stored: StoredIdentity?,
        onDiskSize: Int64?,
        onDiskMtime: Int64?
    ) -> IndexDecision {
        if isDataless { return .skipDataless }
        if force { return .needsHashing }
        guard let stored else { return .needsHashing }
        guard stored.contentHash != nil else { return .needsHashing }
        if isUbiquitous { return .unchanged }
        guard stored.size == onDiskSize, stored.mtime == onDiskMtime else { return .needsHashing }
        return .unchanged
    }
```

- [ ] **Step 4: Run the pure-decision test to verify it passes**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/IndexerDecisionTests 2>&1 | tail -20`
Expected: PASS (all 9 test methods).

- [ ] **Step 5: Write the failing DB-backed wrapper test**

Create `Muse/MuseTests/IndexerFastPathTests.swift`. `isUnchanged` is `private`, so exercise it through the shared `decideIndexAction` for the decision AND assert the DB-side effects by driving the retained wrapper indirectly. Since `isUnchanged` is private, this task ALSO makes it `internal` (drop `private`) so the wrapper's DB wiring + touch side-effect are directly testable:

```swift
//
//  IndexerFastPathTests.swift
//  MuseTests
//
//  DB-backed coverage that the retained single-file `isUnchanged` wrapper wires
//  stored rows into decideIndexAction correctly and applies the last_seen touch.
//

import XCTest
import GRDB
@testable import Muse

final class IndexerFastPathTests: XCTestCase {

    private func freshQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func seed(_ q: DatabaseQueue, hash: String?, size: Int64?, mtime: Int64?,
                      lastSeen: Int64) throws {
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, size_bytes, modified_at, last_seen_at) VALUES ('f1',?, 'image', ?, ?, ?)",
                           arguments: [hash, size, mtime, lastSeen])
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/a/x.png',1)")
        }
    }

    func testICloudTrustsHashIgnoresMetadata() throws {
        let q = try freshQueue()
        try seed(q, hash: "h1", size: 100, mtime: 50, lastSeen: 0)
        // iCloud + wrong size/mtime → still unchanged.
        XCTAssertTrue(Indexer.isUnchanged(absPath: "/a/x.png", sizeBytes: 999, modifiedAt: 999,
                                          isUbiquitous: true, now: 10, queue: q))
    }

    func testLocalMatchUnchangedMismatchChanged() throws {
        let q = try freshQueue()
        try seed(q, hash: "h1", size: 100, mtime: 50, lastSeen: 0)
        XCTAssertTrue(Indexer.isUnchanged(absPath: "/a/x.png", sizeBytes: 100, modifiedAt: 50,
                                          isUbiquitous: false, now: 10, queue: q))
        XCTAssertFalse(Indexer.isUnchanged(absPath: "/a/x.png", sizeBytes: 101, modifiedAt: 50,
                                           isUbiquitous: false, now: 10, queue: q))
    }

    func testNullHashAlwaysChanged() throws {
        let q = try freshQueue()
        try seed(q, hash: nil, size: 100, mtime: 50, lastSeen: 0)
        XCTAssertFalse(Indexer.isUnchanged(absPath: "/a/x.png", sizeBytes: 100, modifiedAt: 50,
                                           isUbiquitous: false, now: 10, queue: q))
        XCTAssertFalse(Indexer.isUnchanged(absPath: "/a/x.png", sizeBytes: 100, modifiedAt: 50,
                                           isUbiquitous: true, now: 10, queue: q))
    }

    func testNoAlivePathChanged() throws {
        let q = try freshQueue()
        XCTAssertFalse(Indexer.isUnchanged(absPath: "/a/missing.png", sizeBytes: 1, modifiedAt: 1,
                                           isUbiquitous: false, now: 10, queue: q))
    }

    func testStaleLastSeenIsTouched() throws {
        let q = try freshQueue()
        try seed(q, hash: "h1", size: 100, mtime: 50, lastSeen: 0)   // stale: now - 0 > 86400
        _ = Indexer.isUnchanged(absPath: "/a/x.png", sizeBytes: 100, modifiedAt: 50,
                                isUbiquitous: false, now: 200_000, queue: q)
        let ls = try q.read { try Int64.fetchOne($0, sql: "SELECT last_seen_at FROM files WHERE id='f1'") }
        XCTAssertEqual(ls, 200_000)
    }

    func testFreshLastSeenNotTouched() throws {
        let q = try freshQueue()
        try seed(q, hash: "h1", size: 100, mtime: 50, lastSeen: 190_000)   // fresh: 200000 - 190000 < 86400
        _ = Indexer.isUnchanged(absPath: "/a/x.png", sizeBytes: 100, modifiedAt: 50,
                                isUbiquitous: false, now: 200_000, queue: q)
        let ls = try q.read { try Int64.fetchOne($0, sql: "SELECT last_seen_at FROM files WHERE id='f1'") }
        XCTAssertEqual(ls, 190_000, "a fresh last_seen must not be rewritten")
    }
}
```

- [ ] **Step 6: Run the wrapper test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/IndexerFastPathTests 2>&1 | tail -20`
Expected: COMPILE FAILURE — `isUnchanged` is `private` (inaccessible from tests).

- [ ] **Step 7: Rewrite `isUnchanged` to delegate + make it internal**

Replace the whole `isUnchanged` function (`Indexer.swift:505–535`) with this — note `private` is dropped so tests can reach it, and the content-hash-nil guard moves out of the read into `decideIndexAction`:

```swift
    /// True if the file is already indexed and can be treated as unchanged — the
    /// single-file fast path. Delegates the decision to the pure
    /// `decideIndexAction` (shared with the batched discovery in `indexBatch`)
    /// and owns only the DB read + the `last_seen_at` retention touch. Callers
    /// reach here only for non-dataless, non-force files.
    static func isUnchanged(absPath: String, sizeBytes: Int64?,
                            modifiedAt: Int64?, isUbiquitous: Bool,
                            now: Int64, queue: DatabaseQueue) -> Bool {
        let stored: StoredIdentity? = (try? queue.read { db -> StoredIdentity? in
            guard let path = try PathRow
                    .filter(PathRow.Columns.absolute_path == absPath)
                    .filter(PathRow.Columns.is_alive == 1)
                    .fetchOne(db),
                  let fid = path.file_id,
                  let file = try FileRow.filter(FileRow.Columns.id == fid).fetchOne(db)
            else { return nil }
            return StoredIdentity(fileID: fid, contentHash: file.content_hash,
                                  size: file.size_bytes, mtime: file.modified_at,
                                  lastSeen: file.last_seen_at)
        }) ?? nil

        let decision = decideIndexAction(
            isDataless: false, force: false, isUbiquitous: isUbiquitous,
            stored: stored, onDiskSize: sizeBytes, onDiskMtime: modifiedAt)
        guard decision == .unchanged else { return false }

        if let stored, now - stored.lastSeen > 86_400 {
            try? queue.write { db in
                try db.execute(sql: "UPDATE files SET last_seen_at = ? WHERE id = ?",
                               arguments: [now, stored.fileID])
            }
        }
        return true
    }
```

- [ ] **Step 8: Run both new suites to verify they pass**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/IndexerDecisionTests -only-testing:MuseTests/IndexerFastPathTests 2>&1 | tail -20`
Expected: PASS (all methods in both files).

- [ ] **Step 9: Run the reconcile suite to confirm no regression**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/IndexerReconcileTests 2>&1 | tail -20`
Expected: PASS (all 8 tests — reconcile is untouched).

- [ ] **Step 10: Commit**

```bash
git add Muse/Muse/Indexing/Indexer.swift Muse/MuseTests/IndexerDecisionTests.swift Muse/MuseTests/IndexerFastPathTests.swift
git commit -m "refactor: extract pure folder-open discovery decision (P4 groundwork)"
```

---

### Task 2: Batch the folder-open discovery read + the last_seen touch

**Files:**
- Modify: `Muse/Muse/Indexing/Indexer.swift` (add `loadStoredIdentities`; rewrite the discovery loop in `indexBatch`, `Indexer.swift:561–587`)
- Test: `Muse/MuseTests/IndexerFastPathTests.swift` (add batched-equivalence + batched-touch tests)

**Interfaces:**
- Consumes: `Indexer.decideIndexAction(...)`, `Indexer.StoredIdentity` (Task 1).
- Produces:
  - `static func Indexer.loadStoredIdentities(absPaths: [String], queue: DatabaseQueue) -> [String: StoredIdentity]`
  - `indexBatch` unchanged signature/behavior; discovery now does one chunked read + one batched touch.

- [ ] **Step 1: Write the failing batched-read + equivalence test**

Add to `Muse/MuseTests/IndexerFastPathTests.swift`:

```swift
    // MARK: batched discovery (P4)

    func testLoadStoredIdentitiesReturnsJoinedRows() throws {
        let q = try freshQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, size_bytes, modified_at, last_seen_at) VALUES ('f1','h1','image',100,50,7)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/a/x.png',1)")
            // A dead path and a null-file_id path must NOT appear in the map.
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p2','f1','/a/dead.png',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p3',NULL,'/a/orphan.png',1)")
        }
        let map = Indexer.loadStoredIdentities(
            absPaths: ["/a/x.png", "/a/dead.png", "/a/orphan.png", "/a/unknown.png"], queue: q)
        XCTAssertEqual(map.count, 1)
        let s = try XCTUnwrap(map["/a/x.png"])
        XCTAssertEqual(s.fileID, "f1")
        XCTAssertEqual(s.contentHash, "h1")
        XCTAssertEqual(s.size, 100)
        XCTAssertEqual(s.mtime, 50)
        XCTAssertEqual(s.lastSeen, 7)
    }

    // The core "old and new paths agree" guarantee: over the same fixture, the
    // set of paths the batched read+decision flags for hashing equals the set
    // the per-file isUnchanged wrapper flags.
    func testBatchedDiscoveryAgreesWithPerFileWrapper() throws {
        let q = try freshQueue()
        try q.write { db in
            // unchanged-local
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, size_bytes, modified_at, last_seen_at) VALUES ('f1','h1','image',100,50,0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/a/keep.png',1)")
            // changed-local (size differs on disk)
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, size_bytes, modified_at, last_seen_at) VALUES ('f2','h2','image',200,60,0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p2','f2','/a/edit.png',1)")
            // null-hash
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, size_bytes, modified_at, last_seen_at) VALUES ('f3',NULL,'image',300,70,0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p3','f3','/a/nohash.png',1)")
        }
        // On-disk metadata per path (as the loop would read via resourceValues).
        let onDisk: [String: (Int64?, Int64?, Bool)] = [   // (size, mtime, isUbiquitous)
            "/a/keep.png":   (100, 50, false),   // matches → unchanged
            "/a/edit.png":   (201, 60, false),   // size differs → needs hashing
            "/a/nohash.png": (300, 70, false),   // null hash → needs hashing
            "/a/new.png":    (1,   1,  false),   // unknown path → needs hashing
        ]
        let paths = Array(onDisk.keys)
        let map = Indexer.loadStoredIdentities(absPaths: paths, queue: q)

        var batched = Set<String>()
        for p in paths {
            let (sz, mt, ub) = onDisk[p]!
            if Indexer.decideIndexAction(isDataless: false, force: false, isUbiquitous: ub,
                                         stored: map[p], onDiskSize: sz, onDiskMtime: mt) == .needsHashing {
                batched.insert(p)
            }
        }
        var perFile = Set<String>()
        for p in paths {
            let (sz, mt, ub) = onDisk[p]!
            if !Indexer.isUnchanged(absPath: p, sizeBytes: sz, modifiedAt: mt,
                                    isUbiquitous: ub, now: 10, queue: q) {
                perFile.insert(p)
            }
        }
        XCTAssertEqual(batched, perFile)
        XCTAssertEqual(batched, ["/a/edit.png", "/a/nohash.png", "/a/new.png"])
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/IndexerFastPathTests 2>&1 | tail -20`
Expected: COMPILE FAILURE — `loadStoredIdentities` does not exist.

- [ ] **Step 3: Add the batched read helper**

In `Muse/Muse/Indexing/Indexer.swift`, add below `decideIndexAction` (still above `// MARK: - Fast-path helpers`):

```swift
    /// Batched fast-path read: the stored identity of every enumerated path in
    /// ONE chunked `IN (...)` join per ~800 paths, instead of a read transaction
    /// per file. Returns absPath → StoredIdentity for alive paths that have a
    /// file row (the join `ON f.id = p.file_id` excludes null-file_id / missing
    /// rows — the old read's nil guards). Fail-safe: a chunk whose read throws
    /// contributes nothing, so those paths fall through to `.needsHashing`.
    static func loadStoredIdentities(absPaths: [String],
                                     queue: DatabaseQueue) -> [String: StoredIdentity] {
        var map: [String: StoredIdentity] = [:]
        map.reserveCapacity(absPaths.count)
        for start in stride(from: 0, to: absPaths.count, by: 800) {
            let chunk = Array(absPaths[start..<min(start + 800, absPaths.count)])
            let rows = (try? queue.read { db -> [Row] in
                let marks = databaseQuestionMarks(count: chunk.count)
                return try Row.fetchAll(db, sql: """
                    SELECT p.absolute_path AS ap, f.id AS fid, f.content_hash AS ch,
                           f.size_bytes AS sz, f.modified_at AS mt, f.last_seen_at AS ls
                    FROM paths p JOIN files f ON f.id = p.file_id
                    WHERE p.is_alive = 1 AND p.absolute_path IN (\(marks))
                    """, arguments: StatementArguments(chunk))
            }) ?? []
            for r in rows {
                guard let ap: String = r["ap"], let fid: String = r["fid"] else { continue }
                let ls: Int64 = r["ls"]   // files.last_seen_at is INTEGER NOT NULL
                map[ap] = StoredIdentity(fileID: fid, contentHash: r["ch"],
                                         size: r["sz"], mtime: r["mt"], lastSeen: ls)
            }
        }
        return map
    }
```

- [ ] **Step 4: Run the helper/equivalence tests to verify they pass**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/IndexerFastPathTests 2>&1 | tail -20`
Expected: PASS (including `testBatchedDiscoveryAgreesWithPerFileWrapper`).

- [ ] **Step 5: Rewrite the discovery loop in `indexBatch` to use the batched read**

Replace the discovery block (`Indexer.swift:566–587`, from `var work: [(URL, AssetKind)] = []` through `guard !work.isEmpty else { return [] }`) with:

```swift
        var work: [(URL, AssetKind)] = []
        work.reserveCapacity(urls.count)

        // One batched read of the whole folder's stored identities (skipped in
        // force mode, which re-hashes everything regardless of stored metadata).
        let storedByPath: [String: StoredIdentity] = force
            ? [:]
            : Self.loadStoredIdentities(absPaths: urls.map { $0.0.standardizedFileURL.path },
                                        queue: queue)

        var staleFileIDs: [String] = []
        for (url, kind) in urls {
            let dataless = Self.isDataless(url)
            let isUbiquitous = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                .ubiquitousItemDownloadingStatus != nil
            let absPath = url.standardizedFileURL.path
            let rv = force ? nil : try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let sizeBytes = rv?.fileSize.map { Int64($0) }
            let modifiedAt = rv?.contentModificationDate.map { Int64($0.timeIntervalSince1970) }
            let stored = storedByPath[absPath]

            switch Self.decideIndexAction(isDataless: dataless, force: force,
                                          isUbiquitous: isUbiquitous, stored: stored,
                                          onDiskSize: sizeBytes, onDiskMtime: modifiedAt) {
            case .skipDataless:
                continue
            case .needsHashing:
                work.append((url, kind))
            case .unchanged:
                if let stored, now - stored.lastSeen > 86_400 { staleFileIDs.append(stored.fileID) }
                continue
            }
        }

        // One batched last_seen touch for every unchanged-but-stale file.
        if !staleFileIDs.isEmpty {
            try? queue.write { db in
                for start in stride(from: 0, to: staleFileIDs.count, by: 800) {
                    let chunk = Array(staleFileIDs[start..<min(start + 800, staleFileIDs.count)])
                    let marks = databaseQuestionMarks(count: chunk.count)
                    try db.execute(sql: "UPDATE files SET last_seen_at = ? WHERE id IN (\(marks))",
                                   arguments: StatementArguments([now] + chunk))
                }
            }
        }
        guard !work.isEmpty else { return [] }
```

Leave the comment block above `var work` (`Indexer.swift:561–565`) in place, and leave everything from `if !silent { await IndexProgress.shared.begin(work.count) }` onward (`Indexer.swift:589+`) untouched.

- [ ] **Step 6: Add a batched last_seen touch SQL test**

`indexBatch` reads size/mtime from the REAL filesystem and requires
`Database.shared.dbQueue`, and the repo has NO `Database` test-override seam
(verified: `grep -n "forTesting\|override" Muse/Muse/Database/Database.swift`
returns nothing), so `indexBatch` cannot be unit-tested end-to-end against an
in-memory queue. The batched-discovery DECISION is already covered by
`testBatchedDiscoveryAgreesWithPerFileWrapper` (in-memory queue) and the touch
threshold by `testStaleLastSeenIsTouched`. Add one test that pins the batched
`UPDATE … WHERE id IN (…)` SQL shape directly (the exact statement the loop
emits), to guard the chunked multi-id write:

```swift
    func testBatchedLastSeenTouchUpdatesAllIDs() throws {
        let q = try freshQueue()
        try q.write { db in
            for i in 1...3 {
                try db.execute(sql: "INSERT INTO files (id, content_hash, kind, size_bytes, modified_at, last_seen_at) VALUES (?, ?, 'image', 10, 20, 0)",
                               arguments: ["f\(i)", "h\(i)"])
            }
        }
        let ids = ["f1", "f2", "f3"]
        try q.write { db in
            let marks = databaseQuestionMarks(count: ids.count)
            try db.execute(sql: "UPDATE files SET last_seen_at = ? WHERE id IN (\(marks))",
                           arguments: StatementArguments([Int64(200_000)] + ids))
        }
        let seen = try q.read { try Int64.fetchAll($0, sql: "SELECT last_seen_at FROM files ORDER BY id") }
        XCTAssertEqual(seen, [200_000, 200_000, 200_000])
    }
```

Full `indexBatch` behavior (real FS reads) is covered by the running-app
verification in Task 4, per the repo's "verify runtime, not just tests" rule.

- [ ] **Step 7: Run the full indexer-related suites**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/IndexerFastPathTests -only-testing:MuseTests/IndexerDecisionTests -only-testing:MuseTests/IndexerReconcileTests 2>&1 | tail -20`
Expected: PASS (all methods; reconcile still green).

- [ ] **Step 8: Run the whole suite**

Run: `xcodebuild -scheme Muse test 2>&1 | tail -30`
Expected: PASS (503+ tests, `** TEST SUCCEEDED **`).

- [ ] **Step 9: Commit**

```bash
git add Muse/Muse/Indexing/Indexer.swift Muse/MuseTests/IndexerFastPathTests.swift
git commit -m "perf: batch folder-open discovery reads into one chunked IN fetch (P4)"
```

---

### Task 3: Fold P6 — batched path→fileID in the analyze pass + sidecar re-export

**Files:**
- Modify: `Muse/Muse/Intelligence/AnalyzePipeline.swift` (add `aliveFileIDs`; rewrite the resolution loop at `AnalyzePipeline.swift:219–234` and `exportSidecarsAfterTagEdit` at `AnalyzePipeline.swift:307–324`)
- Test: `Muse/MuseTests/AnalyzePipelineResolveTests.swift` (new)

**Interfaces:**
- Consumes: nothing from Tasks 1–2 (independent, same-pattern tidy).
- Produces:
  - `static func AnalyzePipeline.aliveFileIDs(queue: DatabaseQueue, absPaths: [String]) async -> [String: String]`
  - `static func AnalyzePipeline.dedupByFileID(urls: [URL], idByPath: [String: String]) -> [(id: String, url: URL)]`

Both are `internal static` (NOT `private`) and called directly from tests via
`@testable import Muse` — the repo's established pattern (e.g. tests call
`Indexer.reconcile`, `Indexer.inheritVisionTags` directly). The repo has NO
`#if DEBUG`/`ForTesting` shim convention; do not introduce one.

- [ ] **Step 1: Write the failing resolver test**

Create `Muse/MuseTests/AnalyzePipelineResolveTests.swift`:

```swift
//
//  AnalyzePipelineResolveTests.swift
//  MuseTests
//
//  P6: the batched path→fileID resolution must preserve dedup-by-file-id and
//  first-seen URL order (duplicate content analyzed once).
//

import XCTest
import GRDB
@testable import Muse

final class AnalyzePipelineResolveTests: XCTestCase {

    private func freshQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    func testAliveFileIDsResolvesAndSkipsDeadOrOrphan() async throws {
        let q = try freshQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/a/x.png',1)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p2','f1','/a/dead.png',0)")
        }
        let map = await AnalyzePipeline.aliveFileIDs(
            queue: q, absPaths: ["/a/x.png", "/a/dead.png", "/a/gone.png"])
        XCTAssertEqual(map, ["/a/x.png": "f1"])
    }

    func testDedupPreservesFirstSeenOrder() throws {
        // Two paths resolve to the SAME file_id; the pair must keep the FIRST url,
        // and order of distinct ids must follow first appearance.
        let idByPath = ["/a/dup1.png": "fA", "/a/dup2.png": "fA", "/a/other.png": "fB"]
        let urls = ["/a/dup1.png", "/a/dup2.png", "/a/other.png"].map { URL(fileURLWithPath: $0) }
        let pairs = AnalyzePipeline.dedupByFileID(urls: urls, idByPath: idByPath)
        XCTAssertEqual(pairs.map { $0.id }, ["fA", "fB"])
        XCTAssertEqual(pairs.map { $0.url.path }, ["/a/dup1.png", "/a/other.png"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/AnalyzePipelineResolveTests 2>&1 | tail -20`
Expected: COMPILE FAILURE — `aliveFileIDs` / `dedupByFileID` do not exist.

- [ ] **Step 3: Add the batched resolver + a pure dedup helper**

In `Muse/Muse/Intelligence/AnalyzePipeline.swift`, add these two `internal static`
helpers to the class (e.g. just above `analyze(folder:)`). They are `internal`
(not `private`) so the tests reach them directly via `@testable import Muse`, the
repo's established pattern — no `#if DEBUG` shims:

```swift
    /// Resolve standardized absolute paths to their alive file_ids in one chunked
    /// `IN (...)` read per ~800 paths (P6 — mirrors CollectionStore.fileIDs but
    /// returns the path→id MAP so callers keep URL pairing/order). Only paths with
    /// an alive row and a non-null file_id appear.
    static func aliveFileIDs(queue: DatabaseQueue, absPaths: [String]) async -> [String: String] {
        guard !absPaths.isEmpty else { return [:] }
        return (try? await queue.read { db -> [String: String] in
            var map: [String: String] = [:]
            for start in stride(from: 0, to: absPaths.count, by: 800) {
                let chunk = Array(absPaths[start..<min(start + 800, absPaths.count)])
                let marks = databaseQuestionMarks(count: chunk.count)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT absolute_path AS ap, file_id AS fid FROM paths
                    WHERE is_alive = 1 AND file_id IS NOT NULL AND absolute_path IN (\(marks))
                    """, arguments: StatementArguments(chunk))
                for r in rows {
                    if let ap: String = r["ap"], let fid: String = r["fid"] { map[ap] = fid }
                }
            }
            return map
        }) ?? [:]
    }

    /// Dedup URLs to unique file_ids, preserving first-seen URL order (duplicate
    /// content analyzed once, paired with its FIRST occurrence). Pure.
    static func dedupByFileID(urls: [URL], idByPath: [String: String]) -> [(id: String, url: URL)] {
        var pairs: [(id: String, url: URL)] = []
        var seen = Set<String>()
        for url in urls {
            guard let id = idByPath[url.standardizedFileURL.path], !seen.contains(id) else { continue }
            seen.insert(id)
            pairs.append((id, url))
        }
        return pairs
    }
```

- [ ] **Step 4: Rewrite the resolution loop in `analyze(folder:)`**

Replace `AnalyzePipeline.swift:219–234` (the `var pairs` / `var seen` / `for url in urls { … }` block, up to but NOT including `total = pairs.count`) with:

```swift
        // Resolve all URLs to alive file_ids in ONE batched read, then dedup by
        // file_id preserving first-seen URL order (duplicate content — the same
        // bytes under several paths — is analyzed ONCE).
        if shouldStop { return }
        let idByPath = await Self.aliveFileIDs(queue: queue,
                                               absPaths: urls.map { $0.standardizedFileURL.path })
        if shouldStop { return }
        let pairs = Self.dedupByFileID(urls: urls, idByPath: idByPath)
```

Leave `total = pairs.count` and everything after (`AnalyzePipeline.swift:235+`) unchanged. (`pairs` is now a `let`; the analyze loop at `:238` only reads it.)

- [ ] **Step 5: Rewrite `exportSidecarsAfterTagEdit`**

Replace the `Task { … }` body in `exportSidecarsAfterTagEdit` (`AnalyzePipeline.swift:311–323`) with:

```swift
        Task {
            let idByPath = await Self.aliveFileIDs(queue: queue,
                                                   absPaths: inZone.map { $0.standardizedFileURL.path })
            for url in inZone {
                guard let fid = idByPath[url.standardizedFileURL.path] else { continue }
                await writeSidecarIfICloud(fileID: fid, url: url, mergeExisting: false)
            }
        }
```

(Keeps `mergeExisting: false` — manual tag edits are authoritative.)

- [ ] **Step 6: Run the resolver tests to verify they pass**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/AnalyzePipelineResolveTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 7: Run the whole suite**

Run: `xcodebuild -scheme Muse test 2>&1 | tail -30`
Expected: PASS (`** TEST SUCCEEDED **`).

- [ ] **Step 8: Commit**

```bash
git add Muse/Muse/Intelligence/AnalyzePipeline.swift Muse/MuseTests/AnalyzePipelineResolveTests.swift
git commit -m "perf: batch path->fileID resolution in analyze pass + sidecar re-export (P6)"
```

---

### Task 4: Verify in the running app (repo rule)

**Files:** none (manual verification per CLAUDE.md "verify runtime, not just tests").

- [ ] **Step 1: Build and launch**

Run: `xcodebuild -scheme Muse build 2>&1 | tail -5` then launch the built app (Cmd+R in Xcode, or `open` the built product).

- [ ] **Step 2: No spurious re-index on reopen — LOCAL**

Point Muse at a large already-indexed local folder (5k+ files). Open it, let indexing settle (pill disappears), switch to another folder, switch back. CONFIRM: no "Indexing N of M" pill on the second open (fully-indexed folder does zero hashing).

- [ ] **Step 3: No spurious re-index on reopen — iCLOUD (the invariant guard)**

Repeat Step 2 with an iCloud-zone folder. CONFIRM: no pill on reopen — the iCloud content-hash trust path must NOT re-hash on every visit (the shipped bug this change must not reintroduce).

- [ ] **Step 4: A real edit is still caught**

Edit ONE image in place (crop + save), return to the folder. CONFIRM: that one file re-thumbnails/re-analyzes; the rest do not.

- [ ] **Step 5: Analyze pass still runs (P6)**

Add a folder of un-analyzed images. CONFIRM: auto-tags/collections populate as before.

- [ ] **Step 6: Final commit (if any verification-driven fixes were needed)**

```bash
git add -A
git commit -m "chore: folder-open batch reads verified in running app"
```

---

## Self-Review

**Spec coverage:**
- Pure decision function + full truth table → Task 1 (Steps 1–4, all 8 rows + nil quirk).
- Retained `isUnchanged` wrapper delegating → Task 1 (Step 7) + DB-backed tests (Steps 5–8).
- Batched fetch (chunked IN) + in-memory diff + batched last_seen touch → Task 2.
- Dataless stays per-file FS check → Task 2 Step 5 (`Self.isDataless(url)` in the loop).
- size/mtime LOCAL-only → enforced by `decideIndexAction` (Task 1), asserted Task 1 Steps 1 & 5.
- P6 both sites (`analyze(folder:)` + `exportSidecarsAfterTagEdit`) → Task 3 Steps 4–5.
- Dedup-by-file-id invariant → Task 3 (`dedupByFileID` + `testDedupPreservesFirstSeenOrder`).
- Invariants: reconcile untouched (Task 1 Step 9, Task 2 Step 7 re-run), zero-byte guard untouched (not modified), iCloud content-hash rule (truth table).
- Verify in running app → Task 4.

**Placeholder scan:** every code step contains complete code; the two conditional-deletion notes (Task 2 Step 6, Task 3 Step 3) give an explicit grep to decide and a concrete fallback (delete the method / use `internal`), not a TBD.

**Type consistency:** `IndexDecision` (`.unchanged`/`.needsHashing`/`.skipDataless`), `StoredIdentity` (fileID/contentHash/size/mtime/lastSeen), `decideIndexAction` and `loadStoredIdentities` signatures are identical across the spec, Task 1, and Task 2. `aliveFileIDs`/`dedupByFileID` signatures match between Task 3's helper and its tests.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-06-folder-open-batch-reads.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks.
2. **Inline Execution** — execute tasks in this session with checkpoints.
