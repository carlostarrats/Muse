# Folder-open batched reads (P4 + P6) — design spec

**Date:** 2026-07-06
**Branch context:** off `feat/next-115` (clean, `main`-equivalent)
**Source:** `docs/perf-and-feature-review-2026-07-03.md` — P4 (HIGH, APPROVED) with
P6 (DEFER standalone, BUNDLE with P4) folded in. Both are BINDING; this spec
follows the review doc's owner design exactly.
**Scope:** one performance change with two folded parts — (P4) collapse the
per-file DB read on folder open into one chunked `IN (...)` fetch per folder,
and (P6) collapse the path→fileID N+1 in the analyze pass into the same batching
pattern. No user-visible behavior change: identical decisions, identical DB
mutations, fewer transactions.

This is the trickiest approved perf item. **Correctness of the per-file decision
matrix is paramount** — a mistake re-indexes whole libraries (spurious re-hash
every visit) or corrupts identity (the shared-row split). The design's central
move is to extract the current per-file decision into ONE pure function that both
the (retained) single-file path and the new batched path call, so they can never
diverge, and to unit-test every branch of that function against the current
behavior.

---

## Part 1 — Problem

### P4 — one read transaction per file on folder open

`Indexer.indexBatch(_:priority:force:silent:)`
(`Muse/Muse/Indexing/Indexer.swift:554–612`) runs on every fresh folder open
(dispatched off-main from `AppState.scheduleIndexing`,
`Muse/Muse/Models/AppState+Indexing.swift`). Its discovery loop
(`Indexer.swift:568–586`) calls `isUnchanged(...)` once per enumerated file to
decide whether the file can be skipped (already indexed, unchanged) or needs
(re)hashing:

```swift
for (url, kind) in urls {
    if Self.isDataless(url) { continue }
    if force { work.append((url, kind)); continue }
    let isUbiquitous = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
        .ubiquitousItemDownloadingStatus != nil
    let absPath = url.standardizedFileURL.path
    let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let sizeBytes = rv?.fileSize.map { Int64($0) }
    let modifiedAt = rv?.contentModificationDate.map { Int64($0.timeIntervalSince1970) }
    if Self.isUnchanged(absPath: absPath, sizeBytes: sizeBytes,
                        modifiedAt: modifiedAt, isUbiquitous: isUbiquitous,
                        now: now, queue: queue) {
        continue
    }
    work.append((url, kind))
}
```

Each `isUnchanged` call (`Indexer.swift:505–535`) opens **its own**
`queue.read` transaction that runs TWO queries (a `PathRow` lookup, then a
`FileRow` lookup by id), and — when the file is unchanged and stale — a
`queue.write` to touch `last_seen_at` (`Indexer.swift:528–533`).

**Cost:** a fully-indexed 20k-file folder pays ~20k sequential read transactions
(~40k queries) on the serial GRDB queue on every open. It runs off-main so there
is no UI freeze, but it gates thumbnail prewarm + the analyze pass (both queued
after `indexBatch` in `scheduleIndexing`) and contends with grid/sidebar reads on
the same serial queue. A chunked `IN (...)` fetch replaces this with ~25 read
transactions (20 000 / 800) — roughly **800× fewer transactions**, diffed in
memory.

### P6 — path→fileID resolution is N+1 in the analyze pass

`AnalyzePipeline.analyze(folder:)`
(`Muse/Muse/Intelligence/AnalyzePipeline.swift:207–252`) resolves each URL to a
`file_id` one URL at a time (`AnalyzePipeline.swift:221–234`):

```swift
for url in urls {
    if shouldStop { return }
    let absPath = url.standardizedFileURL.path
    let fileID: String? = (try? await queue.read { db -> String? in
        try PathRow
            .filter(PathRow.Columns.absolute_path == absPath)
            .filter(PathRow.Columns.is_alive == 1)
            .fetchOne(db)?.file_id
    }) ?? nil
    if let id = fileID, !seen.contains(id) {
        seen.insert(id)
        pairs.append((id, url))
    }
}
```

