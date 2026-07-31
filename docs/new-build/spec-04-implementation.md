# Spec 04 — Editing Engine, Core Adjustments, Editor UI: full implementation spec

*Derived from `pre-spec-04-editing-engine.md` + `muse-photo-foundation.md` (§3 and §6;
§13 decision log is authoritative) + `DECISIONS.md` (the binding build-level layer from
Specs 01–03). Build-level expansion: exact files, exact schema, exact seams, exact tests.
Written before implementation. Verified against the codebase at `cefa008`
(`feat/editing`) — as of that commit **no Spec 01/02/03 code exists in the tree**
(migrations end at `v12_smart_collections`; there is no `EditStackIndex`,
`EffectiveDimensions`, or `OutputRender` file). Everything referenced from Specs 01–03
is referenced exactly as specified there; every reference to existing code was read
from the actual source, and the Surface Camera port sections were written from a full
read of the Surface sources (`PhotoRecipe.swift`, `EditHistory.swift`,
`RecipeRenderSettings.swift`, `ToneFilterStage.swift`, `WorkingSpaceImage.swift`).*

---

## 0. What this spec does, does not, and depends on

**Does:** the non-destructive edit model (ported from Surface Camera's
`PhotoRecipe`/`ToneAdjustments`/`EditHistory` patterns, extended); migrations **v20
`edits`/`edit_versions` · v21 `edit_presets`**; the per-location edit store + the real
`EditStackProviding` implementation that turns Spec 01's identity seams live; the Core
Image + Metal render pipeline (linear scene-referred, RAW hybrid, HDR-aware); the v1
adjustment set; the editor UI inside the hero viewer ((Preview | Edit) mode, neutral
backdrop, anchored panels, canvas); before/after suite + snapshots + versions;
copy/paste/sync + user presets; Edit-a-Copy for external editors; the consumer sweep
that makes thumbnails, the hero viewer, compare panes, PDF export, Drive share and the
share sheet all render through the stack; edit-stack sidecar mirroring; and the
**minimal semantic Theme token layer** that Spec 02 deviation D12 flagged as a
prerequisite for this spec's UI.

**Does not:** readouts/histogram internals/tone-zone/zebras/Looks live-thumbnails/
`.cube` import (Spec 05 — this spec leaves their seams: the curve panel's
histogram-behind slot, the left scopes card scaffold, the Looks tab hosting user
presets); import of other apps' edit values (Spec 06); social export (Spec 07);
masking, healing, layers, AI selection, dehaze, parametric curve, reorderable stack,
lens-profile DB, own demosaic, anything GPL (NEVER list, foundation §6).

**Depends on:**

| Dependency | Needed by | Nature |
|---|---|---|
| Spec 01 §3 (`EditStackIndex`, `ThumbnailCache` stack-keyed cache, `EffectiveDimensions`, `OutputRender`) | everything | **Hard.** Not yet built. If this spec builds first, it builds those seams to Spec 01's text verbatim as step 0 (§13) — their tests carry too. |
| Spec 02 §1.5/§6.3 (v17 stacks + `StackStore`) | Edit-a-Copy "copy returns stacked with its parent" | Soft. If v17 is unbuilt when Edit-a-Copy lands, the copy is created/indexed/opened but not auto-stacked; one `StackStore.createStack` call is added when v17 exists (§8.4, recorded). |
| Spec 03 §8.7 forward note (compare panes) | consumer sweep | The sweep in §5.4 includes `ComparePane` when it exists; nothing here blocks on it. |
| Existing code | everything else | verified file:line references throughout |

**Migration numbering:** v20 = `edits` + `edit_versions` · v21 = `edit_presets`
(separate migrations so presets can land in a later commit without renumbering —
DECISIONS house rule). Future specs continue at **v22**.

---

## 1. The edit model — `Editing/` (new module folder, zero AppKit imports)

The `Editing/` folder is the platform-neutral core (foundation #26 / SurfaceCore
pattern): model + codec + pure render-math files import only
Foundation/CoreGraphics/CoreImage/Metal — all present on iOS — never AppKit. Extraction
into a real SPM package later is mechanical because this import rule is enforced now
(a `EditingModuleImportTests` greps the folder for `import AppKit` and fails on any).

### 1.1 `Editing/EditStack.swift`

