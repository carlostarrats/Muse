# Spec 02 — Photo Library Core: full implementation spec

*Derived from `spec-02-photo-library-core.md` + `muse-photo-foundation.md` (§13 decision log
is authoritative). Build-level expansion: exact files, exact schema, exact seams, exact
tests. Written before implementation; kept as the record of what was built and what was
deliberately decided along the way. Verified against the codebase at `cc623a7`
(`feat/editing`, working tree clean).*

---

## 0. What this spec does, does not, and depends on

**Does:** EXIF extraction into an indexed `photo_meta` table; offline reverse geocoding
(bundled GeoNames → `places` table) with a Places page; rediscovery
(`files.last_viewed_at`, Rarely Seen / On This Day / Shuffle); near-duplicate burst
stacks (auto + manual, presentation-layer only); token search over indexed metadata with
a chip bar and autocomplete; a `.location` smart-rule case; Google Maps link-out; a new
LIBRARY sidebar section. Plus one **bug fix this spec depends on**: the duplicate
finder's "visually similar" mode is dead code today (§6.1) and its repair is the
foundation for stack similarity.

**Does not:** CLIP/MobileCLIP, region similarity, auto-growing albums, natural-language
parsing, compare/culling, faces (all Spec 03). Any editing (Spec 04). Sharing changes.

**Depends on Spec 01 §2 (coordinates), which is NOT yet built.** Commit `cc623a7` added
docs only: there is no `v13_coordinates` migration, no `CoordinateReader`, no
`CoordinateBackfill` in the tree (verified — `Database.makeMigrator()` ends at
`v12_smart_collections`). This spec **absorbs and amends** Spec 01 §2 (§2 below, recorded
as deviation D1): one header reader and one backfill serve both coordinates and EXIF, so
each file's header is opened once, not twice. The v13 schema from Spec 01 is kept
verbatim. If Spec 01's other parts (seams, commerce) are built first, nothing here
changes; if this spec is built first, it carries v13 with it.

**Migration numbering:** v13 = coordinates (Spec 01, carried here) · v14 = `photo_meta` ·
v15 = `places` · v16 = `last_viewed_at` · v17 = stacks. Separate migrations so the four
features can land in separate commits/branches without renumbering.

---

## 1. Schema

All migrations follow the house convention: registered at the end of
`Database.makeMigrator()` (`Database/Database.swift:63`), GRDB DSL, matching record
structs in `Database/Records.swift` (snake_case fields, `MutablePersistableRecord`,
inserted as `var`). `foreignKeysEnabled = true` is already on; every new child table
cascades on file delete so `Housekeeping.pruneUnreachable` keeps working unchanged.

### 1.1 `v13_coordinates` (Spec 01 §2.1, verbatim)

```sql
ALTER TABLE files ADD COLUMN lat REAL;                 -- signed decimal degrees, WGS-84
ALTER TABLE files ADD COLUMN lon REAL;
ALTER TABLE files ADD COLUMN coords_scanned_hash TEXT; -- content_hash we last read GPS from
CREATE INDEX files_coords_idx ON files(lat, lon) WHERE lat IS NOT NULL;
```

`FileRow` gains `lat: Double?`, `lon: Double?`, `coords_scanned_hash: String?`.
Content-keyed on purpose (GPS lives in the bytes; same grain as `palette`/`caption`) —
Spec 01 §2.1's rationale carries over unchanged.

### 1.2 `v14_photo_meta`

```swift
migrator.registerMigration("v14_photo_meta") { db in
    try db.create(table: "photo_meta") { t in
        t.column("file_id", .text).primaryKey()
            .references("files", onDelete: .cascade)
        t.column("exif_scanned_hash", .text)   // content_hash we last read EXIF from
        t.column("capture_date", .integer)     // unix seconds (DateTimeOriginal, local-time)
        t.column("capture_md", .text)          // "MM-DD" — on-this-day key, precomputed
        t.column("camera_make", .text)
        t.column("camera_model", .text)
        t.column("lens", .text)
        t.column("iso", .integer)
        t.column("f_number", .double)
        t.column("exposure_seconds", .double)
        t.column("focal_length", .double)      // mm
        t.column("focal_length_35mm", .integer)
        t.column("flash_fired", .boolean)      // EXIF Flash bit 0; nil = unknown
    }
    try db.create(index: "photo_meta_capture_idx", on: "photo_meta", columns: ["capture_date"])
    try db.create(index: "photo_meta_md_idx", on: "photo_meta", columns: ["capture_md"])
    try db.create(index: "photo_meta_camera_idx", on: "photo_meta", columns: ["camera_make", "camera_model"])
    try db.create(index: "photo_meta_lens_idx", on: "photo_meta", columns: ["lens"])
    try db.create(index: "photo_meta_iso_idx", on: "photo_meta", columns: ["iso"])
    try db.create(index: "photo_meta_f_idx", on: "photo_meta", columns: ["f_number"])
    try db.create(index: "photo_meta_focal_idx", on: "photo_meta", columns: ["focal_length"])
}
```

**Why a separate table, not columns on `files` (deviation D2):** nine nullable columns +
their indexes would bloat every existing `FileRow` fetch (the grid, the indexer, the
sorters all `SELECT *`), and `files` has already grown three times. The grain is
identical to `files` (content-keyed — EXIF lives in the bytes; two byte-identical copies
share one row by definition; edit-in-place splits the row and the `exif_scanned_hash`
marker triggers a re-read). `PRIMARY KEY = file_id` + cascade keeps identity handling
free. **This is deliberately NOT the tags/notes per-location grain** — same reasoning as
`palette` and Spec 01's coordinates.

**Why `capture_md` is materialized:** On This Day needs "same month-day, any year".
`strftime('%m-%d', capture_date, 'unixepoch')` in a WHERE clause is a full scan and can't
use an index; a precomputed 5-char TEXT column indexed at write time makes the query
`WHERE capture_md = ?` — the "query time touches only precomputed data" rule (§13 #15)
applied at the schema level.

Record:

```swift
struct PhotoMetaRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "photo_meta"
    var file_id: String
    var exif_scanned_hash: String?
    var capture_date: Int64?
    var capture_md: String?
    var camera_make: String?
    var camera_model: String?
    var lens: String?
    var iso: Int?
    var f_number: Double?
    var exposure_seconds: Double?
    var focal_length: Double?
    var focal_length_35mm: Int?
    var flash_fired: Bool?
}
```

### 1.3 `v15_places`

```swift
migrator.registerMigration("v15_places") { db in
    try db.create(table: "places") { t in
        t.column("file_id", .text).primaryKey()
            .references("files", onDelete: .cascade)
        t.column("geocoded_hash", .text).notNull()   // content_hash whose lat/lon we geocoded
        t.column("dataset_version", .integer).notNull() // GeoNamesDataset.version at geocode time
        t.column("city", .text)      // display name (UTF-8 GeoNames 'name'), e.g. "Lisboa"
        t.column("admin", .text)     // admin1 display name, e.g. "Lisbon"
        t.column("country", .text)   // ISO 3166-1 alpha-2, e.g. "PT" — display name resolved at render time
        t.column("place_key", .text) // grouping key: lowercased "city|admin|country"; NULL = geocoded, no place
    }
    try db.create(index: "places_key_idx", on: "places", columns: ["place_key"])
}
```

- **A row with NULL `city/admin/country/place_key` means "geocoded, nothing within
  range"** — the row itself is the attempted-marker (same bug-shape defense as
  `coords_scanned_hash` / `analyzed_hash`: without it, every unplaceable photo re-geocodes
  forever).
- `country` stores the **ISO code**, not a display name — country names localize for free
  at render time via `Locale.current.localizedString(forRegionCode:)`, which keeps French
  correct without touching the DB (display-time-localization rule).
- Re-geocode selection: `lat IS NOT NULL AND (no places row OR geocoded_hash !=
  content_hash OR dataset_version != current)` — a dataset upgrade re-geocodes the
  library (pure CPU over DB rows, no file I/O; 20k lookups well under a second).

Record: `PlaceRow` with the seven fields, same shape as `PhotoMetaRow`.

### 1.4 `v16_rediscovery`

```sql
ALTER TABLE files ADD COLUMN last_viewed_at INTEGER;   -- unix seconds, local-only
```

`FileRow` gains `last_viewed_at: Int64?`. Content-keyed (deviation D3): viewing the copy
in `/A` marks the byte-identical copy in `/B` seen too — that is the correct rediscovery
semantic ("have I looked at this picture"), and it avoids inventing a fourth per-location
table for a single timestamp. **`last_viewed_at` is deliberately NOT carried in sidecars**
— it is device-local behavioral data, not portable metadata; syncing "seen" state across
devices is neither wanted nor private-by-default. (`Sidecar` is untouched by this spec;
`photo_meta`/`places` are also NOT in sidecars — both are derived from bytes/coordinates
and recompute locally for free, exactly like the existing rule for OCR text.)

No index: rediscovery queries scan `files` joined to alive paths at most once per surface
activation (≤ tens of ms at 50k), never per keystroke.

### 1.5 `v17_stacks`