`N` here is files-to-analyze (new/changed only, gated by `analyzed_hash`), NOT
folder size, and each read is microseconds against the seconds/image of Vision
that follows — so standalone impact is negligible (why the review deferred it
standalone). But it is the SAME `IN (...)` batching pattern as P4
(`CollectionStore.fileIDs`, `Muse/Muse/Intelligence/Collections/CollectionStore.swift:104–114`,
already demonstrates it in-repo), and it is a low-risk pure-read tidy — so the
review binds it to P4. The second identical shape,
`exportSidecarsAfterTagEdit` (`AnalyzePipeline.swift:307–324`), is included
because it is the same reorganization (small N per tag-edit, larger on bulk tag
ops).

---

## Part 2 — The extracted PURE decision function

The heart of the change. The current per-file decision is spread across the
discovery loop's pre-checks (dataless, force) and `isUnchanged`'s DB read. It is
pulled into ONE pure, side-effect-free function so the batched path and the
single-file path share exactly one source of truth.

### The current decision, verbatim (the truth to preserve)

`isUnchanged` (`Indexer.swift:505–535`), read exactly:

```swift
private static func isUnchanged(absPath: String, sizeBytes: Int64?,
                                modifiedAt: Int64?, isUbiquitous: Bool,
                                now: Int64, queue: DatabaseQueue) -> Bool {
    struct Known { let fileID: String; let lastSeen: Int64 }
    let known: Known? = (try? queue.read { db -> Known? in
        guard let path = try PathRow
                .filter(PathRow.Columns.absolute_path == absPath)
                .filter(PathRow.Columns.is_alive == 1)
                .fetchOne(db),
              let fid = path.file_id,
              let file = try FileRow.filter(FileRow.Columns.id == fid).fetchOne(db),
              file.content_hash != nil
        else { return nil }
        // iCloud: trust the existing hash (metadata is unreliable).
        if isUbiquitous {
            return Known(fileID: fid, lastSeen: file.last_seen_at)
        }
        // Local: require an exact size + mtime match.
        guard file.size_bytes == sizeBytes, file.modified_at == modifiedAt
        else { return nil }
        return Known(fileID: fid, lastSeen: file.last_seen_at)
    }) ?? nil
    guard let known else { return false }
    if now - known.lastSeen > 86_400 {
        try? queue.write { db in
            try db.execute(sql: "UPDATE files SET last_seen_at = ? WHERE id = ?",
                           arguments: [now, known.fileID])
        }
    }
    return true
}
```

Combined with the loop's pre-checks (`Indexer.swift:569–570`): `isDataless`
short-circuits to a `continue` (skip) BEFORE `force`, and `force`
short-circuits to `work.append` BEFORE any metadata is read.

### Decision enum

```swift
enum IndexDecision: Equatable {
    case unchanged      // known + alive + hash present + (iCloud, OR local size&mtime match) → do NOT hash
    case needsHashing   // unknown path / missing file row / NULL content_hash / local size|mtime mismatch → hash + reconcile
    case skipDataless   // dataless iCloud placeholder — no local bytes to hash yet
}
```

**There is deliberately no `.changed` case.** The review/owner summary lists a
4-value enum `(unchanged / needs-rehash / changed / skip-dataless)`, but at
discovery time "changed" is NOT knowable — whether differing bytes are genuinely
new content requires the hash, and that determination belongs to `reconcile`
(`Indexer.swift:135–268`), AFTER hashing. Discovery is a genuine three-way
skip/hash/skip-dataless decision. Modelling a `.changed` case would add an
unreachable branch. (See "Deviations from the review doc" at the end.)

### Stored-identity input

The DB read's result, as a pure value so the decision function needs no queue:

```swift
struct StoredIdentity: Equatable {
    let fileID: String
    let contentHash: String?   // nil is meaningful: forces re-hash (iCloud AND local)
    let size: Int64?
    let mtime: Int64?
    let lastSeen: Int64
}
```

`nil` `StoredIdentity` means "no alive path for this absolute path, OR its
`file_id` is null, OR its file row is missing" — the three read-guard failures
the old `isUnchanged` collapsed to `return nil` (→ not unchanged → hash).

### The pure function