Ported patterns from Surface (`PhotoRecipe.swift`): explicit `currentVersion` constants,
**decoding never bumps a version** (an untouched v1 stack re-encodes as v1; only
newly-constructed stacks stamp `current`), optional fields tolerate absence so old
documents decode forward without a version bump (Surface's `texture`/`crop` precedent).

```swift
nonisolated struct EditStack: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    /// Rendering-semantics version. NEVER mutated on an existing stack: when a
    /// future macOS RAW decoder or kernel change alters output, the renderer
    /// keeps the old semantics for old stacks and only NEW stacks (or an
    /// explicit, badged, user-invoked upgrade — future UI, not v1) get the new
    /// number. v1 ships exactly one process version; the plumbing (the field,
    /// the renderer switch, the refuse-to-render-newer rule) ships now so the
    /// day macOS 27 drops RAW params, no schema change is needed.
    static let currentProcessVersion = 1

    var schemaVersion: Int
    var processVersion: Int
    var rawParams: RawParams?        // non-nil only for RAW/DNG sources
    var adjustments: [Adjustment]    // fixed canonical order, at most one per case
    var masks: [Mask]                // ALWAYS [] in v1; slot reserved (foundation §6)

    static func fresh() -> EditStack   // stamps both current versions, empty adjustments
    var isNeutral: Bool                // every group absent-or-neutral AND rawParams neutral
}

/// Reserved. Codable with no cases is awkward, so v1 ships a struct that always
/// encodes `{}` and decodes anything to itself — the slot exists in the JSON
/// shape from day one, which is what "reserved" has to mean for sidecars.
nonisolated struct Mask: Codable, Equatable, Sendable {}
```

**`Adjustment` is enum-tagged with one typed params struct per group** — the pre-spec's
`[Adjustment]` shape, with reorderability made unrepresentable: the canonical order is
the declaration order below, `EditStack.normalized()` (applied on decode and before
encode/hash) sorts by case and drops duplicates keeping the last, and the renderer
iterates its OWN fixed chain (§4.3) — it never derives order from the array. There is
no API that reorders.

```swift
nonisolated enum Adjustment: Equatable, Sendable {
    case tone(ToneParams)
    case color(ColorParams)
    case presence(PresenceParams)
    case curve(CurveParams)
    case geometry(GeometryParams)
    case vignette(VignetteParams)
}
```

Codable via an explicit keyed wrapper (`{"type":"tone","params":{…}}`, custom
`init(from:)`/`encode(to:)`): a synthesized enum coding would make the JSON shape an
implementation accident, and the wrapper is what lets a future case decode-fail
*detectably* (unknown `type` → the whole stack decode throws — see the §1.6 stale-blob
rule) instead of silently misparsing.

Every params struct: all-`Double` (plus the few Bools/arrays noted), `static let
neutral`, `var isNeutral: Bool`, `func clamped() -> Self` (the `ToneAdjustments`
pattern, verbatim shape from Surface).

```swift
nonisolated struct ToneParams: Codable, Equatable, Sendable {
    var exposureEV: Double = 0      // −5…+5 EV — stored in REAL units (photographic stops)
    var contrast: Double = 0        // −1…+1
    var highlights: Double = 0      // −1…+1
    var shadows: Double = 0         // −1…+1
    var whites: Double = 0          // −1…+1
    var blacks: Double = 0          // −1…+1
}

nonisolated struct ColorParams: Codable, Equatable, Sendable {
    var temperature: Double = 0     // −1…+1, mapped in MIRED (§4.4) — never raw Kelvin
    var tint: Double = 0            // −1…+1
    var vibrance: Double = 0        // −1…+1
    var saturation: Double = 0      // −1…+1
}

nonisolated struct PresenceParams: Codable, Equatable, Sendable {
    var clarity: Double = 0         // −1…+1 (midtone local contrast)
    var texture: Double = 0         // −1…+1 (fine local contrast)
    var sharpen: Double = 0         //  0…+1
    var noiseReduction: Double = 0  //  0…+1
}

nonisolated struct CurveParams: Codable, Equatable, Sendable {
    struct Point: Codable, Equatable, Sendable { var x: Double; var y: Double } // unit coords
    var rgb: [Point] = []           // empty = identity; strictly increasing x; ≤ maxPoints
    var red: [Point] = []
    var green: [Point] = []
    var blue: [Point] = []
    static let maxPoints = 16
}

nonisolated struct GeometryParams: Codable, Equatable, Sendable {
    /// Normalized crop in UNIT coordinates of the display-oriented, straightened
    /// image (top-left origin). nil = full frame. Normalized, not pixels, so the
    /// same stack renders identically at thumbnail/screen/export resolution —
    /// the render-consistency rule applied to geometry.
    var crop: CropRect?             // struct { x, y, w, h } all 0…1, w/h > 0
    var straightenDegrees: Double = 0   // −45…+45
    var quarterTurns: Int = 0           // 0…3, clockwise
    var flipH: Bool = false
    var flipV: Bool = false
    /// UI restore only (which preset chip was active); rendering reads `crop`.
    var aspectPresetID: String? = nil

    /// Post-geometry display size for a source display size — pure, unit-tested.
    /// This is what EffectiveDimensions/the provider serve to layout (§3.4).
    func appliedDisplaySize(to source: CGSize) -> CGSize
}

nonisolated struct VignetteParams: Codable, Equatable, Sendable {
    var amount: Double = 0          // −1…+1 (negative darkens, positive lightens)
    var midpoint: Double = 0.5      //  0…1
    var feather: Double = 0.5       //  0…1 — normalized; renderer scales by long edge
}

nonisolated struct RawParams: Codable, Equatable, Sendable {
    var lensCorrection: Bool = true
    /// CIRAWFilter decoder version pinned at FIRST edit (best supported then),
    /// so a later macOS upgrading its default demosaic doesn't silently change
    /// an edited photo. nil = old stack from before pinning existed → renderer
    /// uses the lowest still-supported version. Gated on
    /// `supportedDecoderVersions` at render (§4.5).
    var decoderVersion: Int? = nil
    static let neutral = RawParams()
}
```

**Where the routing lives, not the storage:** the user's Temperature/Tint/NR/Sharpen
sliders are stored once (in `ColorParams`/`PresenceParams`) regardless of source kind;
the *renderer* routes them to `CIRAWFilter` params for RAW sources and to the CI chain
for encoded sources (§4.5). `RawParams` holds only what has no encoded-source
equivalent. This keeps copy/paste/presets working across RAW↔JPEG with one model.

### 1.2 `Editing/EditStackCodec.swift` — canonical JSON + the stack hash

```swift
nonisolated enum EditStackCodec {
    /// Canonical bytes: JSONEncoder with `.sortedKeys` (the SidecarStore
    /// precedent, Filesystem/SidecarStore.swift:25) over `stack.normalized()`.
    static func encode(_ stack: EditStack) throws -> String
    /// nil for: undecodable JSON, schemaVersion > currentSchemaVersion.
    /// A processVersion > current DECODES (the model is forward-shaped) — the
    /// renderer is what refuses it (§4.2).
    static func decode(_ json: String) -> EditStack?
    /// SHA-256 hex of the canonical bytes — the `stack_hash` and the thumbnail
    /// cache-key component. Full 64-char hex (CryptoKit, exactly the
    /// ThumbnailCache.cacheKey pattern at ThumbnailCache.swift:341-350).
    static func hash(_ stack: EditStack) -> String
}
```

The hash is over canonical bytes, so hash stability is testable and encoder-ordering
churn can't silently re-key every edited thumbnail (`EditStackCodecTests` pins a
fixture stack's exact hash).

### 1.3 `Editing/EditHistory.swift` — the Surface port, near-verbatim

Surface's `EditHistory` (App/Photo/EditHistory.swift, 46 LOC) ports with its shape
intact: a plain value type over a state array + cursor, `push` deduping
(`guard state != current`), truncate-forward on push, `undo()`/`redo()` returning the
new current. Two adaptations:

- The state type is the whole `EditStack` (Surface's `EditState` was
  adjustments + crop; Muse's stack IS that, generalized).
- A `capacity = 100` cap (drop-oldest) — Surface never needed one because a session
  edited one photo briefly; an editor session can accumulate hundreds of slider
  commits and each state is a full stack copy.

**Session-only, on purpose** (deviation D3): `push` fires on gesture END, not per
slider tick (§6.5), undo/redo walk it, and it dies with the edit session. The
*persistent* record foundation §6 demands ("persistent — RawTherapee's session-only
history is the anti-pattern") is the stack itself + snapshots + versions (§1.4/§7):
what RawTherapee loses on close is your EDIT; Muse's edit is always persisted, and any
state worth returning to across sessions is one "Save Snapshot" click.

### 1.4 Versions & snapshots — one table, two kinds

Foundation §6 wants both **virtual copies** (multiple stacks per photo, grid badge,
digiKam pattern) and **snapshots** (freeze current state, compare any two via wipe).
Both are "a named, frozen EditStack for this (file, parent_dir)" — one `edit_versions`
table with a `kind` column (§2.1), differing only in surface: versions appear in the
editor's version switcher + drive the grid badge; snapshots appear in the
before/after compare picker.

**A version is a switchable stack, not a second grid tile** (deviation D2): exactly one
stack — the `edits` row — is CURRENT and renders everywhere (grid, hero, exports);
switching versions copies the chosen version's stack into the current row (the previous
current is preserved as a version automatically on first switch, so nothing is lost).
Rendering versions as parallel grid presences would fork `FileNode` identity —
selection, collections, stacks, tileFrames, search results are all path-keyed, and a
path can't appear twice. digiKam's affordance (see the versions at a glance) is
delivered by the badge + switcher instead.

### 1.5 Data-grain rule (binding, from DECISIONS)

The edit stack is per **`(file_id, parent_dir)`** — the tags/notes grain, never
content-keyed, never a column on `files` ("**No `files.stack_hash` column, ever**").
Consequence, inherited verbatim from the notes precedent: **the `edits` and
`edit_versions` rows must follow tags/notes through EVERY identity/folder-key
rewrite** or edits are silently orphaned (data loss). The four seams are wired in §3.6.

### 1.6 Stale/foreign blob rule

`EditStackCodec.decode` returning nil (newer schema, corrupt JSON) and a decodable
stack whose `processVersion > currentProcessVersion` both render as **the original
image** — never a partial stack (silently dropping one adjustment changes the photo's
look, which is worse than showing the unedited photo) — and the stored blob is **never
rewritten or deleted by the render path**. Only an explicit user edit (which starts
from what's renderable) or Reset overwrites it. Same consequence class as
`SmartRuleSet`'s decode-empty-on-older-builds, recorded the same way.

---

## 2. Schema

House rules per DECISIONS: registered at the end of `Database.makeMigrator()`
(`Database/Database.swift:63`, currently ending at `v12_smart_collections`, line 357),
GRDB DSL, records in `Database/Records.swift` (snake_case, `Codable + FetchableRecord +
MutablePersistableRecord`, inserted as `var`), every child table cascades on file
delete (`Housekeeping.pruneUnreachable` unchanged — cascade handles children).

### 2.1 `v20_edits`

```swift
migrator.registerMigration("v20_edits") { db in
    try db.create(table: "edits") { t in
        t.column("file_id", .text).notNull()
            .references("files", onDelete: .cascade)
        t.column("parent_dir", .text).notNull()   // TagScope.parentDir — the tags/notes key
        t.column("stack", .text).notNull()        // EditStackCodec canonical JSON
        t.column("stack_hash", .text).notNull()   // EditStackCodec.hash(stack)
        t.column("process_version", .integer).notNull()  // denormalized for cheap queries/badging
        t.column("updated_at", .integer).notNull()       // epoch seconds; sidecar LWW clock
        t.primaryKey(["file_id", "parent_dir"])
    }
    try db.create(table: "edit_versions") { t in
        t.column("id", .text).primaryKey()               // UUID string
        t.column("file_id", .text).notNull()
            .references("files", onDelete: .cascade)
        t.column("parent_dir", .text).notNull()
        t.column("kind", .text).notNull()                // "version" | "snapshot"
        t.column("name", .text).notNull()
        t.column("stack", .text).notNull()
        t.column("created_at", .integer).notNull()
    }
    try db.create(index: "edit_versions_scope_idx", on: "edit_versions",
                  columns: ["file_id", "parent_dir"])
}
```

- One row per (file, folder) = one CURRENT stack. `stack_hash` stored (not derived at
  read time) because the provider index (§3.4) is built from a single SELECT with no
  JSON decode.
- A row whose stack `isNeutral` is **deleted, not stored** (Reset removes the row —
  "no edit" is the absence of a row, the `NoteStore.write` blank-deletes rule), so
  `stackHash(for:)` goes back to nil and the thumbnail cache key reverts to the
  original-bytes key (instant revert, Spec 01's promise).

### 2.2 `v21_edit_presets`

```swift
migrator.registerMigration("v21_edit_presets") { db in
    try db.create(table: "edit_presets") { t in
        t.column("id", .text).primaryKey()
        t.column("name", .text).notNull()
        t.column("stack", .text).notNull()     // geometry group EXCLUDED at save (§7.4)
        t.column("created_at", .integer).notNull()
        t.column("updated_at", .integer).notNull()
    }
}
```

Library-global (a preset is a look, not a per-file fact). No UNIQUE on `name` —
duplicate names are the user's business; ordering is `name COLLATE NOCASE`.

Records: `EditRow`, `EditVersionRow`, `EditPresetRow` — exactly the `NoteRow` shape.

### 2.3 Sidecar fields (`Filesystem/Sidecar.swift`)

`Sidecar` gains two optional fields with `= nil` defaults so pre-edit sidecars decode
unchanged (the `note` precedent at Sidecar.swift:45):

```swift
var edit_stack: String? = nil       // EditStackCodec canonical JSON of the CURRENT stack
var edit_updated_at: Int64? = nil   // edits.updated_at — the per-FIELD clock for edits
```

- **Only the current stack rides the sidecar** — versions/snapshots don't (deviation
  D11): they multiply sidecar size per photo, and the portable promise ("another
  device hydrates the full experience") is the photo as it looks. Recorded limitation.
- `Sidecar.merge` (the analyze path): edits resolve like the note — a scalar with a
  field clock, and **union semantics never delete**:
  `winner.edit_stack/edit_updated_at = (the side with the greater non-nil
  edit_updated_at) ?? (the other side)`. A device that never edited exports nil and
  can't clobber another device's edit; between two edits the newer `edit_updated_at`
  wins (a real per-field clock, unlike the note's fresh-side heuristic — edits get the
  clock because `edits.updated_at` exists; nothing about this makes the wider
  per-field-clock project harder, it's a down payment on it).
- `Sidecar.resolveForWrite(fresh:existing:mergeExisting:noteAuthoritative:)`
  (Sidecar.swift:168) gains `editAuthoritative: Bool = false`: only the edit-save /
  reset export path passes true (fresh wins including a clear); every other manual
  export (tag/rating/note edits) preserves the on-disk edit field exactly as the note
  rule does (`out.edit_stack = existing.edit_stack ?? fresh.edit_stack`, same for the
  clock) — an unrelated tag edit must never wipe an edit another device wrote.
- `Sidecar.build(from:tags:updatedAt:note:)` gains `edit: (stack: String, updatedAt:
  Int64)? = nil`; `AnalyzePipeline.writeSidecarIfICloud`
  (Intelligence/AnalyzePipeline.swift:340) reads the `edits` row for `(fileID, dir)`
  inside its existing bundle `queue.read` and passes it through.
- `SidecarHydrator`: on hydrating a sidecar carrying `edit_stack`, call
  `EditRecordStore.applyHydrated(json:incomingUpdatedAt:fileID:parentDir:db:)` —
  row-level LWW identical to `NoteStore.applyHydrated` (NoteStore.swift:46): a
  strictly-newer local `updated_at` wins; otherwise the incoming stack lands (nil
  incoming never deletes — absence of the field is not a clear). After any applied
  edit: `EditStore` index refresh + thumbnail invalidation for that path (§3.5).

### 2.4 New sidecar/export seam summary

| Path | mergeExisting | editAuthoritative | Result for `edit_stack` |
|---|---|---|---|
| analyze pass (`analyzeOne` → `writeSidecarIfICloud(mergeExisting: true)`) | true | — | `Sidecar.merge` clock rule |
| tag/rating/import edits (`exportSidecarsAfterTagEdit`) | false | false | on-disk value preserved |
| note edit (`setNote`) | false | false (note true) | on-disk value preserved |
| **edit save / reset** (new `exportSidecarsAfterEditChange`) | false | **true** | fresh wins, including clear |

`AnalyzePipeline.exportSidecarsAfterEditChange(for urls: [URL])` mirrors
`exportSidecarsAfterTagEdit` (AnalyzePipeline.swift:379) with
`editAuthoritative: true`.

---

## 3. `EditStore`, the provider, and the carry seams

### 3.1 `Database/EditRecordStore.swift` — pure DB funcs (the `NoteStore` shape)

```swift
nonisolated enum EditRecordStore {
    static func read(fileID: String, parentDir: String, db: GRDB.Database) throws -> EditRow?
    /// Upsert; a neutral stack DELETES the row (§2.1). Also prunes edit_versions?
    /// NO — reset clears the current stack only; versions/snapshots survive a
    /// reset (they are the user's saved states; Reset means "back to original",
    /// not "forget my experiments").
    static func write(stackJSON: String, hash: String, processVersion: Int,
                      fileID: String, parentDir: String, updatedAt: Int64,
                      db: GRDB.Database) throws
    static func delete(fileID: String, parentDir: String, db: GRDB.Database) throws
    static func applyHydrated(json: String, incomingUpdatedAt: Int64,
                              fileID: String, parentDir: String, db: GRDB.Database) throws

    // Versions/snapshots
    static func versions(fileID: String, parentDir: String, db: GRDB.Database) throws -> [EditVersionRow]
    static func addVersion(_ row: EditVersionRow, db: GRDB.Database) throws
    static func deleteVersion(id: String, db: GRDB.Database) throws

    /// Carry BOTH tables from one (file_id, parent_dir) scope to another —
    /// mirrors NoteStore.carry (NoteStore.swift:94) exactly: INSERT OR IGNORE
    /// (never clobbers a destination edit — a copy already living at the target
    /// keeps its own stack), then delete-source when `deleteOriginal`.
    static func carry(fromFileID: String, fromDir: String,
                      toFileID: String, toDir: String,
                      deleteOriginal: Bool, db: GRDB.Database) throws
    /// Mirrors NoteStore.carryAll (NoteStore.swift:113): move every scope of one
    /// identity onto another, for the sole-alive-path collision.
    static func carryAll(fromFileID: String, toFileID: String, db: GRDB.Database) throws
}
```

(`edit_versions` rows carried in `carry`/`carryAll` get fresh UUID `id`s on copy — the
PK is the version id, not the scope.)

### 3.2 `Models/EditStore.swift` — Pattern B store (AppState frozen)

```swift
@MainActor final class EditStore: ObservableObject {
    static let shared = EditStore()
    /// Bumped on any stack change anywhere (save/reset/hydrate/carry-refresh).
    /// gridSignature folds this in (§5.5); NOT consumed per-tile (tiles refresh
    /// via markContentChanged, §3.5).
    @Published private(set) var generation = 0

    func stack(for url: URL) async -> EditStack?          // DB read via scope
    func save(_ stack: EditStack, for url: URL) async     // §3.5 sequence
    func reset(for url: URL) async                        // delete row, same sequence
    func versions(for url: URL) async -> [EditVersionRow]
    func saveVersion(name: String, kind: String, stack: EditStack, for url: URL) async
    func switchToVersion(_ id: String, for url: URL) async
    func rebuildIndex() async                             // full provider-index rebuild
    func warmIndex(paths: [String]) async                 // per-folder incremental warm
}
```

Sanctioned AppState integration cost (DECISIONS): **zero cancellables** — nothing in
the shell re-renders on `generation` except the grid, which reads it through
`gridSignature` (already a per-render computed string, GridView.swift:677). No new
`@Published` on AppState.

### 3.3 `Models/EditStackIndex.swift` provider — Spec 01's seam goes live

Spec 01 defined the seam; this spec installs the real provider:

```swift
/// Lock-guarded nonisolated(unsafe) static table — the ImageHeaderSizeCache
/// pattern verbatim (Components/ImageHeaderSizeCache.swift:37-38): read from the
/// thumbnail pipeline OFF-main, written by EditStore on the main actor.
struct LiveEditStackProvider: EditStackProviding {
    func stackHash(for url: URL) -> String?     // index lookup by standardized path
    func croppedSize(for url: URL) -> CGSize?   // §3.4
}
```

`EditStackIndex.installProvider(LiveEditStackProvider())` runs in `MuseApp`'s `.task`
(MuseApp.swift:102) before the backfills, followed by a fire-and-forget
`EditStore.shared.rebuildIndex()`.

### 3.4 The index and `croppedSize`

Index entry per standardized alive path: `(stackHash: String, geometry:
GeometryParams?, processRenderable: Bool)`. Built by one SELECT joining `edits` ×
alive `paths` (matching each path whose `TagScope.parentDir(ofPath:)` equals the row's
`parent_dir` and whose `file_id` matches), decoding ONLY the geometry group out of the
stack JSON (cheap; the full stack is not held resident — the edited set is small
relative to the library, but the rule "no code may assume RAM-residency" is honored by
keeping entries to ~a hash + 6 doubles).

`croppedSize(for url:)` = `geometry.appliedDisplaySize(to:
ImageHeaderSizeCache.cached(url))` — nil when either side is unknown (layout falls
back to the header size, exactly Spec 01's `EffectiveDimensions` contract). No I/O in
the provider, ever: it serves view-body-safe lookups like `ImageHeaderSizeCache.cached`.

### 3.5 The save sequence (one place, in order)

`EditStore.save(stack:for:)`:

1. Resolve `(fileID, parentDir)` from the alive path (the `tagScopes` pattern,
   TagStore.swift:18-30). Not indexed yet → no-op (can't happen from the editor; the
   file was open).
2. `queue.write`: `EditRecordStore.write` (or `delete` for neutral).
3. Update the in-memory provider index entry for this path.
4. `appState.markContentChanged([path])` (AppState.swift:119) — this is the existing
   one seam that BOTH invalidates every thumbnail variant (which, per Spec 01, drops
   current-stack AND nil-stack keys) and bumps the tile's content token so a visible
   tile re-fetches (`TileLoadID`, GridView.swift:960). Reused deliberately (deviation
   D7): the semantic is "what this path displays changed", and building a parallel
   edits-version-per-tile channel would duplicate it exactly. `markContentChanged`
   also invalidates `ImageHeaderSizeCache` for the path — harmless (refilled from the
   unchanged header on next touch).
5. `generation += 1` (grid relayout via `gridSignature` — a crop changes the tile's
   aspect).
6. `AnalyzePipeline.shared.exportSidecarsAfterEditChange(for: [url])`.

`analyzed_hash`, `files.width/height`, `content_hash` are **untouched** — an edit
never changes content identity (Spec 01 durable constraint, restated).

### 3.6 Carry seams — the four identity/folder rewrites

Each site adds one `EditRecordStore` call **directly beside the existing
`NoteStore` call**, same arguments, same copy-vs-move flag:

| Seam | Site | Call |
|---|---|---|
| Indexer hash-collision, sole alive path | Indexer.swift:201 (`NoteStore.carryAll`) | `EditRecordStore.carryAll(fromFileID: file.id, toFileID: target.id, db:)` |
| Indexer hash-collision, shared row | Indexer.swift:207 (`NoteStore.carry`) | `EditRecordStore.carry(… deleteOriginal: !keepsSiblingInDir …)` |
| Indexer shared-row split | Indexer.swift:297 (`NoteStore.carry`) | same shape, onto `newFile.id` |
| In-app move | FileMoveMigration.swift:67 (`NoteStore.carry`) | same file_id, oldDir → newDir, same sibling rule |
| Folder rename | FolderRenameMigration.apply (FolderRenameMigration.swift:38) | `edits` + `edit_versions` get the SAME stale-target pre-clear (DELETE at the new prefix — `edits`' composite PK collides exactly like `notes`') and the SAME `SUBSTR`-prefix `parent_dir` rewrite as `tags`/`notes` (lines 70-101) |

(That's five call sites across four seams — the collision seam has two branches.)
After any of these runs, the provider index is stale for the affected paths;
`AppState.moveFiles` and the folder-rename completion call
`EditStore.shared.rebuildIndex()` fire-and-forget, and the Indexer-driven cases are
covered by the existing post-reconcile `reloadCurrentFiles` publish, whose completion
adds `EditStore.shared.warmIndex(paths:)` for the folder in view (the
`StacksStore.reload(for:)` pattern from Spec 02).

**Pure edit-in-place** (external overwrite, sole path — Indexer.swift:315-326): the
row's `file_id`/`parent_dir` don't change, so **the stack survives an external
byte-edit** (deviation D6): every parameter is normalized (unit crop, fraction-of-long-
edge radii), so it still applies; it is user data and non-destructive either way, and
Reset is one click. The thumbnail refresh comes free — the watcher already routes
content changes through `markContentChanged`.

---

## 4. The render pipeline — `Editing/Render/`

### 4.1 Working-space type safety — `Editing/Render/WorkingImage.swift`

Surface's `WorkingSpaceImage.swift` ports whole (50 LOC): `EncodedImage` /
`LinearImage` wrappers, the single crossing `EncodedImage.toLinearWorkingSpace()`
(`matchedToWorkingSpace(from:)`), `LinearImage.oriented(forExifOrientation:)`, and the
named constructor `LinearImage.alreadyDecodedFromFile(_:)` for `CIImage(contentsOf:)`
sources (Core Image applies the file's transfer function on load — decoding again is
the documented 2.3×-too-dark bug the type exists to prevent; the doc block travels
with the port). One extension: `LinearImage` gains the chain-building methods (§4.3),
so an `EncodedImage` *cannot* have adjustments applied — the compile-time guarantee
foundation §3 asks for.

### 4.2 `Editing/Render/EditRenderer.swift`

```swift
nonisolated enum EditRenderer {
    /// Pure chain: linear scene-referred input → adjusted linear output.
    /// `longEdge` is the SOURCE's display long edge in pixels — every
    /// scale-dependent radius is a fraction of it (§4.6), which is the whole
    /// render-consistency mechanism.
    static func apply(_ stack: EditStack, to image: LinearImage,
                      sourceLongEdge: CGFloat) -> LinearImage

    /// Whether this renderer can honor the stack's semantics (§1.6).
    static func canRender(_ stack: EditStack) -> Bool   // processVersion <= current

    /// Decode + apply + return a display-referred CGImage at ≤ maxPixel long
    /// edge. THE one entry every consumer uses (thumbnail, hero ladder, compare,
    /// PDF). Runs withinDecodeBudget first (durable constraint — this is an
    /// automatic decode site). Returns nil when undecodable (caller falls back
    /// to its existing original-pixels path).
    static func render(url: URL, stack: EditStack, maxPixel: Int) -> CGImage?

    /// Full-resolution export for OutputRender/Edit-a-Copy: lazy
    /// CIImage(contentsOf:) source (CI tiles internally — the 60MP-on-8GB
    /// answer), rendered via the export context (§4.7) straight to an encoded
    /// file. Throws on any failure (fail closed — never silently ship the
    /// unedited original as if edited).
    static func exportFile(url: URL, stack: EditStack, to dest: URL,
                           format: OutputFormat) throws
}
```

`render(url:stack:maxPixel:)` decode strategy: bounded `CGImageSourceCreateThumbnail`
at `min(maxPixel scaled up by 1/cropFraction, 4096)` when the stack crops (so a tight
crop still fills its thumbnail sharply), else at `maxPixel` — through
`ThumbnailCache.withinDecodeBudget` first, always. HDR sources load with
`.expandToHDR` (§4.8).

### 4.3 Fixed chain order (the renderer's own, never the array's)

```
RAW only:  CIRAWFilter (neutralized base + WB + luminance NR + sharpness + lens corr, §4.5)
           → outputImage (linear working space)
Encoded:   decode → EncodedImage → toLinearWorkingSpace() → oriented()

1. geometry        quarterTurns/flip → straighten (rotate + auto-inscribe scale) → crop
2. tone            exposure → temperature/tint (encoded sources only) → toneBands
                   (highlights/shadows/whites/blacks) → contrast
3. curve           display-referred domain (§4.4)
4. color           vibrance → saturation
5. presence        noiseReduction → clarity → texture → sharpen
6. vignette        on the CROPPED frame
7. display         (consumer-side: tone-map headroom + output color space, §4.7/4.8)
```

Geometry first: everything downstream runs on fewer pixels, and vignette/clarity are
defined relative to the visible frame. The order is code, documented here, and pinned
by the golden tests — never data.

### 4.4 Per-adjustment operators (the concrete v1 choices)

- **Exposure** — `CIExposureAdjust`, `ev = exposureEV` directly (linear gain on
  un-clamped scene-referred data — recovery of >1.0 values is real; the
  `HighlightRecoveryTests` pin, §12).
- **Temperature/Tint (encoded sources)** — `CITemperatureAndTint`, source neutral
  D65, target computed in **MIRED** (Surface's ToneFilterStage.swift:46-65 lesson,
  ported with its numbers: +1 ↦ 3000 K-equivalent warm, the cool side the same mired
  distance, clamped ≥ 25 mired). Tint ±1 ↦ ±50 on the tint axis. **RAW sources skip
  this filter entirely** — WB happened at demosaic (§4.5); applying it again
  post-demosaic is the foundation's named mistake.
- **toneBands (Highlights/Shadows/Whites/Blacks)** — one custom `[[stitchable]]`
  Metal `CIColorKernel` (`Editing/Render/EditKernels.metal`): per-pixel luminance-
  weighted exposure-space gains. Smooth raised-cosine weight bands over log2
  luminance: highlights weight peaks in the top ~2 stops below diffuse white, shadows
  in the bottom, whites/blacks pull the endpoints; gains multiply un-clamped linear
  RGB (never per-channel curves here — hue-preserving by construction). Neutral at 0
  is an exact identity (all gains 1). Constants (band centers/widths, max gain
  ±1 ↦ ±1.5 EV in-band) are named in the kernel's Swift wrapper — **slider-feel
  tuning is an owner step (§14); Surface's history is three rounds of "baby steps"
  corrections, so the mapping constants are declared once and expected to move.**
- **Contrast** — `CIColorControls` contrast `1 + 0.75 × value` about mid-gray
  (Surface's calibrated round-3 value, ToneFilterStage.swift:67-77), saturation/
  brightness at identity.
- **Curve** — CPU **monotone-cubic spline (Fritsch–Carlson)** through the points →
  1024-entry LUT per channel → `CIColorCurves` with an explicit
  `inputColorSpace = sRGB`. Evaluated in the **display-referred (sRGB-encoded)
  domain**: users read a curve against the histogram of what they see;
  `CIColorCurves`' color-space parameter does the linear↔encoded round-trip
  correctly. `CIToneCurve` is not used anywhere (5-point cap + black-output bug —
  foundation's "unusable" verdict; Surface used it only for its fixed 5-point
  blacks/whites, which Muse's toneBands kernel replaces). Pure spline in
  `Editing/CurveLUT.swift`, unit-tested (monotone output for monotone input,
  endpoints exact, identity for empty points).
- **Vibrance / Saturation** — `CIVibrance` (`amount = vibrance`), `CIColorControls`
  (`saturation = 1 + saturation`).
- **Noise Reduction** — encoded sources: `CINoiseReduction` (noise/sharpness levels
  mapped from the one slider); RAW: routed to `CIRAWFilter.luminanceNoiseReduction`
  at decode (§4.5) and the CI filter skipped.
- **Clarity / Texture** — ONE shared `[[stitchable]]` Metal blend kernel
  (midtone-weighted local contrast, the Pat David formulation foundation §6 names):
  `result = base + amount × midtoneWeight(luma) × (base − blurred)`, with the blur an
  attached `CIGaussianBlur` at radius `clarityRadiusFraction × longEdge` (named
  constant, ~0.015) for clarity and `textureRadiusFraction × longEdge` (~0.003) for
  texture — two invocations of the same kernel with different radius/weight
  constants.
- **Sharpen** — `CIUnsharpMask`, radius `sharpenRadiusFraction × longEdge` (~0.0008,
  named), intensity from the slider. Normalized to the source long edge like every
  radius — that is what makes the consistency test (§12) pass; output-referred
  sharpening is a Spec 07 (social export) concern, not this pipeline's.
- **Vignette** — `CIVignetteEffect` centered on the cropped extent, radius from
  `midpoint`, falloff from `feather` scaled by the cropped long edge, negative/
  positive `amount` darken/lighten.

Kernels: `[[stitchable]]` MSL in `Editing/Render/EditKernels.metal`, loaded via
`CIColorKernel(functionName:fromMetalLibraryData:)` from the default metallib —
**never CIKL** (deprecated). Build note (there are currently ZERO `.metal` files in
the target — the water/burn shaders were removed): adding the file gives the target a
Metal compile phase again; the CI-kernel-specific legacy flags (`-fcikernel`) are NOT
used — stitchable kernels compile in the standard metallib. A build-time smoke test
(`EditKernelLoadTests`) loads every kernel by name so a broken build phase fails in
CI, not at first slider drag.

### 4.5 RAW — `Editing/Render/RawSource.swift`

- `CIRAWFilter(imageURL:)`; **neutralize Apple's default look** for the editing base
  (WWDC21 §10160, foundation's exact list): `baselineExposure = 0; shadowBias = 0;
  boostAmount = 0; localToneMapAmount = 0; isGamutMappingEnabled = false`.
- **Every property set is gated on `filter.isSupported(option:)`** — camera coverage
  varies; an unsupported set is skipped silently (named helper
  `setIfSupported(_:_:)` so no call site forgets).
- Decoder: on first edit, pin `rawParams.decoderVersion` to the best of
  `filter.supportedDecoderVersions` (prefer `.version9` where present — Neural Engine
  demosaic+denoise); at render, apply the pinned version when still supported, else
  the nearest supported (recorded, not hidden: the INFO card's process line shows the
  substitution — Spec 05 surfaces it properly).
- Slider routing: `ColorParams.temperature/tint` → `neutralTemperature` /
  `neutralTint` as offsets from the file's as-shot neutral, temperature offset applied
  in MIRED on the as-shot value (same perceptual-uniformity rule as the encoded path);
  `PresenceParams.noiseReduction` → `luminanceNoiseReductionAmount`;
  `PresenceParams.sharpen` → `sharpnessAmount`; `rawParams.lensCorrection` →
  `isLensCorrectionEnabled`. Highlight recovery is inherent: the neutralized linear
  output keeps >1.0 data and toneBands/exposure operate on it un-clamped.
- `filter.outputImage` is already linear working space → wrapped
  `LinearImage.alreadyDecodedFromFile` and fed to chain step 1.
- **Editable kinds** (Path A): `.image` (JPEG/HEIC/PNG/TIFF + the rest ImageIO
  decodes) and `.raw` (incl. DNG). **`.psd` is excluded** — foundation §6's Path A
  list is "JPEG/HEIC/PNG/TIFF/RAW/DNG"; a PSD is a layered document whose flat
  composite Muse only previews; editing it is Path B's job (deviation D9). The
  (Preview | Edit) control simply doesn't render for `.psd`.

### 4.6 Scale normalization + the consistency test

Every scale-dependent parameter (clarity/texture/sharpen radii, vignette feather,
noise-reduction radius) is computed as `fraction × sourceLongEdge` where
`sourceLongEdge` is the ORIGINAL display long edge **scaled by the ratio actually
decoded** (a 1024px decode of a 6000px photo passes 1024 as the effective long edge,
so a 0.015 clarity radius is 15px at full res and 2.6px in the thumbnail — the same
visual weight). This is Surface's grain-cell normalization
(`(1.5 + 4.5·grainSize) · longEdge / 4032`) generalized, and it is what the
**required** test asserts: `EditRenderConsistencyTests` renders one fixture stack
(every group non-neutral) at 256 / 1024 / full over two fixture images (landscape +
portrait-EXIF-rotated), downsamples all to 256, and asserts mean per-channel error
below a tolerance (start 3/255; goldens regenerate via a checked-in flag, the Surface
golden-test culture).

### 4.7 Contexts & canvas

- `Editing/Render/RenderContexts.swift`:
  - `preview`: one long-lived `CIContext(mtlDevice:options:)` with
    `.cacheIntermediates: true`, `.workingColorSpace:
    CGColorSpace(name: CGColorSpace.extendedLinearSRGB)`, `.name: "muse.edit.preview"`.
  - `export`: created per export, `.cacheIntermediates: false`,
    `.memoryLimit: 1_073_741_824` (1 GB), released after. **No Extended Virtual
    Addressing entitlement** — it does not exist on macOS (iOS-only); the pre-spec
    line is satisfied by CI's tiling + the memory limit (deviation D4).
- Canvas: `Views/Editor/EditCanvasView.swift`, an `NSViewRepresentable` **MTKView**
  (`isPaused = true`, `enableSetNeedsDisplay = true`, framebufferOnly = false)
  drawing via `CIRenderDestination` into the drawable at screen scale. This is the
  app's only MTKView (no Metal remained after the shader removals — the durable note
  updates to "the editor's canvas + CI kernels are the sanctioned Metal surface").
- **Slider coalescing** — `Editing/Render/RenderCoalescer.swift`, an actor: at most
  ONE render in flight; a newer request overwrites the pending slot; on completion
  the pending (latest) params render next. Slider drags therefore render at whatever
  rate the GPU sustains, never queueing (Surface's unthrottled per-tick loop is the
  named anti-pattern). Preview renders from a session-held decoded proxy
  (`min(canvasLongEdge × scale × 2.5, 4096)` — the hero ladder's exact formula,
  HeroStage.swift:446-447), re-decoded only on zoom past its resolution; **never
  full-res for preview** (M1 Air 8GB rule).

### 4.8 HDR/EDR

- Load: encoded HDR sources (gain-map HEIC) via `CIImage(contentsOf:, options:
  [.expandToHDR: true])`; nothing in the chain clamps (toneBands/exposure are gain
  ops; `CIColorCurves`' LUT domain is the one clamp point — curve input is soft-
  clipped into 0…1 with headroom folded by `CIToneMapHeadroom` BEFORE the curve when
  content headroom > 1, which is also the display transform).
- Display: `CIToneMapHeadroom` targeting the screen's current
  `maximumExtendedDynamicRangeColorComponentValue` before the canvas draw.
- Export: HDR sources export via `heifRepresentation` with the HDR image + SDR
  representation where the OS supports gain-map writing (macOS 15+ CI gain-map
  options); on 14.6 the export is the tone-mapped SDR render. **Recorded limitation
  (deviation D5): a byte-level gain-map round-trip of EDITED pixels is not
  achievable pre-15; unedited files trivially round-trip (exports of unedited files
  are the original bytes — `OutputRender` only renders when a stack exists).**

---

## 5. Consumer sweep — every pixel surface renders through the stack

The rule (new durable constraint §11.3): **any surface that shows or ships a photo's
pixels consults `EditStackIndex` and renders via `EditRenderer` when a stack exists.**
Spec 01 built the seams as identity; this is the flip.

### 5.1 Thumbnails — `ThumbnailCache.generate`

In the image-kind branch (ThumbnailCache.swift:405-408), before `imageIOThumbnail`:

```swift
if kind == .image || kind == .raw,
   let hash = EditStackIndex.stackHash(for: url),
   let stack = /* EditStackIndex resolvedStack(for:) — index-held decoded stack */,
   let cg = EditRenderer.render(url: url, stack: stack,
                                maxPixel: Int(max(size.width, size.height) * scale)) {
    return NSImage(cgImage: cg, …)
}
```

- The cache key already differs by `hash` (Spec 01), so edited PNGs live beside the
  original's untouched ones — revert is a cache hit.
- The provider index gains `resolvedStack(for:) -> EditStack?` (the decoded stack,
  cached in the index entry on first use) so the thumbnail path does no DB read.
- Render failure falls through to the original-pixels path (a wrong-but-visible
  thumbnail beats a grey tile; the hero will show the same fallback, consistently).
- `renderedVariants` is untouched — edited thumbnails render at the SAME enumerated
  sizes; `invalidate` already drops both stack variants (Spec 01).
- The prewarm sweep (`prewarmToDisk`) needs no change: it flows through the same
  `ensureDisk` → `loadOrGenerate` → `generate` path and the stack-aware key.

### 5.2 Hero viewer

- `HeroStage.loadFullRes` (HeroStage.swift:441): both the >40 MP mid-res pass and the
  sharp pass route through `EditRenderer.render(url:stack:maxPixel:)` when a stack
  exists (same targets, same `withinDecodeBudget`-first, same `!isClosing` guards and
  `HeroFlightMotion.settling` writes — the decode closure body swaps, the
  choreography does NOT change; every guard in that function is a named durable
  constraint).
- `HeroStage.open()`'s quick thumbnail is already edit-aware for free — the 320
  memory peek returns the stack-keyed bitmap.
- Aspect: `fitRect`/`sourceRect` read `EffectiveDimensions` per Spec 01's consumer
  table (a cropped photo flies to/from its cropped shape). `resolveHeaderSize()`
  consults `EffectiveDimensions.cached` first, falling back as today.
- `HeroImageViewer.loadDetails`' `naturalSize` (HeroImageViewer.swift:518) reads
  `EffectiveDimensions` before the raw header — the zoom readout's 100% means 100% of
  the EDITED geometry.
- The INFO card's Dimensions row (Spec 01 consumer table) shows effective dimensions.

### 5.3 Exports — `OutputRender` goes live

- `OutputRender.forOutput(_:)`: when `EditStackIndex.stackHash(url) != nil` and the
  stack is renderable → `EditRenderer.exportFile` into
  `FileManager.temporaryDirectory/muse-render/<uuid>/<original basename>.<ext>` and
  return that URL + hash; else identity (today's behavior). Formats
  (`OutputFormat`, named constants on `OutputRender`): same container for
  JPEG (q 0.92) / PNG / TIFF / HEIC (q 0.9); RAW sources render **JPEG q 0.92 sRGB**
  for share paths (recipients of a share can't use a RAW's bytes anyway — and the
  Drive stripper re-encodes to clean pixels regardless). Temp files are cleaned by
  the caller's existing lifecycle (the share sheet's items are read immediately;
  Drive uploads then deletes; a sweep of `muse-render/` older than 1 day runs at
  launch beside `enforceDiskCap`).
- `CollectionPDFExporter`: its `imageIOThumbnail(_:maxPixel:)`
  (CollectionPDFExporter.swift:197) — per Spec 01 already fed via `RenderedOutput` —
  uses `OutputRender.image(_:maxPixel:)`, which calls `EditRenderer.render` for
  edited files (no temp file for the PDF path; direct bounded render). Layout reads
  `EffectiveDimensions`, so pagination matches the cropped shapes.
- Drive share (`DriveClient.uploadFile`, DriveClient.swift:62) and both
  `NSSharingServicePicker` sites (SelectionMenu.swift:166-170, ShareButton.swift:44-48)
  flow through `forOutput` per Spec 01's conversions. **The metadata strip still runs
  on the post-render bytes — render first, strip second** (Spec 01 durable
  constraint, unchanged; the stripper's fail-closed behavior is untouched).
- **Backup stays excluded** (restores originals by content hash — rendering edits
  into it would corrupt the restore). Edit data itself IS in backups: the `.muselibrary`
  archive carries the DB, which now contains `edits`/`edit_versions`/`edit_presets`.

### 5.4 Compare panes (when Spec 03 is built)

`ComparePane`'s decode ladder routes through the same `EditRenderer.render` seam and
its geometry reads `EffectiveDimensions` — the Spec 03 §8.7 forward note, discharged
here. If compare lands after this spec, its implementation inherits the rule from the
new durable constraint; if before, this spec's sweep touches it.

### 5.5 Grid

- `gridSignature` (GridView.swift:677) gains `EditStore.shared.generation` as a
  component — a crop relayouts the masonry.
- `TileView.drawnAspectRatio` (GridView.swift:887) reads `EffectiveDimensions` (Spec
  01 consumer table) — ring/hover/badge hug the CROPPED photo.
- **Edited badge**: bottom-trailing mini-badge on image tiles whose path has a stack
  (top-leading = stack badge, top-trailing = star badge, bottom-leading = cull badge —
  bottom-trailing is the free corner). Glyph `slider.horizontal.3` in the star-badge
  visual family (10 pt, capsule, `badgeInset = 6`, GridView.swift:911); when the file
  also has ≥ 1 saved *version*, the badge shows `slider.horizontal.3 N` (N = version
  count + 1 — the digiKam affordance). Not a click target (the editor is one
  double-click away); VoiceOver label `String(localized: "Edited")` /
  `"Edited, %lld versions"`. Data: a small `[String: Int]` published map on
  `EditStore` (path → version count for paths in view), refreshed with
  `warmIndex(paths:)` — read straight by tiles, no AppState involvement.

---

## 6. Editor UI

### 6.1 The minimal Theme layer — `Views/Theme/Theme.swift` (prerequisite, per DECISIONS)

Spec 02 D12: the token layer "should get its own small spec before Spec 04's editor
UI". Delivered here, minimally (deviation D10):

```swift
struct Theme {
    // Roles, not colors. Defaults derive from system semantics + the mood.
    var panelFill: Color          // editor card surface
    var panelStroke: Color        // hairline
    var controlAccent: Color      // active slider track / selected tab
    var textPrimary: Color
    var textSecondary: Color
    var spacingS: CGFloat = 6, spacingM: CGFloat = 12, spacingL: CGFloat = 20
    var radius: CGFloat = 10
    var labelFont: Font           // 11pt medium — the chrome text role
    var valueFont: Font           // 11pt monospacedDigit — readouts

    static func resolve(palette: MoodPalette) -> Theme
}
private struct ThemeKey: EnvironmentKey { … }
extension EnvironmentValues { var theme: Theme }
```

Scope rule: **every NEW surface this spec adds reads `@Environment(\.theme)`** — no
raw hex, no ad-hoc constants (foundation #27's "custom layouts, system skin").
Existing surfaces are NOT migrated (opportunistic later; migrating 200 files is not
this spec). The shell injects `.environment(\.theme, Theme.resolve(palette:
appState.moodPalette))` once in `ContentView`.

### 6.2 Mode toggle + backdrop

- **(Preview | Edit) segmented control, top-center** of the hero viewer overlay —
  mounted in `HeroImageViewer` beside the chrome (a 2-segment capsule in the chrome
  visual family, white-glass fills, localized `Text("Preview")`/`Text("Edit")`;
  hidden for non-editable kinds (§4.5) and while `isClosing`/burning).
- State: `@State private var editMode = false` in `HeroImageViewer` + an
  `EditSession` (§6.3) created on entry. Entering Edit: the stage image shrinks
  slightly (the mode-change transition — a 0.25s ease scaling the fitted rect by
  0.94, matching Photos' feel) and mounts `EditorView`; `ViewerInfoColumn` and the
  parting-ripple/flight machinery are untouched (the flight already happened; Edit
  mode replaces the STAGE content, not the viewer shell).
- **Backdrop**: in Edit mode `ViewerBackdrop`'s palette wash is replaced by a flat
  neutral — `EditorBackdrop` levels (named constants): white 1.0 / light 0.85 /
  **mid 0.48 (default — the 18%-gray card as displayed, ≈ sRGB 0.48)** / dark 0.18 /
  black 0.0. Right-click on the backdrop cycles; a context menu lists all five
  (Lightroom's exact convention). Persisted in
  `AppSettings.editorBackdropKey` (String raw value, default `"mid"`, the
  AppSettings accessor pattern).

### 6.3 `Views/Editor/EditSession.swift` — per-file editing state

```swift
@MainActor final class EditSession: ObservableObject {
    let url: URL
    @Published var draft: EditStack           // live-bound by every control
    @Published private(set) var history: EditHistory
    @Published var beforePeek = false         // hold-to-peek
    @Published var compareMode: CompareMode   // .off / .sideBySide / .wipe(fraction)
    @Published var wipeAgainst: EditStack?    // snapshot compare target (nil = original)
    // canvas
    @Published var canvasZoom: CGFloat = 1    // 1 = fit; 100% button maps to pixel scale
    @Published var canvasPan: CGSize = .zero

    init(url: URL, stack: EditStack?)         // seeds draft + history baseline
    func commitGesture()                      // history.push(draft) — gesture-end only
    func undo() / redo()
    func save() async                         // EditStore.save(draft, for: url)
    func resetAll()                           // draft = .fresh(); autosaves
}
```

**Autosave**: `draft` changes debounce 400 ms into `EditStore.save` (plus an
unconditional save on exit/close/flip). There is no Cancel/Done pair — edits are
non-destructive and Reset/undo cover regret; a modal commit model would fight the
"grid is the product" promise (the tile updates as you edit).

### 6.4 Layout — `Views/Editor/EditorView.swift`

- Center: `EditCanvasView` (§4.7) rendering `session.draft` via the coalescer;
  scroll-wheel zoom + drag pan reusing `ViewerGeometry.clampZoom/clampPan`; a
  Fit / 100% pill in the editor chrome.
- **Anchored floating cards** flanking the canvas — visually detached
  (`theme.panelFill`, radius, shadow, 16pt margin) but **positionally fixed**: a card
  can be grabbed by its header and dragged, and snaps back on release (a rubber-band
  `DragGesture` whose offset animates to `.zero` on end — the Pixelmator-lesson
  middle: acknowledgment without free-floating occlusion/drift). Not persisted,
  nothing to get lost.
- Right card, tabbed **Light / Color / Looks** (per foundation's editor sketch —
  tone+presence live under Light):
  - **Light**: Exposure, Contrast, Highlights, Shadows, Whites, Blacks · then the
    Presence group (Clarity, Texture, Sharpen, Noise Reduction) · the point curve
    (`CurveEditorView`) with RGB/R/G/B channel segmented control. Tone-zone control
    slot: none in v1 (Spec 05 inserts it above the sliders).
  - **Color**: Temperature (with eyedropper), Tint, Vibrance, Saturation. HSL chips /
    grade wheels: Spec 05+/v2, slots noted.
  - **Looks**: the user-preset list (§7.4) — name rows + Apply/Save/Update/Delete.
    Spec 05 replaces the rows with the live-thumbnail browser + LUT imports; the tab
    and its store are this spec's scaffolding.
  - RAW sources append a small **RAW** section under Color: "Auto Lens Correction"
    toggle (`rawParams.lensCorrection`).
- Left card, tabbed **Info / History**:
  - **Info**: the existing EXIF summary (reuses `FileMetadata` rows — read-only).
  - **History**: the session undo stack as a list (click = jump, `history` cursor) +
    a **Snapshots** section (list + "Save Snapshot…" prompt + per-row Compare).
  - **Scopes** tab: present but empty-scaffold ("Histogram arrives with the next
    update" placeholder) — Spec 05's mount point, so the tab bar doesn't reflow when
    it lands.
- All new chrome reads `Theme`; every literal is a SwiftUI text-literal or
  `String(localized:)` (localization rule — the spec is incomplete until the French
  export passes 0 untranslated).

### 6.5 Sliders — `Views/Editor/EditSlider.swift`

One control used by every scalar adjustment: label + value readout
(`theme.valueFont`), track bound to a `Binding<Double>` with its range, **per-slider
reset** (double-click the label or the value → animates to neutral — LR convention),
option-drag for fine steps. Gesture end (and reset, and any discrete control commit)
calls `session.commitGesture()` — the one `EditHistory.push` site, so a drag is ONE
undo step (Surface's dedupe + the coalescer make mid-drag states free).

### 6.6 Curve editor — `Views/Editor/CurveEditorView.swift`

Unit-square canvas; click adds a point (≤ `CurveParams.maxPoints`), drag moves
(x clamped between neighbors — monotone by construction), double-click removes;
per-channel via the segmented control; identity-reset per channel.
**The histogram-behind seam**: `CurveEditorView(histogram: CurveHistogram?)` — a
value type of 64 luminance bins the view draws as a silent backdrop when non-nil.
This spec always passes nil; Spec 05 fills it (the seam the pre-spec demands).

### 6.7 WB eyedropper

Toggle button beside Temperature. Active: crosshair cursor over the canvas; click
samples the session's decoded proxy at the image point (pure mapping via the canvas'
fit/zoom/pan — the `RegionMath` class of math, small pure helper
`Components/CanvasPointMath.swift`, unit-tested).
- Encoded sources: solve the mired/tint offset that neutralizes the sampled pixel
  (equalize R/B via mired shift, G via tint — closed-form approximation, pure,
  tested) → write `ColorParams.temperature/tint`.
- RAW: `CIRAWFilter.neutralLocation = sampledPoint` is the public API that does
  exactly this at demosaic — the session re-reads the filter's resulting
  `neutralTemperature/neutralTint` and stores the equivalent slider offsets so the
  stack stays declarative (the stack never stores "a click location").

### 6.8 Before/after suite (DECIDED, required)

- **Hold-to-peek**: press-and-hold the `\` key (LR's before/after key) or mouse-down
  on the "Before" chrome button → `session.beforePeek = true` → the canvas renders
  the ORIGINAL (cached rendered texture — the session keeps the last original-render
  CIImage; recompute only on proxy change). Release restores.
- **⌘Y side-by-side**: `compareMode = .sideBySide` — two half-width panes
  (original | current), shared zoom/pan (the CompareGeometry normalized-center idea,
  locally).
- **Split-wipe**: `compareMode = .wipe(fraction)` — one canvas compositing
  original/current split at a draggable divider (a mask composite of the two cached
  textures — cheap, per the pre-spec).
- **Snapshots**: "Save Snapshot…" (name prompt via the shell `ModalPromptCard`
  pattern) → `edit_versions(kind: "snapshot")`. The wipe's "against" picker offers
  Original + every snapshot (`wipeAgainst`) — darktable's compare-any-two.
- Keys ride the hero's `KeyCaptureView` (Views/KeyCaptureView.swift) extended with an
  `onKey: (NSEvent) -> Bool` passthrough (returns true = consumed) — the same
  extension Spec 03's cull keys specified; whichever lands first adds it.

### 6.9 Versions UI

Editor chrome (top-right of the canvas): a version menu — current marker, saved
versions by name, "Save as Version…" (name prompt), "Delete Version" on hover rows.
Switching: `EditStore.switchToVersion` (auto-preserves the current stack as a version
first if it isn't one — §1.4), session reseeds, canvas re-renders. Grid badge count
updates via the §5.5 map.

### 6.10 Escape, keys, and gating

- **Escape in Edit mode exits to Preview, never closes the viewer** — implemented
  exactly like Spec 03's region mode: in `HeroImageViewer`'s `viewerClosing` onChange
  (HeroImageViewer.swift:161-183), after the existing immediate
  `appState.viewerClosing = false`, a new first branch
  `if editMode { exitEditMode(); return }` — the close sequence itself is untouched
  (the most protected path in the app; the consume-the-trigger pattern is the ONLY
  sanctioned interception). `EscapeResolver` is unchanged (still returns
  `.closeHero`; the viewer consumes it). If region mode (Spec 03) coexists someday,
  edit-mode's branch sits first; the two are mutually exclusive surfaces anyway.
- **Arrow keys are disabled in Edit mode** (deviation D12): `KeyCaptureView`'s
  onLeft/onRight early-return while `editMode` — flipping files mid-edit would tear
  down the session per keypress and made accidental navigation destructive-feeling.
  Preview keeps flips.
- Modal-presented additions to `AppState.modalPresented` (AppState.swift:514):
  `openWithForkRequest != nil` (§8.2) and `editPasteRequest != nil` (§7.3). The
  editor itself is NOT a modal (it's viewer content; the viewer already gates the
  grid's key catcher via `selectedFile`).
- Delete/rating/tag interactions in Edit mode: the info column is hidden (the
  canvas + panels own the width); rating keys etc. remain Preview-mode affordances.

---

## 7. Copy / Paste / Sync + user presets

### 7.1 `Editing/EditTransfer.swift` — pure semantics

```swift
nonisolated enum AdjustmentGroup: String, CaseIterable, Codable, Sendable {
    case tone, color, presence, curve, geometry, vignette, raw
}
nonisolated enum EditTransfer {
    /// The groups a stack actually adjusts (non-neutral) — the Capture One
    /// auto-select default. NOT a 60-checkbox wall.
    static func adjustedGroups(of stack: EditStack) -> Set<AdjustmentGroup>
    /// COPY-BY-VALUE: overwrite `target`'s chosen groups with `source`'s values
    /// (a group absent in source clears it in target — copying "no vignette" is
    /// copying a look). Untouched groups keep target's values. Returns a
    /// normalized stack stamped with target's schema/process versions.
    static func apply(groups: Set<AdjustmentGroup>,
                      from source: EditStack, onto target: EditStack) -> EditStack
}
```

### 7.2 `Models/EditClipboard.swift`

`@MainActor final class EditClipboard` singleton: `var stack: EditStack?` +
`var groups: Set<AdjustmentGroup>` (what the copy dialog selected). In-memory only —
adjustment clipboards don't survive relaunch anywhere (LR/C1 parity), and
`NSPasteboard` would invite cross-app expectations the format can't honor.

### 7.3 Surfaces

- Editor chrome: **Copy Adjustments** (⌥⌘C) — opens a small shell card
  (`AppState.editCopyRequest`) listing the seven groups as toggles, pre-checked to
  `adjustedGroups(draft)`; **Paste Adjustments** (⌥⌘V) — applies
  `EditClipboard` onto the draft (one history push).
- Menu bar: the same two commands in the Edit menu (`CommandGroup(after:
  .pasteboard)` beside the existing selection commands, MuseApp.swift:171), enabled
  when an editor session is open (copy) / clipboard non-empty (paste).
- **Batch sync**: grid context menu gains "Paste Adjustments" in
  `SelectionActionsMenu` (Views/SelectionMenu.swift — beside the Rating menu),
  visible when the clipboard holds a stack AND the effective selection contains
  image-kind editable files (the `fileURLs` guard pattern already there). Applies
  `EditTransfer.apply` onto each target's current stack via `EditStore.save`,
  off-main sequentially; each save runs the §3.5 sequence, so tiles refresh as the
  sweep progresses. 200 frames ≈ 200 small writes + thumbnail invalidations —
  seconds, no progress UI in v1 (recorded; the pill is for library-scale background
  work, per its durable rule).
- The geometry group IS offered in copy/paste (syncing a crop across a tripod
  sequence is real) — it is only presets that exclude it (§7.4).

### 7.4 User presets (DECIDED, required v1 — copy-by-value is non-negotiable)

- **Save**: Looks tab "Save Preset…" → name prompt → stores
  `draft` minus the geometry group (a preset is a look; a stored crop would
  ambush every photo it's applied to — deviation D8) in `edit_presets`.
- **Apply = `EditTransfer.apply(groups: preset's adjustedGroups, from: preset, onto:
  draft)`** — values are COPIED into the photo's stack; subsequent slider tweaks
  touch only the photo. There is no live link, by construction: the stack stores no
  preset id (only `aspectPresetID` for crop-UI restore, unrelated).
- **Preset mutation is a separate explicit action**: "Update Preset from This Photo"
  (overwrites the preset's stack from the current draft, confirm card) and "Save as
  New Preset…". Rename/Delete on row context menus (delete confirms via the
  `MuseAlert` seam).
- `Models/EditPresetStore.swift` (Pattern B): `@Published presets: [EditPresetRow]`,
  CRUD via `queue.write`, loaded lazily on first Looks-tab view.

---

## 8. Edit-a-Copy (external editors — DECIDED)

### 8.1 Where the fork lives

Both Open With surfaces route through one seam. `OpenWithItems.open(with:)`
(Views/OpenWithMenu.swift:85-88) — shared by the grid tile context menu and the hero
`ShareButton` menu (ShareButton.swift:27) — becomes:

```swift
private func open(with appURL: URL) {
    if EditStackIndex.stackHash(for: url) != nil {
        appState.openWithForkRequest = OpenWithForkRequest(fileURL: url, appURL: appURL)
    } else {
        NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}
```

(`OpenWithItems` gains the `@EnvironmentObject var appState` it needs.) The bare
"Open" rows (double-click default app, the explicit "Open" item) get the same guard —
any hand-off to an external app of a file with Muse edits forks.

### 8.2 The fork card

`AppState.openWithForkRequest: OpenWithForkRequest?` (`{ fileURL, appURL }`),
registered in `modalPresented`, presented at the shell via `.museModal` (durable
constraints: shell-presented, `ModalButton` footer, no `.alert`). Copy:
title `"This photo has Muse edits"`, body explains the fork, buttons
**Edit a Copy with Muse Adjustments** (`.prominent`) / **Edit Original** (`.normal`)
/ Cancel. "Edit Original" = the plain `NSWorkspace` open (external edits to the
original then flow through the normal edit-in-place reconcile — and the Muse stack
survives per §3.6's rule, applying on top of the new bytes).

### 8.3 Naming — `Editing/EditCopyNaming.swift` (pure, tested)

```swift
/// "<stem>-Edit.<ext>", then "-Edit-2", "-Edit-3", … against the existing
/// basenames in the folder (case-insensitive). Extension by source kind:
/// jpeg→jpg/png→png/tif→tif/heic→heic pass through; RAW/DNG → "tif"
/// (16-bit — external editors cannot write RAW; the LR convention).
static func candidate(stem: String, ext: String, existing: Set<String>) -> String
```

### 8.4 The flow (async, ordered, fail-closed)

1. Render: `EditRenderer.exportFile` full-res into a temp file — RAW → 16-bit TIFF,
   others → their own container (§5.3 formats but TIFF for RAW here, not JPEG: this
   copy is an EDITING master, not a share). **Metadata: the original's EXIF/IPTC is
   copied onto the export via `CGImageDestinationAddImageFromSource` property
   forwarding, minus orientation (baked into pixels now) and minus nothing else — this
   file belongs to the user, in their folder; stripping is a Drive-share rule, not a
   local one.**
2. Move the temp file to `EditCopyNaming` target beside the original (same folder —
   inside the security-scoped root by construction).
3. **Index it deterministically**: `Indexer.shared.indexFile(at: copyURL, kind:)`
   (Indexing/Indexer.swift:68) — not "wait for FSEvents", so step 4 has a file_id.
4. Stack with parent (when v17 exists): fetch both file_ids;
   `StackStore.createStack(kind: "manual", memberIDs: [parentID, copyID],
   pick: parentID)` — the copy collapses under its parent in plain browsing, the
   Spec 02 presentation rules doing the rest (nothing else to build; deleting either
   later needs no bookkeeping). Until v17 exists: skip, recorded (§0).
5. Reload the current folder (the standard `reloadCurrentFiles` path — the copy
   appears in place).
6. `NSWorkspace.shared.open([copyURL], withApplicationAt: appURL, …)`.

Failures at 1–2 surface via the `MuseAlert` seam ("Couldn't create the copy — …")
and nothing is written; 3–5 failing degrades to "the file is on disk; the next
reconcile finds it" (never data loss).

The copy is a fresh asset: **no inherited edit stack** (its pixels ARE the edits),
fresh analysis via the normal pipeline, own tags/rating. Round-trip closure: when the
external app saves the copy in place, that's an ordinary edit-in-place → re-hash →
re-analyze; membership in the manual stack is file_id-keyed and survives (or carries,
via §3.6, if the row splits).

---

## 9. What Spec 04 explicitly does NOT change

- `AnalyzePipeline` semantics: analysis reads ORIGINAL bytes, `analyzed_hash` keyed on
  original content (Spec 01 rule) — an edit triggers no re-analysis (colors/tags
  describe the capture; an "analyze the edit" mode is explicitly out).
- Search: no `edited:` token in v1 (grammar-only addition later; the `edits` table is
  trivially queryable).
- Smart rules: no `.edited` rule case in v1.
- The stacks system, duplicates, cull, rediscovery, places — untouched except the
  Edit-a-Copy `createStack` call.
- `.psd`, video, and every non-image kind: no editor.
- The hero close/open choreography: every guard, curve, and timing in
  `HeroStage`/`HeroImageViewer` — the editor mounts INSIDE the open viewer and
  touches none of it (and any regression there is diagnosed by instrumenting the
  running app, per the standing rule).

---

## 10. Performance

Additive `PerfBaseline` rows (record, never assert):

| Metric | Budget | How |
|---|---|---|
| Slider → canvas render (24 MP source, screen-res proxy, warm context) | 50 ms perceived / ~16 ms steady-state | coalescer timestamps |
| Edited thumbnail render (320 @2x, 24 MP source) | 120 ms | ThumbnailCache path, cache cleared |
| Full-res export, 60 MP TIFF source | < 20 s, no memory-pressure kill on M1 Air 8 GB | `exportFile`, export context |
| Editor enter (session seed + first canvas render, 24 MP) | 400 ms | mode-toggle → first draw |
| Stack decode + hash | < 1 ms | codec micro-bench |

M1 Air 8 GB discipline, restated as build rules: preview renders only from the
bounded proxy (≤ 4096, hero-ladder formula); export renders via lazy
`CIImage(contentsOf:)` + tiled context with the 1 GB limit; edited-thumbnail decodes
ride the existing `ThumbnailGate`/`DecodePermit` weighting (the render happens inside
the same `withSlot` body the plain decode used).

---

## 11. New durable constraints (added to `CLAUDE.md`)

1. **Edits are per `(file_id, parent_dir)` (`edits`/`edit_versions`) and MUST be
   carried through every identity/folder rewrite alongside tags and notes** — the
   Indexer split + both hash-collision branches, `FileMoveMigration`, and
   `FolderRenameMigration` (incl. the stale-target pre-clear) each call
   `EditRecordStore.carry`/`carryAll` beside the existing `NoteStore` call. A NEW
   rewrite path must carry `edits` too. A neutral stack is a DELETED row, never a
   stored no-op.
2. **Every surface that displays or ships a photo's pixels renders through the edit
   seam** (`EditStackIndex` → `EditRenderer`): grid thumbnails, hero decode ladder,
   compare panes, `OutputRender` (PDF/Drive/share sheet). Backup is the one
   deliberate exclusion. A new pixel surface must consult the seam; layout reads
   `EffectiveDimensions` (crop-aware), analysis and decode budgets keep reading
   `ImageHeaderSizeCache` (original bytes).
3. **The renderer never mutates a stack**: `processVersion` is stamped at creation
   and never bumped by decode or render; a stack the renderer can't honor (newer
   schema/process, corrupt JSON) renders as the ORIGINAL image and the stored blob is
   left byte-identical — only an explicit user edit or Reset rewrites it.
4. **Scene-referred rule**: adjustments run on un-clamped linear working-space data
   (`LinearImage`; the `EncodedImage`→`LinearImage` crossing happens exactly once);
   highlight recovery must actually recover (pinned by test); every scale-dependent
   parameter is a fraction of the source long edge, and
   `EditRenderConsistencyTests` (thumbnail/screen/export agreement) is the gate for
   any renderer change. RAW white balance happens ONLY at demosaic
   (`CIRAWFilter.neutralTemperature/Tint`) — never `CITemperatureAndTint` on a RAW
   source's output.
5. **Preset application is copy-by-value** — applying writes values into the photo's
   stack; no stack stores a preset reference; preset mutation happens only via the
   explicit Update/Save-as-New actions. (This is what makes
   "tweak one image without touching the preset" automatic — foundation's
   non-negotiable.)
6. **Handing a file with Muse edits to an external app always presents the
   Edit Original / Edit a Copy fork** — every Open With/Open path routes through the
   one `OpenWithItems` seam. The copy is rendered full-res, indexed via
   `Indexer.indexFile` (never left to FSEvents), then stacked manual with its parent.
7. **The sidecar's edit field is owner-gated**: only the edit-save export passes
   `editAuthoritative: true` through `Sidecar.resolveForWrite`; every other export
   preserves the on-disk value, and `Sidecar.merge` resolves edits by the
   `edit_updated_at` field clock with union-never-deletes semantics.
8. **Editor chrome reads the `Theme` environment** (`Views/Theme/Theme.swift`) — new
   editor-adjacent surfaces take tokens from it, never raw hex; the theme resolves
   from `moodPalette` + system semantics.
9. **Escape in Edit mode is consumed inside the hero's `viewerClosing` onChange
   handler** (the region-mode pattern) — it exits to Preview and returns before
   `startClose()`; the hero close sequence and `EscapeResolver` are untouched.

---

## 12. Tests

All pure-logic (house convention; no UI unit tests). New files:

| File | Covers |
|---|---|
| `EditStackCodecTests` | canonical-bytes stability (sorted keys), pinned fixture hash, decode of every group, unknown adjustment `type` → nil, `schemaVersion+1` → nil, `processVersion+1` decodes but `canRender` false, **decoding never bumps versions** (v1 blob re-encodes v1), `Mask` slot round-trips `[]` |
| `EditStackNormalizeTests` | canonical order enforced, duplicate case → last wins, `isNeutral` across groups, `clamped()` bounds |
| `EditHistoryTests` | the Surface suite ported: push dedupe, truncate-forward on push after undo, canUndo/canRedo edges, capacity drop-oldest |
| `CurveLUTTests` | monotone-cubic: identity for empty, endpoint exactness, monotone output for monotone input, 1024-entry LUT round-trip tolerance, maxPoints clamp |
| `GeometryParamsTests` | `appliedDisplaySize` for quarterTurns 0–3 × flips × crop, straighten inscribe math, unit-crop bounds validation |
| `EditTransferTests` | `adjustedGroups` per group, copy-by-value isolation (mutating target never touches source), group-absent-clears rule, preset-apply-then-tweak never mutates the preset stack |
| `EditRecordStoreTests` | write/read/delete (neutral deletes), `applyHydrated` LWW (strictly-newer local wins), `carry` INSERT-OR-IGNORE + copy-vs-move, `carryAll`, versions CRUD, cascade on file delete |
| `EditMigrationTests` | v20+v21 run clean on a v12-shaped library (and on a v19-shaped one when Specs 02/03 built first); idempotent re-migrate; existing rows untouched |
| `EditCarrySeamTests` | extends the Indexer/FileMove/FolderRename suites: an `edits`+`edit_versions` row follows each of the five §3.6 sites exactly as the notes row does (split copy-vs-move, collision both branches, move, rename incl. stale-target pre-clear) |
| `EditSidecarTests` | `Sidecar` decode with/without edit fields, merge clock rule (newer wins, nil never clobbers), `resolveForWrite` editAuthoritative matrix (§2.4 table), build round-trip |
| `EditRenderConsistencyTests` | the REQUIRED test: one all-groups fixture stack × 2 fixture images × 3 resolutions → downsampled agreement within tolerance |
| `EditRenderNeutralityTests` | all-neutral stack renders byte-tolerant-identical to the plain decode (per group and whole-stack) |
| `HighlightRecoveryTests` | synthetic linear fixture with >1.0 highlight data: negative exposure + highlights recovery brings detail back (variance in the recovered region > clipped baseline) — the scene-referred pin |
| `MiredMappingTests` | temperature slider symmetry in mired space (Surface's warm/cool asymmetry bug pinned against recurrence), clamp floor |
| `EditKernelLoadTests` | every `[[stitchable]]` kernel loads by name from the metallib (build-phase smoke) |
| `EditCopyNamingTests` | collision ladder, extension mapping incl. RAW→tif, case-insensitive existing set |
| `CanvasPointMathTests` | canvas→image unit-point mapping under fit/zoom/pan; out-of-image → nil |
| `EditingModuleImportTests` | no `import AppKit` anywhere under `Editing/` (the platform-neutral rule as a test) |

Existing suites that must stay green and are touched: Spec 01's
`ThumbnailStackKeyTests` / `EditStackIndexTests` / `EffectiveDimensionsTests` /
`OutputRenderTests` (extended: `forOutput` is no longer identity for edited files —
the rendered-temp path + format table get cases), `IndexerReconcileTests`,
`FileMoveMigrationTests`, `FolderRenameMigrationTests` (each gains the edits-carry
cases via `EditCarrySeamTests`), `ThumbnailVariantTests` (the editor adds **no** new
thumbnail variant — edited renders use the enumerated sizes), `EscapeActionTests`
(unchanged resolver, re-run), `SidecarTests`/`SidecarHydratorTests`.

---

## 13. Build order

0. **Spec 01 §3 seams if absent** (`EditStackIndex`, stack-keyed `ThumbnailCache`
   key + dual invalidate, `EffectiveDimensions` + consumer conversions,
   `OutputRender` choke point + call-site conversions, their tests) — built to Spec
   01's text verbatim, committed separately.
1. **Model + codec + history + transfer** (§1, §7.1) — pure, fully tested, no app
   dependency.
2. **v20 + `EditRecordStore` + the five carry seams + sidecar fields/hydration**
   (§2.1, §2.3, §3.1, §3.6) — the data layer is complete and safe before any pixel
   renders.
3. **Renderer core** (§4): WorkingImage port → CurveLUT → kernels → chain →
   RawSource → consistency/neutrality/recovery goldens.
4. **`EditStore` + provider + consumer sweep** (§3.2–3.5, §5): thumbnails, hero,
   effective dimensions, `OutputRender` live, grid badge. From this commit an edit
   made in a test harness shows everywhere.
5. **Theme layer + editor shell** (§6.1–6.5): mode toggle, backdrop, panels, canvas,
   coalescer, sliders, autosave, Escape/keys.
6. **Curve editor + WB eyedropper** (§6.6–6.7).
7. **Before/after + snapshots + versions** (§6.8–6.9).
8. **v21 + presets + copy/paste/sync** (§7).
9. **Edit-a-Copy** (§8).
10. Docs (`CLAUDE.md` constraints §11 + phase-table row + the "No editing UI"
    convention rewrite lands HERE with the shipped feature, per Spec 01 §1.1's
    doctrine table; `architecture-map.md`; `session-log.md`; DECISIONS.md refresh) +
    localization export pass (`xcodebuild -exportLocalizations … fr` → 0
    untranslated).

1–3 are shippable invisibly (no UI change); 4 is the first user-visible commit and
the point where the render-consistency gate must already be green.

---

## 14. Owner-only steps

1. **Tune the slider-feel constants on real photos** — toneBands band gains, contrast
   ×0.75, clarity/texture/sharpen radius fractions, vignette scaling. All are named
   constants with one declaration site; Surface's history (three "baby steps"
   escalation rounds, documented in `RecipeRenderSettings.swift`) says first guesses
   WILL move — budget an iteration session with before/after screenshots.
2. **RAW acceptance on real files**: blown-highlight recovery on a test DNG
   (the pre-spec acceptance), decoder v9 opt-in behavior on a macOS 26/27 machine,
   graceful degrade on 14.6, a Fuji X-Trans file through the pinned-decoder path.
3. **60 MP export + editing session on the M1 Air 8 GB** — commit the PerfBaseline
   report with the §10 rows.
4. **Edit-a-Copy round-trip through Affinity/Pixelmator/Preview** (acceptance): copy
   opens, external save flows back, stack/grid behavior verified live (the
   verify-runtime rule — green tests don't cover NSWorkspace hand-offs).
5. Editor look sign-off: backdrop default (mid gray 0.48), panel styling, slider
   metrics — visual calls only the owner makes.
6. French translations for the new keys (export pass emits them).

---

## 15. Deliberate deviations from the source specs

Recorded so they read as decisions, not drift:

1. **Adjustments are typed group structs in an enum-tagged array, at most one per
   case, canonical order enforced by `normalized()` and the renderer's own chain** —
   the pre-spec's `[Adjustment]` shape delivered with reorderability made
   unrepresentable rather than merely forbidden. §1.1.
2. **Virtual copies are switchable stacks (one CURRENT stack renders everywhere),
   not parallel grid tiles** — path-keyed identity (selection, tileFrames,
   collections, search) cannot represent one path twice; digiKam's affordance ships
   as the badge + version switcher. §1.4.
3. **Undo history is session-only; persistence is the stack + snapshots/versions** —
   the foundation's "persistent" requirement binds versions (which persist);
   RawTherapee's sin is losing state on close, and Muse's current state is always
   persisted. §1.3.
4. **No Extended Virtual Addressing entitlement** — it is iOS-only and does not
   exist on macOS; the export-memory answer is lazy CIImage sources + the export
   context's 1 GB `memoryLimit` + CI tiling. §4.7.
5. **Gain-map export round-trip is best-effort**: macOS 15+ writes HDR HEIF with
   gain map for edited pixels; 14.6 exports tone-mapped SDR (recorded limitation);
   unedited files always ship original bytes. §4.8.
6. **An external edit-in-place keeps the Muse stack** — parameters are normalized so
   they still apply; the stack is user data and Reset is one click. Silently
   discarding edits because another app touched the bytes is the worse failure. §3.6.
7. **`markContentChanged` is the tile-refresh seam for edit saves** — its semantic is
   "what this path displays changed", and it already does exactly the required pair
   (invalidate both thumbnail variants + bump the tile task token); a parallel
   edits-only channel would duplicate it. §3.5.
8. **Presets exclude the geometry group** (a stored crop ambushes every applied
   photo); copy/paste DOES offer geometry (syncing a crop across a tripod set is a
   real workflow). §7.4.
9. **`.psd` is excluded from Path A** — foundation §6's editable-format list is
   JPEG/HEIC/PNG/TIFF/RAW/DNG; a PSD's flat composite is a preview, and editing it
   belongs to Path B. §4.5.
10. **The Theme layer ships minimally, scoped to new (editor) surfaces** — the
    DECISIONS gate is satisfied without a 200-file migration; existing surfaces
    migrate opportunistically later. §6.1.
11. **Sidecars carry only the current stack** — versions/snapshots are device-local;
    the portable promise is the photo as it looks. §2.3.
12. **Arrow-key file flips are disabled in Edit mode** — a flip tears down the edit
    session; accidental navigation mid-edit reads as loss. Preview keeps flips.
    §6.10.
13. **Autosave, no Done/Cancel** — edits are non-destructive with full undo +
    Reset; a modal commit model would break "the grid is the product" (the tile
    updates live). §6.3.
14. **Edit-a-Copy renders RAW to 16-bit TIFF** (an editing master; external editors
    can't write RAW — the LR convention), while share paths render RAW to JPEG.
    §8.4 / §5.3.
15. **Curve evaluates in the display-referred domain** — users read curves against
    what they see; scene-referred tone ops stay linear, the curve is the deliberate
    exception, implemented via `CIColorCurves`' explicit color-space parameter.
    §4.4.

---

## 16. Acceptance mapping (from `pre-spec-04-editing-engine.md`)

| Acceptance item | Where satisfied |
|---|---|
| Non-destructive: original bytes untouched; revert always available; edits survive moves and restarts; sidecars carry stacks | no write path to originals exists; Reset deletes the row (§2.1); §3.6 carry seams + content-hash identity; §2.3 sidecars |
| Thumbnail/screen/export consistency at 3 resolutions | `EditRenderConsistencyTests` (§4.6, §12) — a build gate, not a hope |
| RAW blown-highlight recovery on a test DNG; v9 opt-in on new macOS, graceful on 14.6 | §4.5 neutralized scene-referred base + `HighlightRecoveryTests`; decoder pinning + `supportedDecoderVersions` gate; owner step §14.2 |
| Slider-to-render < 50 ms perceived at screen res on the reference machine | §4.7 coalescer + proxy renders; measured §10 |
| 60 MP export completes without memory-pressure kill | §4.7 export context (tiling + 1 GB limit); measured §10/§14.3 |
| Copy/paste/sync across 200 frames with partial selection; preset apply-then-tweak never mutates the preset | §7.3 batch sync; §7.4 copy-by-value + `EditTransferTests` |
| Edit-a-Copy round-trips through Affinity/Preview; copy appears stacked with its parent | §8.4 flow (render → index → `createStack` → open); owner step §14.4 |