```swift
migrator.registerMigration("v17_stacks") { db in
    try db.create(table: "stacks") { t in
        t.column("id", .text).primaryKey()             // UUID string
        t.column("kind", .text).notNull()              // "auto" | "manual"
        t.column("dissolved", .boolean).notNull().defaults(to: false)
        t.column("pick_file_id", .text)                // representative; NULL = first in sort order
        t.column("created_at", .integer).notNull()
    }
    try db.create(table: "stack_members") { t in
        t.column("stack_id", .text).notNull()
            .references("stacks", onDelete: .cascade)
        t.column("file_id", .text).notNull()
            .references("files", onDelete: .cascade)
        t.primaryKey(["stack_id", "file_id"])
    }
    try db.create(index: "stack_members_file_idx", on: "stack_members", columns: ["file_id"])
}
```

- **Stacks are sets of `file_id`s — no `parent_dir`, no path** (deviation D4). A stack is
  presentation-layer grouping of *assets* (binding decision #13: grouping, not taxonomy);
  membership never touches `paths`, `tags`, or `collection_members`, so identity, tag
  scoping, and collections are structurally unaffected. Where its members *render* is
  decided at display time (§6.5).
- **`dissolved` is a tombstone, not a delete** (same pattern as collection
  `setHidden`): unstacking an auto stack keeps the row + members so the auto-stacker
  never re-forms it. The auto-stacker's hard rule: **a file that appears in ANY
  `stack_members` row (dissolved or not) is off-limits** — auto-stacking only ever
  touches virgin files, so it can never fight a user's manual arrangement.

Records: `StackRow` (`id`, `kind`, `dissolved: Bool`, `pick_file_id: String?`,
`created_at: Int64`), `StackMemberRow` (`stack_id`, `file_id`).

---

## 2. EXIF + coordinates: one header pass

### 2.1 `Filesystem/PhotoHeaderReader.swift` (amends Spec 01 §2.2 — deviation D1)

One nonisolated enum reading **everything Muse wants from a file header in a single
`CGImageSourceCopyPropertiesAtIndex` call** — coordinates (Spec 01's job) and EXIF (this
spec's job). Two readers would parse every header twice for no reason; Spec 01 isn't
built, so the merge costs nothing.

```swift
nonisolated struct ExifFields: Equatable, Sendable {
    var captureDate: Int64?       // epoch seconds; nil when absent/unparseable
    var captureMD: String?        // "MM-DD", derived from the same parse
    var cameraMake: String?
    var cameraModel: String?
    var lens: String?
    var iso: Int?
    var fNumber: Double?
    var exposureSeconds: Double?
    var focalLength: Double?
    var focalLength35mm: Int?
    var flashFired: Bool?
}

nonisolated struct PhotoHeader: Sendable {
    var coordinate: Coordinate?   // FileMetadata.Coordinate — the existing type
    var exif: ExifFields?         // nil for kinds that carry none
}

nonisolated enum PhotoHeaderReader {
    /// Header-only read; no decode; dataless iCloud → empty header, never a download.
    static func read(url: URL, kind: AssetKind) async -> PhotoHeader

    /// Pure mapping, unit-tested without fixtures on disk.
    static func exifFields(exif: [String: Any], tiff: [String: Any]) -> ExifFields
    static func sanitize(_ c: Coordinate?) -> Coordinate?   // Spec 01's validator, verbatim
    static func parseExifDate(_ s: String?) -> (epoch: Int64, md: String)?
}
```

- `.image/.raw/.psd` → `CGImageSourceCreateWithURL` + `CopyPropertiesAtIndex(src, 0, nil)`
  once; the GPS sub-dictionary feeds the existing pure
  `FileMetadata.coordinate(latitude:latRef:longitude:longRef:)`; the EXIF/TIFF
  sub-dictionaries feed `exifFields(exif:tiff:)`. Key handling mirrors
  `FileMetadata.imageMetadata` exactly (`Viewers/FileMetadata.swift:50-78`) — same
  prefix-stripped bare keys, same `ISOSpeedRatings` `[Int]`-or-`Int` tolerance — **the
  two must not diverge**: a viewer showing one camera while search indexes another is
  worse than no index. (`FileMetadata` itself is untouched; a follow-up may re-point it
  at this reader, not required here.)
- `.video` → `AVURLAsset.noNetwork(url:)` (durable constraint — never a bare
  `AVURLAsset`) → `asset.load(.metadata)`: `.commonKeyLocation` → `parseISO6709` for the
  coordinate; `.commonKeyCreationDate` → `captureDate`/`captureMD` (note: the existing
  `FileMetadata.loadVideo` reads `.metadata`, not `.commonMetadata` — follow the code,
  not Spec 01's wording). All other `ExifFields` stay nil for video.
- Everything else → empty `PhotoHeader`.
- Dataless-iCloud guard first statement, identical to `FileMetadata.load`
  (`.ubiquitousItemDownloadingStatusKey == .notDownloaded` → empty, never forcing a
  download).
- `sanitize`: rejects non-finite and out-of-range (`|lat| > 90`, `|lon| > 180`) — Spec 01
  §2.2 unchanged.
- `parseExifDate`: `"yyyy:MM:dd HH:mm:ss"`, `en_US_POSIX`, **interpreted in the current
  local time zone** (EXIF carries no zone; local-time is the Photos-app convention and
  the least-wrong default; recorded limitation, not a bug). `captureMD` comes from the
  same `DateComponents` so the two can never disagree.
- Flash: EXIF `Flash` is a bitfield; `flashFired = (value & 1) == 1`; absent → nil.

### 2.2 Write points

1. **`AnalyzePipeline.analyzeOne`** (`Intelligence/AnalyzePipeline.swift:408`): read the
   header once at the top, **before the image-kind guard at line 410** (which returns
   early for `.video`):
   - For `.video`: one small write transaction that re-reads the row, guards
     `file.content_hash` unchanged since the read, then upserts
     `photo_meta` (capture fields only) + `files.lat/lon` + both `*_scanned_hash`
     markers. Then return (Vision still doesn't run on video). A geotagged or dated
     video must not be invisible to `near:`/`in:`/On This Day just because Vision
     doesn't tag videos.
   - For image kinds: carry the `PhotoHeader` into the **existing guarded write
     transaction** (the one gated on `file.content_hash == analyzedHash`) and add:
     `file.lat/lon/coords_scanned_hash` assignments + a `PhotoMetaRow` upsert with
     `exif_scanned_hash = analyzedHash`. No new transaction; ~10 more column writes.
   - The header read runs concurrently with Vision (`async let`), so the pass gets no
     slower.
2. **`Intelligence/PhotoHeaderBackfill.swift`** — replaces Spec 01's
   `CoordinateBackfill` (deviation D1). Launch pass modelled on `IntentBackfill`
   (fire-and-forget `Task` from `MuseApp.swift`'s `.task`, beside the
   `IntentBackfill.run()` call at line 131, with `PhaseTrace` marks):

   ```swift
   nonisolated enum PhotoHeaderBackfill {
       static let maxPerLaunch = 5_000
       static let concurrency = 4
       static let writeChunk = 200
       static func run() async
   }
   ```

   Selection: alive-pathed files where
   `coords_scanned_hash IS NULL OR coords_scanned_hash != content_hash OR` the
   `photo_meta` marker is missing/stale:

   ```sql
   SELECT f.id, f.content_hash, f.kind, p.absolute_path
   FROM files f JOIN paths p ON p.file_id = f.id AND p.is_alive = 1
   LEFT JOIN photo_meta m ON m.file_id = f.id
   WHERE f.kind IN ('image','raw','psd','video')
     AND (f.coords_scanned_hash IS NULL OR f.coords_scanned_hash != f.content_hash
          OR m.exif_scanned_hash IS NULL OR m.exif_scanned_hash != f.content_hash)
   LIMIT 5000
   ```

   One URL per file_id (first alive path). Bounded concurrency 4 via a task group;
   dataless files come back empty and are **skipped without stamping** (they'll be
   picked up once local — same rule as the indexer). Writes batched one transaction per
   200 files, each row's write guarded on `content_hash` still matching. The
   5,000/launch cap spreads a 100k cold library over a few launches instead of
   hammering the disk once (Spec 01's numbers, kept). On completion: if anything was
   written, `SearchFacets.shared.refresh()` (§7.6) and `GeocodeBackfill.run()` (§3.4)
   chain behind it.

Throttling: the pass runs at `.utility` priority; that plus the launch cap is the
"background, throttled" posture (#22). Battery/thermal-aware pausing is Spec 06's
import-scale work; not built here.

---

## 3. Offline reverse geocoding

### 3.1 Dataset (DECIDED #17: offline; deviation D5: cities1000)

**GeoNames `cities1000` (CC-BY 4.0), not `cities15000`.** ~140k rows vs ~26k; the
difference is villages and small towns — exactly where travel photos are taken. A
15000-population floor sends a Tuscan hill town's photos to Florence. Cost: ~2.5 MB
compressed in the bundle (vs ~0.6 MB) — acceptable against the "few MB" budget in
foundation §4.

Two bundled resources, produced by a **checked-in script** (`scripts/make-geonames.sh`,
run manually when refreshing the dataset; its output artifacts are committed):

| Resource | Content | Format |
|---|---|---|
| `Muse/Muse/Resources/geonames-cities.tsv.zlib` | per row: `name \t lat \t lon \t admin1code \t countrycode` (5 of GeoNames' 19 columns) | raw-DEFLATE (`COMPRESSION_ZLIB`), same codec the app already uses in `DriveShareManifest.swift:71-82` |
| `Muse/Muse/Resources/geonames-admin1.tsv` | `code \t name` from `admin1CodesASCII.txt` (~6k rows, ~100 KB) | plain TSV |

**Bounded decompress (durable-constraint class):** the expected inflated byte count is
embedded as the first 4 bytes of the `.zlib` file; `GeoNamesDataset.load` allocates
exactly that and treats a short/overflowing decode as corrupt (→ dataset unavailable, no
crash, no unbounded allocation). Same rule as the share page's `MAX_INFLATED` cap — a
bundled file is not attacker-controlled, but the guard costs three lines and makes the
loader reusable.

Attribution (CC-BY requirement): one line in the existing About card
(`Views/InfoSheet.swift`): `Text("Place names © GeoNames (geonames.org), CC BY 4.0")` —
SwiftUI literal position, auto-extracted for localization. Also added to `README.md`
credits.

### 3.2 `Intelligence/Geo/GeoNamesDataset.swift`

```swift
nonisolated struct GeoCity: Sendable {
    let name: String        // UTF-8 display name
    let lat: Double
    let lon: Double
    let admin1Code: String  // "PT.14"
    let countryCode: String // "PT"
}

nonisolated final class GeoNamesDataset: Sendable {
    static let version = 1                      // bump when regenerating the artifacts
    static let shared = GeoNamesDataset()       // lazy; loads nothing until first use
    func cities() -> [GeoCity]?                 // nil = resource missing/corrupt (fail closed)
    func admin1Name(for code: String) -> String?
}
```

Loaded once, off-main, on first geocode; ~140k × ~48 bytes ≈ 7 MB resident **only while a
geocode pass is running** — the dataset and tree are released when the pass ends (a
`GeocodeBackfill`-scoped strong reference, `weak` in the singleton), so browsing carries
zero standing cost. This is bounded by the dataset, not the library — it does not
violate the no-RAM-residency rule (#25), which is about library-proportional data.

### 3.3 `Intelligence/Geo/GeoKDTree.swift`

Pure, unit-tested. 3-D k-d tree over unit-sphere coordinates — Euclidean distance on the
unit sphere is monotone in great-circle distance, so nearest-neighbor is exact without
trig in the hot path, and the antimeridian/pole edge cases disappear (a lat/lon 2-D tree
gets both wrong).

```swift
nonisolated struct GeoKDTree {
    init(points: [(lat: Double, lon: Double)])          // O(n log n) build, ~100 ms at 140k
    /// Index of the nearest input point + great-circle distance in km.
    func nearest(lat: Double, lon: Double) -> (index: Int, distanceKM: Double)?
}

// Same file — shared pure helpers, also used by the .near smart rule (§8.2):
nonisolated enum GreatCircle {
    static func distanceKM(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double
}
nonisolated enum GeoBounds {
    /// Bounding box(es) for a radius query; splits in two when crossing ±180°.
    static func boxes(lat: Double, lon: Double, radiusKM: Double)
        -> [(latRange: ClosedRange<Double>, lonRange: ClosedRange<Double>)]
}
```

### 3.4 `Intelligence/Geo/GeocodeBackfill.swift` + `ReverseGeocoder`

```swift
nonisolated enum ReverseGeocoder {
    static let maxDistanceKM: Double = 150
    /// nil = no city within range ("geocoded, no place").
    static func place(lat: Double, lon: Double, tree: GeoKDTree, cities: [GeoCity],
                      dataset: GeoNamesDataset) -> Place?
    struct Place: Equatable { var city: String; var admin: String?; var country: String
                              var key: String }   // key = lowercased "city|admin|country"
}

nonisolated enum GeocodeBackfill {
    static func run() async    // fire-and-forget from MuseApp .task, after PhotoHeaderBackfill
}
```

- Selection (§1.3): coordinates present, `places` row missing or stale by hash or
  dataset version. Pure DB + in-memory tree — **no file I/O, no network, ever** (#17).
- Beyond 150 km → write the row with NULL place fields (attempted-marker). Within →
  city/admin/country + `place_key`.
- Writes chunked 200/transaction; whole pass for 20k geotagged photos is ~1–2 s of
  `.utility` CPU on the reference machine.
- On completion with any writes: `PlacesStore.shared.reload()` + `SearchFacets.shared.refresh()`.

Apple's `CLGeocoder` is **not** used anywhere (throttled ~50 req/min — foundation §4's
non-starter math; and it's a network call, forbidden by the doctrine).

---

## 4. Places surface

### 4.1 `Models/PlacesStore.swift` — own store, AppState frozen (#26)

```swift
@MainActor final class PlacesStore: ObservableObject {
    static let shared = PlacesStore()
    @Published private(set) var showingPlaces = false
    @Published private(set) var groups: [PlaceGroup] = []
    @Published var sortByCount = true          // false = by recency; persisted via AppSettings key
    func reload() async                        // re-query groups (root-filtered)
    func setShowing(_ v: Bool)
}

nonisolated struct PlaceGroup: Identifiable, Equatable, Sendable {
    var key: String            // places.place_key
    var city: String
    var admin: String?
    var countryCode: String
    var count: Int
    var latestAt: Int64        // max(capture_date ?? modified_at) in the group
    var coverPath: String?     // alive path of the most recent member
    var id: String { key }
    var displayName: String    // "Lisboa, Portugal" — country via Locale display name
}
```

Group query (`Database/PlaceQueries.swift`, nonisolated enum, pure `db` funcs like
`NoteStore`): `places` JOIN `paths (is_alive = 1)` LEFT JOIN `photo_meta`, `GROUP BY
place_key` with count, `MAX(COALESCE(capture_date, modified_at))`, and one cover path
per group (`MAX` row); Swift-side root filtering via `CollectionStore.isUnderAnyRoot`
(the existing trailing-slash-safe helper). NULL `place_key` rows are excluded (no
"Unknown" group — an unplaceable photo simply isn't in Places).

Store follows **Pattern B** (free-standing `@MainActor` singleton observed directly by
views, like `CollectionsEngine`) — zero new `@Published` on `AppState`.

### 4.2 `Views/PlacesPage.swift` — modelled tile-for-tile on `CollectionsPage`

Same skeleton as `Views/CollectionsPage.swift` (the documented page pattern): top
clearance `Color.clear.frame(height: TagChipsRow.noTagsTopClearance)`, `ScrollView` +
`LazyVGrid`, header `HStack { BackArrowButton { appState.closePlacesPage() };
Text("Places").font(.system(size: 42, weight: .semibold)); Spacer(); sort menu }`,
`.background(appState.moodPalette.background)`. Sort menu toggles
`sortByCount` (Count / Recent). Group card: cover thumbnail at the **existing 320×320
grid variant** (no new `renderedVariants` entry — durable constraint honored by reuse),
name + count caption. Empty state (no geotagged photos yet): centered
`Text("No places yet — photos with location will appear here as analysis runs.")`.

**Mount:** `ContentView.detailStage` gains one branch ahead of the grid branch:

```swift
if isCollectionsPage { CollectionsPage().transition(Self.pageReveal) }
else if placesStore.showingPlaces && !appState.isSearchActive { PlacesPage().transition(Self.pageReveal) }
else { … TagChipsRow(); GridView() … }
```

(`@ObservedObject private var placesStore = PlacesStore.shared` beside the existing
`collectionsEngine` property.)

### 4.3 Click-through = a `near:` token search (deviation D6 — no parallel grid state)

Tapping a place group runs a **programmatic token search** instead of introducing a
fourth `visibleFiles` substitution:

```swift
appState.openPlaceSearch(group)   // AppState+Places.swift (methods-only extension)
// = closePlacesPage(); searchAllFolders = true; runs the query "near:\"Lisboa\""
//   through the existing programmatic path: searchQuery = q; Task { await runSearch(q) }
```

The existing `.onChange(of: appState.searchQuery)` in `ContentView` mirrors the injected
query into the field (that seam already exists for programmatic injection), the token
chip bar (§7.5) renders it as a removable chip, Escape backs out through the normal
search-clear chain, and the grid is the ordinary search grid. One navigation system, and
Places dog-foods the token engine. What is lost: sort control inside a place (search
results keep search order) — same tradeoff search already makes, accepted.

### 4.4 Sidebar LIBRARY section + Settings toggle

`SidebarView.twoSectionScroll` becomes three sections: **FOLDERS · LIBRARY ·
COLLECTIONS** (LIBRARY between the existing two; same 14-pt spacer, same
`SectionHeader`, own collapse key `"sidebarLibraryCollapsed"` following the
plain-`@State`-seeded-from-UserDefaults pattern the other two use). Gated identically to
COLLECTIONS: `!appState.rootNodes.isEmpty && collectionsEngine.hasReachableContent`,
plus a new `AppSettings.showLibraryInSidebarKey` (default true) with a SettingsView
toggle in the Sidebar section — mirroring `showCollectionsInSidebarKey` exactly.

Rows (`Views/Sidebar/LibraryRows.swift`), copying the `StarRow` template (fixed,
non-reorderable, shared geometry constants — the documented invariant):

| Row | Glyph | Action |
|---|---|---|
| Places | `mappin.and.ellipse` | `appState.openPlacesPage()` |
| On This Day | `calendar` | `appState.openRediscovery(.onThisDay)` |
| Rarely Seen | `moon.zzz` | `appState.openRediscovery(.rarelySeen)` |
| Shuffle | `shuffle` | `appState.openRediscovery(.shuffle)` |

Selected state: Places row highlights on `placesStore.showingPlaces`; rediscovery rows
on `RediscoveryStore.shared.active == <surface>`; fill/label colors from the shared
`SidebarView.selectionFill`/`selectedLabelColor` constants. All four titles are SwiftUI
`Text` literals (auto-localized) and each row gets the standard
`.accessibilityAddTraits(.isButton)` treatment `StarRow` has.

### 4.5 Viewer: place name + Google Maps

- `ViewerFileDetails` (`Views/Viewer/ViewerFileDetails.swift`) gains `var place:
  String?` — resolved in its existing `load(queue:path:)` DB read (one extra
  `PlaceRow` fetch by `file_id`), formatted "Lisboa, Portugal".
- `ViewerInfoColumn.infoCard`: when `place` exists, the Location row shows the place
  name (coordinates move to the tooltip/`help`); link-outs render as **two** links where
  `OpenInMapsButton` sits today:
  - existing `OpenInMapsButton` (`maps://?ll=…`) unchanged;
  - new `OpenInGoogleMapsButton` — same visual component, URL
    `https://www.google.com/maps?q=<lat>,<lon>` via `NSWorkspace.shared.open`. **This is
    a browser hand-off, not an app network call** — the app never touches the URL with
    `URLSession`; same doctrine class as `maps://`. Label `Text("Google Maps")`,
    accessibility label `"Open location in Google Maps"` (both localized).

---

## 5. Rediscovery

### 5.1 `Models/RediscoveryStore.swift`

```swift
enum RediscoverySurface: String, CaseIterable { case rarelySeen, onThisDay, shuffle }

@MainActor final class RediscoveryStore: ObservableObject {
    static let shared = RediscoveryStore()
    @Published private(set) var active: RediscoverySurface?
    @Published private(set) var files: [FileNode]?      // nil unless a surface is active
    private(set) var paths: Set<String>?                // standardized, for fast membership
    private var requestToken = 0

    func activate(_ s: RediscoverySurface, roots: [String]) // token-guarded async resolve
    func dismiss()
    func reshuffle(roots: [String])                     // shuffle only; new seed
    func drop(path: String)                             // delete-in-view bookkeeping
    func markViewed(url: URL)                           // §5.2
}
```

Queries in `Database/RediscoveryQueries.swift` (nonisolated, pure `db` funcs, all
root-filtered in Swift via `CollectionStore.isUnderAnyRoot` after fetch, kinds limited to
`image/raw/psd/video`):

- **Rarely Seen** (`limit 500`): alive paths joined to `files`, ordered
  `last_viewed_at IS NOT NULL, last_viewed_at ASC, created_at ASC` — never-viewed first
  (they are the coldest), then oldest-viewed.
- **On This Day**: `photo_meta.capture_md = <today "MM-DD">` with capture year <
  current year; files with no `photo_meta` row fall back to the same month-day test on
  `files.created_at` (computed in Swift after a `created_at` range fetch is wrong at
  scale — instead the fallback is a second indexed-enough pass:
  `strftime('%m-%d', created_at,'unixepoch')` over only the rows with **no**
  `photo_meta` row, which shrinks toward zero as the backfill completes). Ordered
  newest year first. Feb 29 shows on Feb 29 only (no Mar 1 remap — recorded, trivial,
  honest).
- **Shuffle**: sample 500 alive image/video paths without replacement using the existing
  `SeededRandom` (`Views/Spatial/SeededRandom.swift`) with a fresh random seed per
  activation/reshuffle.

`activate` resolves off-main (`Task.detached`), maps to `FileNode`s, publishes under its
token — the same stale-guard shape as `setActiveCollection`.

### 5.2 `last_viewed_at` write path — two view-layer hooks, zero AppState edits

`markViewed(url:)`: in-memory dedupe (skip if the same standardized path was marked
< 5 s ago), then fire-and-forget:

```sql
UPDATE files SET last_viewed_at = ?
WHERE id = (SELECT file_id FROM paths WHERE absolute_path = ? AND is_alive = 1)
```

Hooks (both view-layer; `AppState.selectedFile` keeps no `didSet`):

1. `ContentView`: `.onChange(of: appState.selectedFile?.url) { _, url in if let url {
   RediscoveryStore.shared.markViewed(url: url) } }` — covers **every** kind
   (`ViewerRouter` is the single funnel: hero, video, PDF, text, Quick Look fallback).
2. `HeroImageViewer`'s existing `.task(id: currentURL)` (line ~187) and
   `HeroVideoViewer`'s (line ~67): one `markViewed(url: currentURL)` call — covers
   arrow-key flips, which change `currentURL` without touching `selectedFile`.

Double-fire on open is absorbed by the dedupe window. Local-only; never in sidecars;
never sent anywhere.

### 5.3 The `visibleFiles` seam (one line) + invalidation

`AppState+Filters.visibleFiles` non-search branch changes from
`base = activeCollectionFiles ?? currentFiles` to:

```swift
base = activeCollectionFiles ?? RediscoveryStore.shared.files ?? currentFiles
```

Invalidation wiring in `AppState.init`, following the existing `folderStats` forwarding
pattern exactly:

```swift
rediscoveryCancellable = RediscoveryStore.shared.objectWillChange
    .sink { [weak self] _ in self?._visibleFilesValid = false; self?.objectWillChange.send() }
```

(One stored cancellable — not a `@Published` — recorded as the sanctioned integration
cost of the frozen-AppState rule, deviation D7. Same for `PlacesStore` and
`StacksStore`: three cancellables total, declared beside `folderStatsCancellable`.)

### 5.4 Orchestration methods — `Models/AppState+Rediscovery.swift` / `AppState+Places.swift`

Methods-only extensions (the house rule for `AppState+*` files):

```swift
func openRediscovery(_ s: RediscoverySurface)
// clearSelection(); setActiveCollection(nil); showingCollections = false;
// PlacesStore.shared.setShowing(false); RediscoveryStore.shared.activate(s, roots: rootPathList)

func closeRediscovery()          // clearSelection(); RediscoveryStore.shared.dismiss()
func openPlacesPage() / closePlacesPage() / openPlaceSearch(_ group: PlaceGroup)
```

Teardown parity (every context-switch rule the collections page obeys):

- `select(folder:)` additionally calls `RediscoveryStore.shared.dismiss()` +
  `PlacesStore.shared.setShowing(false)` (beside its existing `showingCollections =
  false` at `AppState.swift:922`).
- `removeRoot` re-resolves an active rediscovery surface the same way it re-resolves the
  active collection (calls `activate` again with the shrunk roots) — the
  "collection ghost after root removal" bug class, preempted.
- **Selection pruning:** activating/dismissing a surface narrows/changes `visibleFiles`
  → `activate`/`dismiss` start with `clearSelection()` (via the orchestration methods).
  The durable "anything that narrows visibleFiles must prune selection" rule is thereby
  honored.
- Burn-delete: `AppState.dropFromActiveCollection(path:)` — the documented seam for
  delete-inside-a-view — additionally calls `RediscoveryStore.shared.drop(path:)`.

### 5.5 Grid header + Escape

- `Views/RediscoveryHeader.swift`: mounted in `GridView` exactly where `CollectionsRow`
  mounts (`GridView.swift:205`, `if !appState.isSearchActive`), shown when
  `RediscoveryStore.shared.active != nil`. Same metrics as `ActiveCollectionHeader`:
  `BackArrowButton { appState.closeRediscovery() }`, title (`Text("Rarely Seen")` /
  `"On This Day"` / `"Shuffle"` — localized literals), count, and for Shuffle a
  trailing `ModalButton`-styled "Shuffle Again" calling
  `RediscoveryStore.shared.reshuffle(roots:)`.
- `EscapeAction` gains `.exitRediscovery` and `.exitPlacesPage`;
  `EscapeResolver.action` gains `rediscoveryActive: Bool` and `showingPlacesPage: Bool`
  parameters. Order (documented + tested): modal → viewer → search → tags →
  collection → **rediscovery** → collections page → **places page** → none. Rationale:
  a rediscovery surface behaves like a collection context (content scope), pages are
  outermost. `EscapeActionTests` extended accordingly; `ContentView`'s resolver call
  site passes the two new flags.

---

## 6. Near-duplicate stacks

### 6.1 Prerequisite fix: feature prints are unreadable today (shipped bug)

`files.feature_print` stores **raw `VNFeaturePrintObservation.data`** (the bare Float32
element buffer — written at `VisionServices.swift:197`). But both consumers try
`NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from:)`
(`DuplicateFinder.swift:220`, `SimilarTagSuggestions.swift:134`), which returns nil for
every row — **the duplicate finder's "Visually similar" mode and the similar-photo tag
suggestions have silently returned empty since they shipped.** A
`VNFeaturePrintObservation` cannot be reconstructed from its raw data, so the fix is to
compute distance on the raw buffers directly:

`Intelligence/Core/FeaturePrints.swift`:

```swift
nonisolated enum FeaturePrints {
    /// Raw element buffer → floats. nil when byteCount % 4 != 0 or empty.
    static func floats(_ data: Data) -> [Float]?
    /// Euclidean distance via vDSP. nil when lengths differ
    /// (prints written by different Vision revisions must never pair).
    static func distance(_ a: [Float], _ b: [Float]) -> Float?
}
```

For the Vision revision in use, `computeDistance` is Euclidean distance over these same
elements, so existing threshold intuition (0.45 in `DuplicateFinder`) carries — but
since the visual mode never actually ran, **the threshold has never been validated**;
it ships as a named constant with an owner validation step (§12). Both broken call
sites are rewritten onto `FeaturePrints` (delete both `unarchive` helpers); the
duplicate finder's bucketing/grouping logic is otherwise untouched. New durable
constraint recorded (§9).

### 6.2 `Intelligence/Stacks/BurstClusterer.swift` — pure, tested

```swift
nonisolated enum BurstClusterer {
    static let sessionGapSeconds: Int64 = 10       // spec: same 10s window
    static let similarityThreshold: Float = 0.45   // Euclidean on raw print floats

    struct Item: Sendable {
        let fileID: String
        let captureAt: Int64      // capture_date ?? created_at (caller supplies the coalesce)
        let print: [Float]?       // nil = no feature print → never clusters
    }
    /// Groups of fileIDs, each group.count >= 2, deterministic order.
    static func clusters(_ items: [Item]) -> [[String]]
}
```

Algorithm — **time bucket first, similarity second** (the O(n²) fix, binding #25):

1. Sort by `captureAt`; split into sessions wherever the gap to the previous item
   exceeds `sessionGapSeconds`. This is O(n log n) over the whole library and bounds
   every subsequent comparison to a burst-sized session.
2. Within a session: union-find over pairs with `FeaturePrints.distance(a, b) <=
   similarityThreshold` (skip nil-print items and length-mismatched pairs). Sessions
   are physically small (a burst), so the inner O(k²) is trivial; a defensive cap
   (`maxSessionSize = 256`, splitting oversized sessions at their largest internal
   gaps) keeps a pathological timestamp pile-up (10k scans stamped identically) from
   reintroducing n².
3. Components of ≥ 2 become clusters, ordered by first member's `captureAt`.

### 6.3 `Intelligence/Stacks/AutoStacker.swift` + `Database/StackStore.swift`

`StackStore` — nonisolated pure `db` funcs (the `NoteStore` shape):

```swift
static func stacksFor(fileIDs: [String], db: Database) throws -> [String /*fileID*/ : StackRef]
    // StackRef: (stackID, kind, dissolved, pickFileID) — chunked IN(...) by 800
static func claimedFileIDs(db: Database) throws -> Set<String>   // any membership, incl. dissolved
static func createStack(kind: String, memberIDs: [String], pick: String?, db: Database) throws -> String
static func dissolve(stackID: String, db: Database) throws        // sets dissolved = 1
static func setPick(stackID: String, fileID: String?, db: Database) throws
static func removeMember(stackID: String, fileID: String, db: Database) throws
    // if remaining members < 2 → dissolve
```

`AutoStacker`:

```swift
nonisolated enum AutoStacker {
    /// Clusters VIRGIN files (no stack_members row, incl. dissolved) among `fileIDs`,
    /// writes kind:"auto" stacks. Returns count created.
    static func run(fileIDs: [String]) async -> Int
}
```

Input rows: `files JOIN photo_meta` for `captureAt = COALESCE(capture_date, created_at)`
+ `feature_print`; files already claimed are excluded up front (the §1.5 virgin rule).
Triggers:

1. End of `AnalyzePipeline.analyzePending` / `analyzeFolderManual` — after a pass that
   analyzed anything, over that pass's file ids (prints are freshest there).
2. `StacksStore.reload(for:)` (§6.4) runs it lazily for the current folder when it
   finds virgin analyzed files with prints — so existing libraries stack up folder by
   folder as they're browsed, without a global launch pass.

Both run off-main; writes are one transaction per stack batch.

### 6.4 `Models/StacksStore.swift` + `Components/StackDisplay.swift`

`StackDisplay` — pure math, unit-tested (the `Components/` convention):

```swift
nonisolated enum StackDisplay {
    struct Entry: Equatable { let stackID: String; let isPick: Bool }
    struct Result: Equatable {
        var visible: [FileNode]                 // input order preserved, hidden members removed
        var badges: [String: Int]               // representative std-path → member count IN VIEW
        var hiddenPaths: Set<String>
    }
    /// Collapse rule: for each stack with >= 2 members present in `files`,
    /// keep the pick (if present) else the first in current order; hide the rest —
    /// unless the stack is in `expanded`.
    static func collapse(_ files: [FileNode], entries: [String /*std path*/ : Entry],
                         expanded: Set<String>) -> Result
}
```

`StacksStore` (@MainActor singleton, Pattern B):

```swift
@Published private(set) var entries: [String: StackDisplay.Entry] = [:]  // std path → entry
@Published private(set) var expanded: Set<String> = []                    // stack ids
@Published private(set) var generation = 0        // bumped on any change; grid signature input
func reload(for files: [FileNode]) async          // resolve stacks for these paths; maybe AutoStacker
func toggleExpanded(_ stackID: String)
func stackSelection(paths: [String]) async        // manual stack; §6.6
func unstack(_ stackID: String) async
func setPick(stackID: String, path: String) async
func removeFromStack(path: String) async
```

`reload(for:)` is called from `reloadCurrentFiles`' completion (the fresh-select publish
site) and after any stack mutation; it maps the folder's alive paths → file_ids →
`StackStore.stacksFor` (excluding dissolved stacks from `entries` — dissolved =
invisible), publishes, bumps `generation`.

### 6.5 Grid presentation

- **Collapse applies ONLY in plain folder browsing** (deviation D8): in
  `AppState+Filters.visibleFiles`, after the existing gridFilter step:

  ```swift
  if !isSearchActive && activeCollectionFiles == nil && RediscoveryStore.shared.files == nil {
      let d = StackDisplay.collapse(result, entries: StacksStore.shared.entries,
                                    expanded: StacksStore.shared.expanded)
      StacksStore.shared.badges = d.badges   // plain (non-@Published) var, read by tiles
      result = d.visible
  }
  ```

  (`badges: [String: Int]` is a plain stored var on `StacksStore` — written here inside
  the memoized computation, so it must not publish.)

  Search results never hide a matching frame under a non-matching representative;
  collections show exactly their members; rediscovery shows what its query returned.
  (Google Photos scopes stacks to the main grid the same way.) `StacksStore` changes
  invalidate the memo via its §5.3-style cancellable, and expand/collapse calls
  `pruneSelectionToVisible()` — collapsing narrows `visibleFiles` (durable-constraint
  compliance).
- `gridSignature` (`GridView.swift:677`) gains `StacksStore.shared.generation` and the
  expanded-set count as components, so geometry recomputes on stack changes.
- **Stack badge on `TileView`:** top-LEADING capsule (star badge owns top-trailing),
  same visual family as the star badge — `HStack(spacing: 2) {
  Image(systemName: "square.stack"); Text("\(count)") }`, 10 pt semibold, near-white
  capsule, `badgeInset` 6. Unlike the star badge it **is a click target**: a `Button`
  that calls `StacksStore.shared.toggleExpanded(stackID)`, `.buttonStyle(.plain)`,
  `.contentShape(Capsule())`, VoiceOver label
  `String(format: NSLocalizedString("Stack of %lld photos", comment: …), count)` with a
  named `.accessibilityAction` "Expand Stack"/"Collapse Stack" (mouse-only affordances
  need a VO parallel — durable constraint). Expanded members render inline in flow
  order (no strip view in v1); the representative's badge shows the collapse affordance
  while expanded (filled `square.stack` variant).
- Hero viewer arrow-flips iterate `visibleFiles`, so collapsed members are skipped
  unless expanded — consistent with what the grid shows, accepted (matches Google
  Photos).
- Deleting a representative: the path leaves `currentFiles` → next `visibleFiles` pass
  recollapses and the next member in order becomes representative automatically (no
  stored state to fix; `pick_file_id` pointing at a dead file simply stops matching).

### 6.6 Manual stack / unstack / pick — context-menu surface

In `GridView`'s file-tile context menu (below `SelectionActionsMenu`, above the
Move-to-Trash divider), a Stack section:

- **"Stack Selection"** — visible when ≥ 2 image-kind (`.image/.raw/.psd`) files are
  selected AND none has a `StacksStore` entry (v1 rule: no merging into existing
  stacks; the item is hidden, not disabled-with-mystery, when a member is already
  stacked). Calls `stackSelection(paths:)` → `StackStore.createStack(kind: "manual",
  pick: first-selected)`.
- On a stacked tile: **"Unstack"** (`unstack` → tombstone), **"Set as Stack Pick"**
  (members only), **"Remove from Stack"**.
- All four strings are SwiftUI literals in `Button` labels (auto-localized).
- Kind guards follow the folder-exclusion precedent: `.folder` and non-image kinds
  never see the Stack section.

**Guardrails (binding #13, restated as behavior):** stacking writes ONLY
`stacks`/`stack_members`; a stacked file's tags, rating, notes, collection memberships,
paths, and `analyzed_hash` are bit-for-bit untouched; PDF export / Drive share / Save
to Collection operate on `visibleFiles`, so a collapsed view exports its
representatives — expand first to export all (matches what the user sees; noted in the
session log, not a bug).

---

## 7. Search Phase 1 — tokens over indexed metadata

### 7.1 Token model + grammar — `Search/SearchToken.swift` (new module folder, #26)

```swift
nonisolated enum SearchToken: Equatable, Sendable {
    case camera(String)              // camera:x100v — matches make OR model, case-insensitive substring
    case lens(String)                // lens:23mm
    case iso(NumericFilter)          // iso:>1600, iso:400, iso:100-400
    case aperture(NumericFilter)     // f:<2, f:1.4-2.8 (f-number)
    case inDate(DateToken)           // in:2019, in:2019-06, in:2019-06-21
    case near(String)                // near:Lisboa, near:"New York" — places city/admin/country
    case text(String)                // text:"receipt" — FTS-only, no semantic leg
    case color(String)               // color:red (SmartColor token) or color:#a1b2c3
    case rating(atLeast: Int)        // star:4, ★≥4, ★>=4, ★★★★
    case kind(SmartRule.KindGroup)   // kind:raw, kind:video — reuses the existing group→kinds map

    struct NumericFilter: Equatable, Sendable {
        enum Op: Equatable { case eq, gt, gte, lt, lte, range(Double, Double) }
        var op: Op; var value: Double
    }
    struct DateToken: Equatable, Sendable { var year: Int; var month: Int?; var day: Int? }
}

nonisolated struct ParsedQuery: Equatable {
    var tokens: [SearchToken]
    var freeText: String            // remainder, whitespace-joined
    /// Rebuild the query string minus one token — the chip-✕ operation.
    func removing(tokenAt index: Int) -> String
}

nonisolated enum SearchQueryParser {
    static func parse(_ raw: String) -> ParsedQuery
}
```

Grammar rules (all unit-tested):

- A token is `key:value` with no space before the `:`; value may be double-quoted to
  carry spaces (`near:"New York"`). An unknown key, or a known key with an empty/invalid
  value, is **not** a token — it stays in `freeText` verbatim (typing `iso:` mid-thought
  must not silently drop text from the search).
- Numeric ops: `>`, `>=`, `<`, `<=`, `a-b` range, bare number = equals. `in:` accepts
  `YYYY`, `YYYY-MM`, `YYYY-MM-DD` and expands to a `capture_date` epoch range at query
  time (falling back to `files.created_at` for files with no `photo_meta` row — same
  fallback as On This Day).
- Star forms: `star:N` (≥ N — the common intent), `star:=N` exact, a literal run of
  `★` (its length = ≥ N), `★≥N` / `★>=N`. Parsing strips these before the FTS leg ever
  sees a `★` glyph.
- Keys are **canonical English only in v1** (recorded limitation; French key aliases are
  a follow-up — the values themselves are user data and language-neutral). Keys are
  matched case-insensitively.
- `ParsedQuery.removing(tokenAt:)` reconstructs the query text from surviving tokens +
  free text — the field text remains the single source of truth (§7.5).

### 7.2 `Search/PhotoSearch.swift` — token → SQL, indexed only

```swift
nonisolated enum PhotoSearch {
    struct Result: Sendable {
        var ids: [String]                       // ordered: capture_date DESC, then modified_at DESC
        var idSet: Set<String>
        var dirRestrictions: [String: Set<String>]   // ONLY from rating tokens (per-location data)
    }
    static func filter(tokens: [SearchToken], db: Database) throws -> Result?  // nil when tokens empty
}
```

Per-token SQL (every one hits an index from §1.2/§1.3 or an existing one; AND across
tokens = set intersection, mirroring `SmartRuleSet.all`):

| Token | Query |
|---|---|
| `camera` | `SELECT file_id FROM photo_meta WHERE LOWER(camera_make) LIKE '%v%' OR LOWER(camera_model) LIKE '%v%'` (prefix-anchored `v%` tried first; falls back to substring — model strings like "X100V" make pure prefix too strict) |
| `lens` | same shape on `lens` |
| `iso` / `aperture` | `WHERE iso >= ?` etc.; `range` → `BETWEEN` |
| `inDate` | `WHERE capture_date BETWEEN ? AND ?` ∪ (created_at fallback for rows absent from photo_meta) |
| `near` | `SELECT file_id FROM places WHERE place_key IS NOT NULL AND (LOWER(city) = ? OR LOWER(admin) = ? OR LOWER(country) = ? OR LOWER(city) LIKE ?∥'%')` — exact match on any of the three, else city-prefix |
| `text` | the existing FTS query (`files_fts MATCH`), phrase-escaped — no semantic leg |
| `color` | resolved to `[LabColor]` (SmartColor token name via `SmartColor.rgb(for:)`, else hex via `ColorQuery`'s validator) and handed to the **existing** palette leg in `SearchService` — not re-implemented |
| `rating` | `SmartCollectionResolver.qualifyingRatingLabels(op: .atLeast, stars:)` → `SELECT file_id, parent_dir FROM tags WHERE label IN (…)` — ids AND per-id dir sets |
| `kind` | `SELECT id FROM files WHERE kind IN (…)` via `SmartRule.KindGroup.kinds` |

**Rating tokens carry dir restrictions** because ratings are per `(file_id,
parent_dir)` — a ★★★★ on the `/A` copy must not surface the unrated `/B` copy. That is
the tag/note cross-folder-bleed rule (durable constraint) applied to the one token backed
by per-location data. Every other token is content-derived and unrestricted.

### 7.3 `SearchService.search` integration

Revised flow (`Database/SearchService.swift`) — **byte-identical behavior when no token
parses** (pinned by test):

1. `let parsed = SearchQueryParser.parse(trimmed)`.
2. `parsed.tokens.isEmpty` → the existing pipeline runs on `trimmed`, untouched
   (including the legacy bare-hex `ColorQuery` behavior).
3. Tokens present → inside the existing `queue.read`:
   - `let tok = try PhotoSearch.filter(tokens: parsed.tokens, db: db)!`
   - **Token-only** (`freeText` empty, no color token): `orderedIDs = tok.ids`;
     `matchedDirs = tok.dirRestrictions`; resolve via the existing
     `aliveePaths(for:restrictedToDirs:db:)` and return through the existing scope
     filter. Ranking = capture DESC (photo intuition; free-text relevance ordering
     doesn't apply when there's no free text).
   - **Tokens + free text**: run the existing legs (FTS/tag/note/semantic/color) on
     `parsed.freeText` exactly as today, producing `orderedIDs` + `matchedDirs`; then
     `orderedIDs = orderedIDs.filter { tok.idSet.contains($0) }` (the precedent is the
     existing color∧text intersection at `:164-166`); then apply token dir
     restrictions AFTER the existing relaxation step so an FTS match cannot un-restrict
     a rating token: `for (id, dirs) in tok.dirRestrictions { matchedDirs[id] =
     matchedDirs[id].map { $0.intersection(dirs) } ?? dirs }`.
   - A `color:` token routes its `[LabColor]` into the existing color leg variables, so
     token-color ∧ text behaves exactly like today's hex ∧ text.
4. The unindexed-extras leg (`currentFolder` basename scan) is skipped whenever tokens
   are present — extras can't satisfy token constraints.

Everything expensive stays where it is; token SQL adds single-digit milliseconds at 50k
(indexed lookups + set ops). The `< 100 ms` acceptance number is measured by a new
`PerfBaseline` metric (additive row in Spec 01's harness table: "token search, 50k
synthetic photo_meta" — budget 100 ms).

Debounce is unchanged (250 ms in `ContentView.handleSearchTextChange`); "works with tags
off" holds by construction — no token reads `tags` except `rating`, which is
tag-implemented by design (#13) and still works when the *user-facing tag UI* is unused.

### 7.4 Autocomplete — `Search/SearchFacets.swift` + `.searchSuggestions`

```swift
@MainActor final class SearchFacets: ObservableObject {
    static let shared = SearchFacets()
    @Published private(set) var cameras: [String] = []   // DISTINCT camera_model, count DESC
    @Published private(set) var lenses: [String] = []
    @Published private(set) var places: [String] = []    // DISTINCT city (place_key non-NULL)
    @Published private(set) var years: [String] = []     // DISTINCT strftime('%Y', capture_date)
    var snapshot: FacetsSnapshot { … }                   // value copy for the pure suggester
    func refresh() async     // four DISTINCT selects, off-main; ~ms at 50k
}

nonisolated struct FacetsSnapshot: Equatable, Sendable {
    var cameras: [String]; var lenses: [String]; var places: [String]; var years: [String]
}

nonisolated enum SearchSuggest {
    struct Suggestion: Equatable, Identifiable {
        var display: String        // "camera: FUJIFILM X100V"
        var completion: String     // full replacement field text
        var id: String { completion }
    }
    /// Pure: current field text + facets → at most 8 suggestions.
    static func suggestions(fieldText: String, facets: FacetsSnapshot) -> [Suggestion]
}
```

Rules (pure, tested): a trailing partial word that prefixes a token key suggests the
key (`cam` → `camera:`); a trailing `key:` or `key:partial` suggests real values from
the matching facet list (this is the "autocomplete reflects real library values"
acceptance item); free text with no partial token suggests nothing (the field is not a
command line). `completion` replaces only the trailing token-in-progress, preserving
everything before it.

Wiring in `ContentView`, directly after `.searchable`:

```swift
.searchSuggestions {
    ForEach(SearchSuggest.suggestions(fieldText: searchText,
                                      facets: searchFacets.snapshot)) { s in
        Text(s.display).searchCompletion(s.completion)
    }
}
```

(`.searchSuggestions`/`.searchCompletion` are macOS 13+; floor is 14.6. The native
field + native suggestions is what keeps the toolbar search durable-constraint intact.)
`refresh()` triggers: launch (after `PhotoHeaderBackfill`/`GeocodeBackfill` complete)
and at the end of any analyze pass that wrote rows.

### 7.5 Token chip bar (deviation D9 — the "custom SwiftUI token bar", delivered as chips-below-toolbar)

The committed query's tokens render as **removable chips in the existing active-filter
bar row of `TagChipsRow`** — the row that already renders "Viewing <tag> ✕" pills and is
already mounted during search:

- `TagChipsRow` computes `SearchQueryParser.parse(appState.searchQuery)` when
  `appState.isSearchActive` (pure, cheap, no new state anywhere — the field text stays
  the single source of truth).
- Each token renders as a `BannerPill(label: token.displayLabel) { … }` ahead of any tag
  pills, prefixed `Text("Search")` (the tag group keeps its "Viewing" prefix). The ✕
  action rebuilds the query via `parsed.removing(tokenAt:)` and re-runs it through the
  existing programmatic path (`searchQuery` assignment + `runSearch` — the same seam
  `runSearchNow` uses); removing the last token with empty free text clears the search.
- `token.displayLabel` (a `SearchToken` extension in the same file): localized key
  display via `String(localized:)` per case + the raw value (`"camera: X100V"`,
  `"★ ≥ 4"`).

**Why not in-field NSTokenField-style tokens (the foundation's literal sketch):** the
search field is the native `.searchable` toolbar item — a hard-won durable constraint
(collapse-to-magnifier, overflow behavior; `docs/search-bar-fill-investigation.md` is
the record of why custom toolbar fields lost). Tokens-as-text + chips-below keeps every
token *visible and editable* (the foundation's actual requirement — stated for the FM
parser as "always render the parsed result as visible tokens the user can edit") without
re-fighting that battle. Spec 03's natural-language layer lands on this same surface:
FM fills a `ParsedQuery`, which round-trips to text. Recorded as the binding
interpretation.

### 7.6 What search phase 1 does NOT change

`SemanticSearch`, `SearchBridge`, `NoteStore` legs, the `matchedDirs` relaxation for
FTS/semantic/unscoped-tag ids, scope filtering, and `AppState+Search` are untouched
except as described in §7.3. The Spec 01 semantic-cancellation item
(threading the token into the embedding walk) remains Spec 01's deliverable — not
duplicated here.

---

## 8. `.location` smart rule

### 8.1 Model (`Intelligence/Collections/SmartRule.swift`)

```swift
case location(LocationTerm)                              // 8th case

nonisolated enum LocationTerm: Codable, Equatable {
    case place(String)                                   // matches city OR admin OR country display
    case near(lat: Double, lon: Double, radiusKM: Double)
}
```

`isValid`: `.place` requires non-blank trimmed string; `.near` requires
`sanitize`-passing coordinates and `radiusKM > 0`. Codable stays fully synthesized
(house style). **Back-compat consequence, recorded:** a rule set containing `.location`
fails `SmartRuleSet.decode` wholesale on a pre-v17 build → the collection survives
(smart collections are `model_version = "manual"`) but shows empty there. Same
consequence every future case has; accepted when v12 chose synthesized Codable.

### 8.2 Evaluation (`SmartCollectionResolver.evaluate`)

- `.place(let name)`: `SELECT file_id FROM places WHERE place_key IS NOT NULL AND
  (LOWER(city) = ? OR LOWER(admin) = ? OR LOWER(country) = ?)` — with the country
  comparison also accepting the *localized display name* resolved back to its ISO code
  in Swift first (user types "Portugal", DB stores "PT").
- `.near(lat, lon, radiusKM)`: bounding-box prefilter on the v13 partial index, exact
  haversine in Swift:

  ```sql
  SELECT id, lat, lon FROM files
  WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?
  ```

  Box: `±radius/111.32` degrees latitude; longitude span divided by
  `cos(latitude)` clamped away from the poles; **a box crossing ±180° splits into two
  range queries** and unions (pure helper `GeoBounds.boxes(lat:lon:radiusKM:)
  -> [(latRange, lonRange)]`, unit-tested with antimeridian fixtures). Then
  `GreatCircle.distanceKM(...) <= radiusKM` filters exact.

### 8.3 UI (`SmartCollectionRulesView`)

`Kind` enum gains `case location` (label `Text("Location")`); `defaultRule(for:)` →
`.location(.place(""))`; `valueControls` for `.place` = `TextField` (width 210, like
filename) with placeholder `Text("City or country")`. **`.near` decodes and evaluates
but has no editor in v1** — the exact precedent of `ColorTerm.hex` (decodes, no UI),
noted in the same comment style. All four exhaustive-switch sites from the current-state
audit are covered by the compiler; the two test files that enumerate cases
(`SmartRuleSetTests.testEveryRuleTypeRoundTrips`, `SmartCollectionResolverTests`) gain
the new case (§10).

---

## 9. New durable constraints (added to `CLAUDE.md`)

1. **`files.feature_print` is RAW `VNFeaturePrintObservation.data` — never
   `NSKeyedUnarchiver` it.** It was never an archive; unarchiving returns nil and the
   consumer silently degrades to empty results (the shipped visual-duplicates bug).
   All comparisons go through `FeaturePrints.floats/distance`, which refuses
   length-mismatched pairs (prints from different Vision revisions must never pair).
2. **Query time touches ONLY precomputed data.** Every search token resolves against an
   indexed column written at analyze/backfill time (`photo_meta`, `places`,
   `files.lat/lon`, `capture_md`); no token may open a file, call Vision, or geocode.
   New search capability = new indexed column + backfill, never query-time work.
3. **Geocoding is fully offline** (bundled GeoNames, k-d tree). `CLGeocoder`/MapKit
   geocoding are forbidden (network + throttled). The bundled dataset decompresses into
   an exact-size buffer (bounded inflate); `places.country` stores the ISO code and
   localizes at display time.
4. **Attempted-markers for header-derived data:** `coords_scanned_hash`,
   `photo_meta.exif_scanned_hash`, and the `places` row (NULL place = "geocoded,
   nothing near") exist so files without GPS/EXIF/places are not re-scanned every
   launch — the `analyzed_hash`-NULL retry-loop bug shape. Don't replace any of them
   with a bare NULL-column check; dataless iCloud files are skipped WITHOUT stamping.
5. **Stacks are presentation-only and content-keyed**: sets of `file_id` in
   `stacks`/`stack_members`; they never touch paths, tags, ratings, notes, or
   collection membership. Collapse applies ONLY in plain folder browse (never search,
   collections, or rediscovery), and any collapse/expand change must prune the grid
   selection. The auto-stacker only ever touches files with no `stack_members` row —
   dissolved stacks are tombstones that keep their members claimed (that is what makes
   unstack durable); don't "clean up" dissolved rows.
6. **`last_viewed_at` is device-local** — never exported to sidecars, never synced,
   never sent anywhere. Rediscovery surfaces are queries over it; they add no new
   analysis.
7. **Search token grammar keys are canonical English** and parse before every other
   leg; an unparseable token stays in free text verbatim (typed text is never silently
   dropped). The committed field text is the single source of truth for tokens — the
   chip bar renders `SearchQueryParser.parse(searchQuery)`, holds no state of its own,
   and edits tokens by rewriting the query text.

---

## 10. Tests

All pure-logic (house convention). New files:

| File | Covers |
|---|---|
| `PhotoHeaderReaderTests` | `exifFields` mapping (ISO array vs scalar, flash bit 0, missing keys → nil), `parseExifDate` (valid, garbage, epoch↔MD agreement), `sanitize` bounds/NaN (Spec 01's cases, absorbed) |
| `PhotoMetaMigrationTests` | v13→v17 run clean on a v12 library; columns/indexes/tables present; idempotent re-migrate; existing rows untouched |
| `PhotoHeaderBackfillTests` | selection SQL picks stale-by-either-marker rows only; hash-guard skips a mid-pass edit; dataless skip stamps nothing |
| `GeoKDTreeTests` | nearest == brute force on 5k random points; antimeridian pair (179.9°E vs 179.9°W); polar points; empty input |
| `GeoNamesDatasetTests` | TSV row parse; admin1 join; bounded-inflate rejects short/oversized payloads (fail closed, no crash) |
| `ReverseGeocoderTests` | fixture cities: known coord → expected place; 151 km away → nil; `key` normalization |
| `PlaceQueriesTests` | grouping, count vs recency order, cover path = most recent, NULL place_key excluded, root filtering |
| `RediscoveryQueriesTests` | rarely-seen order (NULL-first, then ascending), on-this-day MD match across years + created_at fallback + year ordering, shuffle determinism under a fixed seed, kind restriction |
| `LastViewedTests` | `markViewed` dedupe window; write targets the alive path's file_id |
| `FeaturePrintsTests` | raw blob → floats (alignment guard), Euclidean distance, length mismatch → nil; **regression: `DuplicateFinder.visualGroups` forms groups from raw-data prints** (the shipped-bug pin) |
| `BurstClustererTests` | session split at the 10 s gap; no cross-session pair ever compared; union within session; nil-print and mismatched-length items never cluster; `maxSessionSize` split; deterministic output order |
| `StackStoreTests` | create/dissolve/setPick/removeMember (auto-dissolve under 2); `claimedFileIDs` includes dissolved; cascade on file delete |
| `StackDisplayTests` | collapse keeps pick else first-in-order; badge counts = members in view; expanded shows all; < 2 present → no collapse; order preservation |
| `SearchQueryParserTests` | every token form incl. quoted values, numeric ops/ranges, `in:` shapes, all star spellings, unknown key → free text, `removing(tokenAt:)` round-trip |
| `PhotoSearchTests` | in-memory DB per token; AND intersection; rating dir-restriction map; capture-DESC ordering; `in:` created_at fallback |
| `SearchServiceTokenTests` | tokenless query byte-identical to today (pin); token∧text intersection; rating restriction survives FTS relaxation; token-only path ordering |
| `SearchSuggestTests` | key-prefix suggestion, value suggestions from facets, completion preserves preceding text, cap at 8, no suggestions for plain free text |
| `SmartRuleLocationTests` | round-trip Codable, `isValid` branches, resolver `.place` (incl. localized-country → ISO), `.near` bbox + haversine + antimeridian split |
| `EscapeActionTests` (extended) | new ordering incl. `.exitRediscovery` / `.exitPlacesPage` |

Existing suites that must stay green and are touched: `SmartRuleSetTests` (+ location in
the round-trip list), `SmartCollectionResolverTests` (+ location), `EscapeActionTests`,
`GridFilterTests`, `FileMetadataTests`/`FileMetadataLoadTests` (untouched reader — must
not regress), `DuplicateDeleteRulesTests`.

---

## 11. Build order

1. **§6.1 FeaturePrints fix** (standalone bug fix; smallest reviewable unit; unblocks
   stacks and un-breaks shipped visual duplicates)
2. **v13 + v14 + `PhotoHeaderReader` + `analyzeOne` write points + `PhotoHeaderBackfill`**
   (§1.1–1.2, §2) — everything downstream reads these rows
3. **v15 + GeoNames artifacts + `GeoKDTree`/`ReverseGeocoder`/`GeocodeBackfill`** (§3) +
   About attribution
4. **Search phase 1** (§7): parser → `PhotoSearch` → `SearchService` integration →
   facets/suggestions → chip bar → `PerfBaseline` metric
5. **Places surface** (§4): `PlacesStore`/`PlaceQueries` → `PlacesPage` → sidebar
   LIBRARY section (Places row only at this point) → click-through via `near:` →
   viewer place row + Google Maps
6. **v16 + Rediscovery** (§5): `markViewed` hooks → queries → store → seam → header →
   sidebar rows → Escape cases
7. **v17 + Stacks** (§6.2–6.6): clusterer → store/engine → collapse seam → badge/UI →
   context menus
8. **`.location` smart rule** (§8)
9. Docs: `CLAUDE.md` (constraints §9, phase-table row), `architecture-map.md`,
   `session-log.md`; localization export pass (`xcodebuild -exportLocalizations … fr`,
   fill new keys — the feature is incomplete until this reports 0 untranslated)

Steps 4–8 are independently shippable behind their migrations; 2–3 are strict
prerequisites for 4's `near:`/`in:` tokens, 5, 6's On This Day, and 7's time bucketing.

---

## 12. Owner-only steps

1. Run `scripts/make-geonames.sh` once (downloads cities1000 + admin1CodesASCII from
   geonames.org, ~35 MB transfer, dev machine only) and commit the two generated
   resources. The app itself never fetches them.
2. **Validate `BurstClusterer.similarityThreshold` (0.45) and the duplicate finder's
   repaired visual mode against real bursts** — a camera burst series and a
   same-scene-different-shot pair. The number was never live before §6.1; tuning it is
   a judgment call only real photos can settle.
3. Re-run `PerfBaseline` (with the new token-search metric) on the M1 Air 8GB and
   commit the report — the < 100 ms acceptance number is measured there.
4. French translations for the new keys (the export pass emits them; the wording is the
   owner's voice).

---

## 13. Deliberate deviations from the source specs

Recorded so they read as decisions, not drift:

1. **Spec 01 §2 absorbed and amended:** one `PhotoHeaderReader` + one
   `PhotoHeaderBackfill` replace `CoordinateReader` + `CoordinateBackfill` — the header
   is opened once for coordinates AND EXIF. Spec 01's schema, sanitize rules, caps, and
   video handling carry verbatim; nothing of Spec 01 §2 was built, so nothing is
   migrated. §2.
2. **EXIF lives in a `photo_meta` table, not columns on `files`** — keeps `SELECT *`
   fetch paths lean and the change surface contained; identical content-keyed grain.
   §1.2.
3. **`last_viewed_at` is content-keyed and never synced** — viewing either
   byte-identical copy marks the asset seen; device-local by design. §1.4.
4. **Stacks are folder-agnostic `file_id` sets** (no `parent_dir`), collapsed at
   display time only in plain folder browse; auto-stacking touches only virgin files
   and dissolved stacks are permanent tombstones. §1.5, §6.5.
5. **cities1000 over cities15000** — villages are where travel photos happen; ~2 MB of
   bundle is the whole cost. §3.1.
6. **Places click-through is a programmatic `near:` token search** — no fourth
   `visibleFiles` substitution, one navigation system, dog-foods the token engine.
   §4.3.
7. **AppState stays frozen via three forwarded `objectWillChange` cancellables** (the
   `folderStats` pattern) plus methods-only extensions — no new `@Published` on
   `AppState` anywhere in this spec. §5.3.
8. **Stack collapse never applies in search/collections/rediscovery** — a matching
   burst frame must not hide under a non-matching representative. §6.5.
9. **The "custom SwiftUI token bar" ships as tokens-in-text + chips below the toolbar**
   (the existing active-filter-bar surface), preserving the native `.searchable`
   durable constraint; suggestions ride native `.searchSuggestions`. In-field token
   views are explicitly not built. §7.5.
10. **Feature-print similarity is computed on raw float buffers** —
    `VNFeaturePrintObservation` cannot be reconstructed from its stored `data`, so
    Vision's `computeDistance` is unreachable for persisted prints; Euclidean over the
    elements is the same metric. Fixes the shipped dead visual-duplicates mode as a
    prerequisite. §6.1.
11. **Shutter/focal/flash are indexed but have no v1 token** — the shipped token set is
    exactly the foundation §4 list; the columns exist so adding `shutter:`/`mm:`/
    `flash:` later is grammar-only. §1.2, §7.1.
12. **Theme layer (#27) is NOT introduced here.** No spec assigns its creation; it does
    not exist in the codebase (verified), so "all new surfaces use the Theme layer" is
    unsatisfiable as written. New surfaces use system semantic colors, the shared
    `SidebarView` constants, and `moodPalette` — no raw hex anywhere. **Flag to owner:**
    the token layer should get its own small spec before Spec 04's editor UI, where the
    custom-surface count explodes.
13. **Rediscovery surfaces cap at 500 items** (Rarely Seen, Shuffle sample) — they are
    browse surfaces, not archives; caps keep activation instant at 800k (#25) and
    Shuffle re-samples on demand.

---

## 14. Acceptance mapping (from `spec-02-photo-library-core.md`)

| Acceptance item | Where satisfied |
|---|---|
| 20k library: Places populated fully offline | §2 backfill + §3 geocode chain, zero network by construction (§9.3) |
| Place grid opens instantly | `places` grouped query over indexed `place_key`, no file I/O (§4.1); groups cached in `PlacesStore` |
| Smart collection by location works | §8 |
| Rarely Seen / Shuffle / On This Day in sidebar; `lastViewedAt` updates on view | §4.4 rows, §5.1–5.2 |
| Bursts collapse into stacks; manual stack/unstack/pick; no identity side effects | §6.2–6.6; guardrails §6.6 + constraint §9.5 |
| Token search < 100 ms at 50k for indexed queries | §7.2–7.3, measured via the `PerfBaseline` metric (§12.3) |
| Autocomplete reflects real library values | §7.4 facets = `SELECT DISTINCT` over the live index |
| Works with tags disabled | §7.3 — only the rating token reads `tags`, by design (#13) |