```swift
/// Pure discovery decision — replicates `isUnchanged` + the discovery loop's
/// dataless/force pre-checks EXACTLY, with NO side effects. The `last_seen`
/// touch is deliberately NOT here so the caller can batch it into one write.
///
/// Ordering is load-bearing and matches the original loop + isUnchanged:
///   1. dataless FIRST — skipped before force, before any DB compare
///   2. force → hash (ignores stored metadata entirely)
///   3. no stored identity (missing alive path / file row) → hash
///   4. NULL content_hash → hash — applies to iCloud AND local, checked
///      BEFORE the iCloud-trust branch (an un-hashed iCloud file is NOT trusted)
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

### Full truth table (every branch, verbatim from current behavior)

| # | isDataless | force | stored | content_hash | isUbiquitous | size match | mtime match | → decision | current-code source |
|---|---|---|---|---|---|---|---|---|---|
| 1 | true | — | — | — | — | — | — | `.skipDataless` | loop `if Self.isDataless(url) { continue }` (`:569`) |
| 2 | false | true | — | — | — | — | — | `.needsHashing` | loop `if force { work.append; continue }` (`:570`) |
| 3 | false | false | nil | — | — | — | — | `.needsHashing` | read guard `path?/file_id?/file?` → nil → `false` (`:510–517`) |
| 4 | false | false | present | nil | any | — | — | `.needsHashing` | read guard `file.content_hash != nil` → nil → `false` (`:516`) |
| 5 | false | false | present | non-nil | **true** | — | — | `.unchanged` | `if isUbiquitous { return Known }` (`:519–521`) |
| 6 | false | false | present | non-nil | false | **true** | **true** | `.unchanged` | `guard size==, mtime==` passes (`:523–525`) |
| 7 | false | false | present | non-nil | false | false | any | `.needsHashing` | `guard size==` fails → nil → `false` (`:523`) |
| 8 | false | false | present | non-nil | false | any | false | `.needsHashing` | `guard mtime==` fails → nil → `false` (`:523`) |

Rows 5–8 are the load-bearing iCloud-vs-local split: **the size/mtime fast path
is LOCAL-ONLY**. An iCloud file (`isUbiquitous == true`) is trusted as unchanged
purely on its stored hash and never compared on size/mtime — because iCloud
rewrites and oscillates size/mtime on sync, so a size/mtime proxy would never
converge and would re-hash the whole iCloud folder on every visit (the shipped
"indexing 920 + UI freeze" bug; CLAUDE.md "iCloud change detection = content
hash, NOT size/mtime").

Row 4 is also load-bearing and its ORDER matters: the NULL-`content_hash` guard
is checked BEFORE the `isUbiquitous` trust branch, so even an iCloud file that
was recorded but never successfully hashed (e.g. a prior dataless read) is
re-hashed, not trusted.

### Nil-optional equality (preserve exactly)

`stored.size == onDiskSize` and `stored.mtime == onDiskMtime` are `Int64?`
comparisons — `nil == nil` is `true`. The current `isUnchanged` uses the same
optional equality (`file.size_bytes == sizeBytes`). A file whose stored size is
nil AND whose on-disk size is nil compares equal (unchanged); this quirk is
preserved verbatim by using `==` on the optionals rather than force-unwrapping.

---

## Part 3 — Batched fetch design (P4)

### The single-file wrapper is retained and delegates

`isUnchanged` is NOT deleted. It is rewritten to (a) do the same two-query DB
read, packaged into a `StoredIdentity`, (b) call `decideIndexAction`, (c) apply
the `last_seen` touch side-effect when the decision is `.unchanged` and the row
is stale. This keeps a live, DB-backed, single-file reference implementation that
provably shares the batched path's decision logic (both call
`decideIndexAction`) and gives the tests a DB-backed oracle:

```swift
private static func isUnchanged(absPath: String, sizeBytes: Int64?,
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

    // Callers only reach here for non-dataless, non-force files.
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

Note the content-hash-nil guard moved OUT of the read (into `decideIndexAction`)
— `StoredIdentity` is now non-nil even when `content_hash` is nil, but the touch
branch only runs when `decision == .unchanged`, which `decideIndexAction` never
returns for a nil hash, so no `last_seen` is written for an un-hashed row.
Behavior is identical.

### The batched read helper

One chunked join per ~800 paths (the repo's `stride(from:to:by:800)` chunk size,
e.g. `TagChipLoader.fast`, `Muse/Muse/Database/TagChipLoader.swift:61–72`). The
join `ON f.id = p.file_id` naturally excludes null-`file_id` paths and paths
whose file row is missing — exactly the old read's first two guard failures — so
an absent map entry means "not known" → `.needsHashing`:

```swift
/// Batched fast-path read: the stored identity of every enumerated path in ONE
/// chunked `IN (...)` join per ~800 paths, instead of a read transaction per
/// file. Returns absPath → StoredIdentity for alive paths that have a file row.
/// Fail-safe: a chunk whose read throws contributes nothing, so those paths
/// fall through to `.needsHashing` (do the work) — never a silent skip.
private static func loadStoredIdentities(absPaths: [String],
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

### The rewritten discovery loop

The per-file FS reads (dataless / ubiquitous / size / mtime via
`resourceValues`) STAY per-file — they are local stat calls, not the N+1 being
removed, and dataless MUST stay a per-file FS check (it needs the URL and must
never read bytes; CLAUDE.md "classification never reads dataless iCloud bytes").
Only the DB read is batched. The batched read is skipped entirely in `force`
mode (stored metadata is ignored there). Stale `last_seen` touches are collected
and written ONCE:

```swift
var work: [(URL, AssetKind)] = []
work.reserveCapacity(urls.count)

// One batched read of the whole folder's stored identities (skipped for force,
// which re-hashes everything regardless of stored metadata).
let storedByPath: [String: StoredIdentity] = force
    ? [:]
    : Self.loadStoredIdentities(absPaths: urls.map { $0.0.standardizedFileURL.path }, queue: queue)

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

// One batched last_seen touch for every unchanged-but-stale file (chunked).
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

The rest of `indexBatch` (the windowed `withTaskGroup` hashing at
`Indexer.swift:589–611`) is unchanged — it still runs `indexFile` →
`reconcile` per surviving `work` item exactly as today. The reconcile write path
is untouched.

### Equivalence note on ordering of side-effects

The old path touched `last_seen` inside each `isUnchanged` call, interleaved with
discovery; the new path defers all touches to one write after discovery. The
touched SET is identical (same files, same `now`, same 86 400 threshold), only
the timing/transaction-count differs. No reader observes `last_seen` mid-pass
(it drives only the 180-day retention prune at launch), so this is behavior-
equivalent.

---

## Part 4 — The P6 fold (path→fileID batch)

### Site 1 — `analyze(folder:)` resolution (`AnalyzePipeline.swift:219–234`)

Replace the per-URL read loop with ONE batched resolution up front, then dedup by
file_id in URL order (preserving the invariant that duplicate content is analyzed
ONCE and that the URL paired with each unique id is the FIRST occurrence, and that
`pairs` order — which drives the progress pill's `current`/`completed` — is
unchanged):

```swift
// Resolve all URLs to alive file_ids in ONE batched read, then dedup by
// file_id preserving first-seen URL order (duplicate content analyzed once).
let absPaths = urls.map { $0.standardizedFileURL.path }
let idByPath = await Self.aliveFileIDs(queue: queue, absPaths: absPaths)   // [absPath: fileID]
var pairs: [(id: String, url: URL)] = []
var seen = Set<String>()
for url in urls {
    if shouldStop { return }
    guard let id = idByPath[url.standardizedFileURL.path], !seen.contains(id) else { continue }
    seen.insert(id)
    pairs.append((id, url))
}
```

The batched resolver (a private static helper on `AnalyzePipeline`, mirroring
`CollectionStore.fileIDs`' chunked `IN` but returning the path→id MAP so callers
keep URL pairing/order):

```swift
/// Resolve standardized absolute paths to their alive file_ids in one chunked
/// `IN (...)` read per ~800 paths. Returns absPath → fileID (only paths that
/// have an alive row with a non-null file_id appear).
private static func aliveFileIDs(queue: DatabaseQueue, absPaths: [String]) async -> [String: String] {
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
```

**Dedup-by-file-id invariant preserved** (`AnalyzePipeline.swift:216–232`): the
`seen` set + first-seen order are kept byte-for-byte; only the N reads collapse to
~1. The `shouldStop` check stays inside the dedup loop (cheap, keeps cancellation
responsive); an additional `if shouldStop { return }` should guard immediately
before/after the batched read since the per-URL reads that previously offered
cancellation points are gone.

### Site 2 — `exportSidecarsAfterTagEdit` (`AnalyzePipeline.swift:307–324`)

Same shape. Resolve all in-zone URLs in one batched read, then loop the sidecar
writes:

```swift
func exportSidecarsAfterTagEdit(for urls: [URL]) {
    let zone = iCloudFolder
    let inZone = urls.filter { ICloudZone.contains($0, folder: zone) }
    guard !inZone.isEmpty, let queue = Database.shared.dbQueue else { return }
    Task {
        let idByPath = await Self.aliveFileIDs(queue: queue,
                                               absPaths: inZone.map { $0.standardizedFileURL.path })
        for url in inZone {
            guard let fid = idByPath[url.standardizedFileURL.path] else { continue }
            await writeSidecarIfICloud(fileID: fid, url: url, mergeExisting: false)
        }
    }
}
```

`mergeExisting: false` is preserved (manual tag EDITS are authoritative, incl.
deletions — CLAUDE.md sidecar merge rule).

---

## Part 5 — Invariants preserved (checklist)

- **iCloud content-hash rule (LOCAL-only size/mtime fast path).** Rows 5–8 of the
  truth table; `isUbiquitous == true` → `.unchanged` on stored hash alone,
  size/mtime never consulted. Verbatim from `isUnchanged:518–525`.
- **NULL content_hash → re-hash, before the iCloud trust.** Truth-table row 4;
  guard order preserved in `decideIndexAction`.
- **Dataless files never hashed / never read for bytes.** `isDataless` stays a
  per-file FS check (`Indexer.isDataless`, `:483–491`), evaluated first; the pure
  function returns `.skipDataless`. Not batched into the DB read.
- **Zero-byte-hash guard untouched.** `HashService.sha256`
  (`Muse/Muse/Indexing/HashService.swift:33–39`) is downstream of discovery and
  not touched — files that survive discovery still hash through the same streaming
  hasher with the `totalBytes == 0 && size > 0 → nil` guard intact.
- **`reconcile` split-on-edit untouched.** The batched change ends at deciding
  the `work` set; every `work` item still flows `indexFile` → `queue.write` →
  `reconcile` unchanged. `IndexerReconcileTests` must stay green with zero edits.
- **Dedup-by-file-id (analyze pass).** `seen` set + first-seen URL order kept
  verbatim; only reads batch.
- **`last_seen` touch set + 86 400 threshold + `now`.** Identical set of files
  updated, one write instead of N.
- **Serial-queue fail-safe direction.** A DB read failure yields "not known" →
  `.needsHashing` (do the work), never a silent skip — same direction as the old
  `(try? queue.read {…}) ?? nil` → `false`.

---

## Part 6 — Test strategy

TDD. The pure decision function is extracted and tested FIRST, proving it
reproduces current behavior, BEFORE any call site is rewired.

### New: `IndexerDecisionTests.swift` (pure, no DB — exhaustive)

One assertion per truth-table row (8 rows), plus the nil-optional equality quirk:

- Row 1: `decideIndexAction(isDataless: true, force: false, …)` → `.skipDataless`
  (and `force: true` with `isDataless: true` STILL `.skipDataless` — dataless
  wins over force).
- Row 2: `isDataless: false, force: true` → `.needsHashing` regardless of stored.
- Row 3: `stored: nil` → `.needsHashing`.
- Row 4: `stored` with `contentHash: nil`, both `isUbiquitous: true` and `false`
  → `.needsHashing` (hash-nil beats iCloud trust).
- Row 5: `isUbiquitous: true`, hash present, size/mtime DELIBERATELY mismatched →
  `.unchanged` (proves size/mtime ignored for iCloud).
- Row 6: local, hash present, size & mtime match → `.unchanged`.
- Rows 7–8: local, size mismatch OR mtime mismatch → `.needsHashing`.
- Quirk: local, `stored.size == nil` & `onDiskSize == nil` & mtimes equal →
  `.unchanged` (nil == nil).

### New: DB-backed `isUnchanged` wrapper tests (in `IndexerReconcileTests` or a
new `IndexerFastPathTests.swift`)

Prove the wrapper wires DB values into the pure function AND applies the touch:

- iCloud file (`isUbiquitous: true`) with a stored hash but wrong size/mtime →
  `isUnchanged == true`.
- Local file, matching size+mtime → `true`; mismatched size → `false`.
- Row with `content_hash NULL` → `false` (both iCloud and local).
- No alive path → `false`.
- `last_seen_at` touch: a stale (`now - lastSeen > 86_400`) unchanged file has its
  `last_seen_at` bumped to `now`; a fresh one is NOT written.

### New: batched-discovery equivalence test (the "old/new agree" guarantee)

Seed a fixture folder mixing every state (unchanged-local, changed-local-size,
changed-local-mtime, unchanged-iCloud-with-oscillated-metadata, null-hash,
brand-new-unknown-path). Because `indexBatch`'s discovery is hard to observe in
isolation (it feeds a task group), the test asserts equivalence at the decision
layer: for the same fixture, the set `{absPath | decideIndexAction(...) ==
.needsHashing}` computed over the batched `loadStoredIdentities` map equals the
set computed by calling the retained per-file `isUnchanged` and collecting the
`false` results. Both consult the same DB fixture; identical `work` sets prove the
batched read reproduces the per-file reads.

### Regression: existing suites stay green

- `IndexerReconcileTests` (all 8 tests) — reconcile is untouched; they must pass
  with zero edits.
- Full `xcodebuild -scheme Muse test` (503+ tests) green.

---

## Part 7 — Verify in the running app (repo rule — tests are necessary, not
sufficient)

1. **No spurious re-index on reopen (the core P4 payoff + the iCloud invariant).**
   Point Muse at a large, already-fully-indexed LOCAL folder (ideally 5k+ files).
   Open it, let indexing settle, switch away, switch back. The "Indexing N of M"
   pill must NOT appear on the second open (a fully-indexed folder does zero
   hashing). Then do the same with an iCloud-zone folder — it must ALSO show no
   pill on reopen (the iCloud content-hash trust path); a re-index-every-visit
   regression here is the exact shipped bug this guards.
2. **A real edit is still caught.** Edit one image in-place (crop/save), return to
   the folder — that ONE file re-hashes and re-analyzes, the rest do not.
3. **Analyze pass still runs (P6).** Add a folder of un-analyzed images; confirm
   auto-tags/collections populate as before (the batched fileID resolution feeds
   the same `analyzeOne`).

---

## Part 8 — Out of scope (explicitly deferred, per the review doc)

- **P1** (incremental clustering) and **P2** (warm embedding matrix) — deferred to
  real large-analyzed-library scale.
- **P5** (parallel Vision) — DEFER pending measurement; not touched here.
- **The `reconcile` write path itself** — unchanged. This change only reduces the
  DISCOVERY reads that decide which files reach `reconcile`.
- **The per-file FS `resourceValues` calls** (dataless / ubiquitous / size /
  mtime) stay per-file. A micro-optimization exists — the current loop reads
  `ubiquitousItemDownloadingStatusKey` TWICE per file (once in `isDataless`, once
  for `isUbiquitous`), collapsible to one `resourceValues` call fetching all
  keys — but it is intentionally left out to keep the change surgical and the
  decision matrix the sole focus; noted for a future opportunistic tidy.
- **Widening the hash concurrency cap of 2** (`Indexer.swift:605`) — a deliberate
  anti-stutter throttle; review says SKIP.

---

## Deviations found between the review doc's summary and the ACTUAL code

1. **The 4-value enum overstates the discovery decision.** The review/owner design
   names `(unchanged / needs-rehash / changed / skip-dataless)`. The actual
   discovery is three-valued — `.changed` is NOT determinable without the hash and
   is decided later in `reconcile`. This spec models three cases and omits
   `.changed` deliberately (an unreachable case would be misleading). "needs-rehash"
   = `.needsHashing`.
2. **`content_hash`-nil is not a standalone branch — it's an ordered guard.** The
   review lists "missing `content_hash` → re-hash" as if parallel to the
   iCloud/local split. In the code it is checked BEFORE the `isUbiquitous` branch
   (`isUnchanged:516`), so it also overrides the iCloud trust: an iCloud file with a
   null hash is re-hashed, not trusted. The pure function preserves this order.
3. **Dataless lives OUTSIDE `isUnchanged` today.** The review says "dataless-skip
   stays a per-file FS check" (correct), but note the current code does the dataless
   `continue` in the discovery LOOP (`:569`), not inside `isUnchanged`. Folding the
   dataless boolean into the shared pure function (as the owner asked) is therefore a
   behavior-preserving reorganization, with the FS call itself remaining per-file in
   the loop.
4. **Redundant FS read.** Not a decision-logic difference, but the loop reads
   `ubiquitousItemDownloadingStatusKey` twice per file today; left as-is (see
   out-of-scope).
