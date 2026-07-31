# Spec 06 — Import & Migration (Lightroom, Apple Photos, Google Takeout, Eagle) + Import-Size FYI: full implementation spec

*Derived from `pre-spec-06-import-migration.md` + `muse-photo-foundation.md` (§7
import & migration; §13 decision log is authoritative) + `DECISIONS.md` (the binding
build-level layer from Specs 01–05). Build-level expansion: exact files, exact seams,
exact tests. Written before implementation. Verified against the codebase at `cefa008`
(`feat/editing`) — as of that commit **no Spec 01/02/03/04/05 code exists in the
tree** (migrations end at `v12_smart_collections`); everything referenced from Specs
01–05 is referenced exactly as specified there, and every reference to existing code
was read from the actual source (`Import/MetadataKeywordReader.swift`,
`Import/MetadataImportApply.swift`, `Import/MetadataImportRules.swift`,
`Import/MetadataImportModel.swift`, `Import/MetadataImportSheet.swift`,
`Models/AppState+Import.swift`, `Database/TagStore.swift`, `Database/NoteStore.swift`,
`Database/SearchService.swift`, `Filesystem/Sidecar.swift`, `Filesystem/FileMover.swift`,
`Intelligence/AnalyzePipeline.swift`, `Intelligence/Collections/CollectionStore.swift`,
`Components/WorkProgress.swift`, `Components/AnalyzeProgress.swift`,
`Settings/AppSettings.swift`, `Models/StarRating.swift`, `MuseApp.swift`,
`ContentView.swift`, `docs/future-features/eagle-library-import.md`).*

---

## 0. What this spec does, does not, and depends on

**Does:** one coherent **File > Import** submenu over five sources, all reporting
through one shared `ImportReport` card; the **universal lossless layer** (extends the
shipped `MetadataKeywordReader` with GPS, caption/title/creator → note, and
`xmp:Label`); the **color-label mapping sheet** (DECIDED #12 — Skip / `Label: X`
namespaced tag / user-chosen tag, remembered, reported) plus the search-exclusion
rule that keeps label tags out of content-flavored search; **Lightroom edit import**
(crs: namespace → badged "approximated" `EditStack`s inside the industry envelope,
with one-click compare against the file's embedded rendered preview) and **Lightroom
preset (.xmp) import** into `edit_presets`; **Apple Photos import** (PhotoKit
current-version rendered image + metadata, albums → collections, stated-plainly
limitations); **Google Takeout import** (JSON-beside-file metadata merge with the
filename-quirk ladder); **Eagle `.library` import** (per the approved
`docs/future-features/eagle-library-import.md` design, updated for the Notes feature
that now exists); and the **import-size FYI + analysis throttling** package (DECIDED
#22/#23): on-device-calibrated time estimate, one-button FYI card gated on estimated
time, visible pause/resume progress in Settings + a sidebar footer row, and
battery/Low-Power/thermal-aware throttling of the analyze pass and the Spec 02/03
backfills (the work DECISIONS explicitly parks here: "Backfill posture … battery/
thermal-aware pausing is Spec 06's work").

**Does not:** Capture One `.costyle` (deferred, foundation §12) · face identity from
any source (people names from Takeout become plain tags or are skipped — never
identities) · any write-back to source apps · AAE/`PHAdjustmentData` parsing (Apple-
private; pre-spec forbids) · Highlights/Shadows/Whites/Blacks/Clarity/Dehaze/local-
correction translation from Lightroom (outside the industry envelope — skipped AND
disclosed, never silently attempted) · pick/reject flags (LR doesn't export them to
XMP; pre-spec: "do not invent handling") · any new analysis toggle (analysis stays
always-on; pause is temporal, not an off switch) · any new search token or smart-rule
case.

**Migrations: NONE.** Spec 06 adds no tables and no columns — every write lands in
existing seams (`tags`, `notes`, `edits`/`edit_presets` from Spec 04, `photo_meta`/
`files.lat/lon` from Spec 02, `collections`). The one new persisted edit-model datum
(the "Approximated from Lightroom" provenance) rides the `EditStack` JSON itself
(§4.4), not a column. Future specs still continue at **v24**.

**Depends on:**

| Dependency | Needed by | Nature |
|---|---|---|
| Shipped metadata import (`Import/` module, Polish 19) | §1–§3 (the universal layer extends it in place) | **Hard** — already in the tree. |
| Spec 02 (v13 `files.lat/lon` + markers, v14 `photo_meta`, `PhotoHeaderReader`, `PhotoHeaderBackfill`, `SearchFacets`) | §2.4 supplement writer (GPS/dates from XMP sidecars, Takeout JSON, PHAsset), Takeout/Apple acceptance ("dates/GPS restored") | **Hard for the supplement legs.** Keywords/ratings/labels/notes legs and the Eagle/Apple/Takeout file-copy flows run without it (the supplement step no-ops when the schema is absent — but do not ship that way; build order §14 assumes Spec 02 first). |
| Spec 04 (`EditStack`/`EditStackCodec`/`EditStore`/`EditPresetStore`, editor before/after suite) | §4 LR edit import, §5 LR preset import | **Hard for §4–§5 only.** The pre-spec allows metadata-only sequencing ahead of editing; §4/§5 are cleanly severable (their menu items simply don't appear until built). |
| Spec 03 | nothing | None. (`SearchFacets.refresh()` is called after imports **when it exists** — same chaining rule as the backfills.) |
| Spec 05 | nothing | None. (LR *preset* import was Spec 05's recorded deferral to this spec; it needs only Spec 04's `edit_presets`.) |

**Independently shippable:** each numbered build-order step (§14) maps to one
pre-spec item and leaves the app releasable.

---

## 1. The Import surface — one submenu, one report

### 1.1 File > Import submenu (`MuseApp.swift`)

The single existing item (`MuseApp.swift:266`, "Import Keywords & Ratings…") becomes
a **File > Import submenu** — the promotion the Eagle design doc already called for
("promote the single item to a File > Import submenu when Eagle joins it"):

```
File > Import >
    Metadata & Lightroom Edits…      // §2–§4 — the folder scan (supersedes the old item)
    Lightroom Presets…               // §5 — .xmp preset files → edit_presets (Spec 04 built only)
    From Apple Photos…               // §6
    From Google Takeout…             // §7
    From Eagle Library…              // §8
```

All five are `Label(_:systemImage:)` literals (auto-extracted for localization).
"Metadata & Lightroom Edits…" keeps the old item's `square.and.arrow.down` glyph and
its enablement (always enabled — it opens a picker). Items whose spec dependency is
unbuilt are **absent, not disabled** (the hidden-not-disabled house rule from
"Stack Selection").

### 1.2 `AppState.importModal` — one shell-modal seam for all import UI (deviation D6)

The shipped `AppState.metadataImportRequest` (`Models/AppState.swift:341`) is
**replaced** by one enum-payload flag, so five import flows cost AppState *net zero*
stored properties (the `collectionModal` / `CollectionModal` precedent — a card
raised from a menu can't present itself; the shell presents it):

```swift
// Models/AppState+Import.swift (extended file; the struct moves here)
enum ImportModal: Equatable, Identifiable {
    case metadata(MetadataImportRequest)     // §2–§4 (folder scan run card)
    case labelMapping(LabelMappingRequest)   // §3 (raised BY the run, over it)
    case lightroomPresets([URL])             // §5
    case applePhotos                         // §6
    case takeout(TakeoutImportRequest)       // §7
    case eagle(EagleImportRequest)           // §8
    case report(ImportReport)                // §1.3 (raised by any run on completion)
    var id: String { … }                     // stable per case + payload id
}
```

- `@Published var importModal: ImportModal?` replaces `metadataImportRequest`
  1-for-1: the `modalPresented` term at `AppState.swift:517` swaps to
  `importModal != nil`, the `dismissTopModal` branch at `ContentView.swift:55`
  swaps to clearing it, and the `.museModal` presenter at `ContentView.swift:202-205`
  switches over the enum. (AppState-frozen accounting: −1 `@Published`, +1
  `@Published` — the same sanctioned modal-flag class as Spec 04's
  `openWithForkRequest`.)
- Every run card keeps the shipped `MetadataImportSheet` contract: built only while
  presented, `.onAppear` starts the model, **`.onDisappear` cancels it** (work
  already applied stays; re-runs are idempotent), footer buttons are `ModalButton`,
  presented at the shell, registered in `modalPresented`.
- `labelMapping` and `report` are raised **over** a run card by setting `importModal`
  to the new case (the run model holds its own state; the card swap is a phase
  change, not a second stacked modal — one flag, one card at a time, Escape peels it
  via the existing `dismissTopModal`).

### 1.3 `Import/ImportReport.swift` + `Import/ImportReportCard.swift`

One report shape for every source (the pre-spec's "always show what happened"):

```swift
nonisolated struct ImportReport: Equatable, Identifiable {
    let id: UUID
    var sourceName: String                   // localized display: "Lightroom", "Apple Photos", …
    var filesImported: Int = 0               // files copied/created (0 for in-place scans)
    var filesTouched: Int = 0                // files that received any metadata
    var filesWithNone: Int = 0
    var filesSkipped: Int = 0                // unreadable / dataless / copy-failed
    var keywords: Int = 0                    // tag rows written or promoted
    var ratings: Int = 0
    var notes: Int = 0
    var coordinates: Int = 0                 // supplement writes that filled lat/lon
    var captureDates: Int = 0
    var labelCounts: [LabelOutcome] = []     // per label value: count + the mapping applied
    var editsApproximated: Int = 0           // LR stacks written
    var editsSkippedExisting: Int = 0        // had a Muse edit already — never clobbered
    var unsupportedSliders: [String: Int] = [:] // "Highlights" → file count, … (§4.2)
    var collectionsCreated: Int = 0
    var notices: [String] = []               // source-specific stated-plainly lines (§6.3, §7.2)
}
nonisolated struct LabelOutcome: Equatable {
    var label: String                        // raw source value ("Red", "Rouge", "Second")
    var count: Int
    var choice: LabelMapping.Choice
}
```

`ImportReportCard` renders it as a plain summary list (the pre-spec's example line —
"312 ratings, 1,840 keywords, 47 red labels → `Label: Red`" — is the register to
match), with the `unsupportedSliders` disclosure and `notices` at the bottom in
`.secondary`. One **Done** button. Counts accumulate in the run models and are pure
data — the card computes nothing.

---

## 2. The universal lossless layer — extending the shipped scanner

### 2.1 `MetadataKeywordReader.Extracted` grows four fields

`Import/MetadataKeywordReader.swift` keeps its name, entry point, and guarantees
(header/sidecar-only reads, never a pixel decode, dataless-iCloud throw at
`MetadataKeywordReader.swift:37-40`, image-COUNT readability probe at :49-51). The
struct at :19-24 becomes:

```swift
struct Extracted: Equatable {
    var keywords: [String] = []
    var rating: Int? = nil
    var label: String? = nil            // xmp:Label — raw string, verbatim (§3)
    var title: String? = nil            // dc:title [Alt, first] → IPTC ObjectName
    var caption: String? = nil          // dc:description [Alt, first] → IPTC CaptionAbstract
    var creator: String? = nil          // dc:creator [Seq, first] → IPTC Byline
    var coordinate: (lat: Double, lon: Double)? = nil  // exif:GPS* in XMP (§2.2); Equatable via ==
    var isEmpty: Bool                   // ALL fields empty/nil
    fileprivate var complete: Bool      // ALL fields populated (short-circuit gate)
}
```

- The per-field **sidecar → embedded XMP → embedded IPTC** priority is unchanged and
  extends naturally: `merge(from:into:)` (:87-95) gains the four XMP reads (each
  guarded `out.field == nil`), `mergeIPTC` (:124-137) gains the three IPTC fallbacks
  (`kCGImagePropertyIPTCObjectName`, `kCGImagePropertyIPTCCaptionAbstract`,
  `kCGImagePropertyIPTCByline` — Byline arrives array-or-string like Keywords; take
  the first). `xmp:Label` has no IPTC fallback (none exists).
- `dc:title`/`dc:description` are XMP **Alt** arrays and `dc:creator` a **Seq** —
  all three read through the existing `xmpSubjects`-style tag-value walk (:99-112,
  generalized to `xmpStrings(_:path:)`), taking the first entry.
- `complete` covering more fields means the embedded-XMP/IPTC fallbacks run for more
  files than before — header-only property reads, cost noise. The existing
  keywords/rating behavior is **pinned byte-identical** by test (§13): same inputs →
  same `keywords`/`rating` out.

### 2.2 XMP GPS — `Import/XMPGPS.swift` (pure, tested)

Lightroom writes GPS into sidecars as XMP-format strings (`exif:GPSLatitude` =
`"47,20.516N"` — degrees, comma, decimal minutes, hemisphere suffix), which
`CGImageSource`'s GPS dictionary never sees for sidecar-only RAW workflows — this is
the one coordinate source `PhotoHeaderReader` (Spec 02 §2.1) structurally cannot
reach, and why the import carries its own GPS leg:

```swift
nonisolated enum XMPGPS {
    /// "DD,MM.mmmmH" / "DD,MM,SSH" → signed decimal degrees; nil for malformed.
    static func parse(_ s: String?) -> Double?
    /// Both axes or nothing; out-of-range (|lat|>90, |lon|>180) and non-finite
    /// rejected — the PhotoHeaderReader.sanitize rule, restated here because the
    /// import can run before Spec 02 exists.
    static func coordinate(lat: String?, lon: String?) -> (Double, Double)?
}
```

Read from the metadata via `CGImageMetadataCopyTagWithPath(meta, nil,
"exif:GPSLatitude")` / `"exif:GPSLongitude"` — sidecar first, then embedded XMP,
same as every other field.

### 2.3 Title/caption/creator → the per-location note (fill-gaps only)

Muse has no user-facing caption field — `files.caption` is the Vision caption,
content-keyed and rewritten by every analyze pass; landing IPTC text there would be
clobbered (and would violate the display-time-vs-storage split). The right
destination is the **per-`(file_id, parent_dir)` note** (v11, `NoteStore`) — user
text, per-location, searched via the note leg, synced via sidecars. Pure composer:

```swift
nonisolated enum ImportedText {
    /// Joins the non-empty, case-insensitively-distinct values in order
    /// title · caption · creator (creator prefixed "© ") with newlines.
    /// nil when all empty. Whitespace-trimmed. Length-capped at 2_000 chars
    /// (defensive — IPTC blocks are small; a malformed field can't balloon a note).
    static let maxLength = 2_000
    static func note(title: String?, caption: String?, creator: String?) -> String?
}
```

Applied through `TagStore.setNote` semantics but at the batch layer: the run's
`queue.write` reads the existing note via `NoteStore.read` (`NoteStore.swift:17`)
and **writes only when none exists** (the `ratingToApply` fill-gaps shape,
`MetadataImportRules.swift:48` — an import never overwrites what the user typed in
Muse; re-runs are no-ops). Written via `NoteStore.write` (:25) inside the same
transaction as the file's tag writes; sidecar export rides the existing
end-of-run `exportSidecarsAfterTagEdit` call (`MetadataImportModel.swift:106`) —
which is the **non-authoritative** note path (`noteAuthoritative` defaults false,
`AnalyzePipeline.swift:340,379`), correct here: an import must not clobber a note
another device wrote (`Sidecar.resolveForWrite` keeps `existing.note`).

### 2.4 `Import/ImportSupplement.swift` — GPS/dates into the Spec 02 columns

One writer shared by the universal layer (XMP GPS), Takeout (§7), and Apple Photos
(§6). It exists because three sources produce **externally-sourced** values for
columns whose normal producer is the file header — and the two must merge without
either clobbering the other:

```swift
nonisolated enum ImportSupplement {
    struct External: Equatable, Sendable {
        var lat: Double? = nil
        var lon: Double? = nil
        var captureDate: Int64? = nil     // epoch seconds
        var description: String? = nil    // NOT written here — callers route to notes (§2.3)
        var isEmpty: Bool
    }
    /// Inside the caller's queue.write. Reads the file's own header via
    /// PhotoHeaderReader (Spec 02), merges HEADER-WINS / external-fills-gaps
    /// per field, writes files.lat/lon + the photo_meta row, and stamps BOTH
    /// markers (coords_scanned_hash + exif_scanned_hash = content_hash).
    /// Returns which external fields actually landed (for the report).
    /// Row-guarded on content_hash still matching (the analyzeOne shape).
    static func apply(db: GRDB.Database, fileID: String, contentHash: String,
                      header: PhotoHeader, external: External) throws -> AppliedFields
}
```

Rules, all binding:

- **Header wins per field; external fills NULLs.** File bytes are the stronger
  provenance; Takeout exists precisely because Google strips the file, so its JSON
  fills what the header lacks. `capture_md` derives from whichever `capture_date`
  won (same-parse rule, Spec 02 §1.2).
- **Both markers stamp `content_hash`** — the supplement IS a completed header scan
  (it read the header). This keeps the launch `PhotoHeaderBackfill` from re-visiting
  the file and overwriting the merged row with header-only values.
- **Spec 02 amendment A1 (deviation D3):** `AnalyzePipeline.analyzeOne`'s
  photo_meta/coords write and `PhotoHeaderBackfill`'s per-row write both gain a
  **skip-when-fresh guard** — when `coords_scanned_hash == content_hash AND
  photo_meta.exif_scanned_hash == content_hash`, don't rewrite the row. Without
  this, the first analyze pass after an import would clobber every supplement-filled
  field with header NULLs. (Semantics preserved: an edit-in-place changes
  `content_hash`, both markers go stale, and the header is re-read — supplement
  values are lost on content edit and restored by re-running the import; **recorded
  limitation**, consistent with "derived data recomputes locally".)
- The `(0, 0)` coordinate is treated as absent (§7.1 — Takeout writes 0.0 for
  no-GPS; a real null-island photo is sacrificed, recorded).
- Sidecars stay out of it: `photo_meta`/`places` carry nothing in sidecars
  (DECISIONS data-grain rule, unchanged).

After any run that applied supplements: `GeocodeBackfill.run()` then
`SearchFacets.shared.refresh()` chain fire-and-forget (the Spec 02 completion
pattern) — newly-located photos become `near:`-searchable without waiting for a
relaunch.

### 2.5 The extended folder run — `Import/MetadataImportModel.swift`

The shipped orchestration (`MetadataImportModel.start`, :29-111) keeps its skeleton
— enumerate recursive → `Indexer.shared.indexBatch(pairs, priority: .high)` →
per-file read off-main → apply in `queue.write` → end-of-run sidecar export +
`tagsVersion += 1` — and grows four legs per file, in this order inside the
existing per-file transaction:

1. keywords (unchanged, `MetadataImportApply.applyKeywords` :43 — rating-glyph
   labels still dropped),
2. rating (unchanged, gap-fill via `hasRating`/`ratingToApply`, written through the
   one `TagStore.setRating` seam :244 after the transaction),
3. note (§2.3, fill-gaps),
4. supplement (§2.4, when `extracted.coordinate != nil` — the date leg is
   header-only here, so `External` carries just the GPS),
5. label **accumulation** (not application — `labelPaths[label, default: []]
   .append(absPath)`; applied after the scan, §3.3),
6. LR edit import when the toggle is on and Spec 04 is built (§4.5).

Progress/summary UI: `Import/ImportRunCard.swift` **replaces**
`MetadataImportSheet.swift` (same phases `running/done`, same cancel-on-dismiss,
same `ModalScroll` + `ModalButton` construction — verbatim port plus: a "Also
import Lightroom adjustments (approximated)" `Toggle` shown pre-scan when Spec 04
is present, persisted as `AppSettings.importLREditsKey` default **true**; and the
done-phase now sets `importModal = .report(report)` instead of rendering its own
counts). The entry point (`AppState.importKeywordsAndRatings`,
`AppState+Import.swift:29`) keeps its panel, its add-root-if-uncovered logic
(trailing-slash containment rule), and gets renamed `importMetadataAndEdits()`;
the panel message is updated to mention adjustments.

---

## 3. Color labels — the mapping sheet (DECIDED #12)

### 3.1 `Import/LabelTag.swift` — the namespace + the search exclusion (pure)

```swift
nonisolated enum LabelTag {
    static let prefix = "Label: "                    // canonical storage prefix, English (storage rule)
    static func isLabel(_ tagLabel: String) -> Bool  // hasPrefix(prefix)
    static func make(_ value: String) -> String      // "Label: " + trimmed value
    /// A free-text search matches label tags ONLY when the user is asking for
    /// them: the query (lowercased, trimmed) contains "label". Otherwise the
    /// tag-search leg must not see them — typing "red" must never surface a
    /// photo whose only redness is a workflow marker (the semantic collision
    /// DECIDED #12 exists to prevent).
    static func queryTargetsLabels(_ query: String) -> Bool
}
```

**Search integration** — `Database/SearchService.swift` tag leg (:101-108): after
`tagRows` are fetched, drop rows where `LabelTag.isLabel(row.label)` unless
`LabelTag.queryTargetsLabels(textQuery)`. One filter line, one pure helper, pinned
by test (§13): query "red" does not match a file tagged `Label: Red`; query
"label: red" does. Everything else about label tags is a plain manual tag on
purpose — they appear in the chips row (filterable), in `allTagLabels`, in smart
`.tag` rules, they carry per-location scope, delete/rename work (rename is the
user re-deciding the mapping — allowed). The `.tag` smart-rule and chip-click
filter paths are exact-label matches, not content-flavored search — no exclusion
there.

**Chip styling:** `TagChipsRow` renders label chips visually distinct — outline
stroke instead of fill + a `tag` SF-Symbol glyph before the text (branch on
`LabelTag.isLabel`; shared with the active-filter bar rendering). Display shows the
full stored label (`Label: Red`) — the prefix IS the affordance; no display-time
truncation.

### 3.2 `Import/LabelMapping.swift` — choices + persistence (pure core)

```swift
nonisolated enum LabelMapping {
    enum Choice: Equatable, Codable {
        case skip
        case namespaced                  // → LabelTag.make(value)
        case tag(String)                 // → the user's chosen existing/typed tag label
    }
    /// Resolved tag label for a source value under a choice; nil for .skip.
    /// .tag values pass through StarRating-glyph rejection (a mapping target
    /// that is a ★-run is refused at the sheet, §3.3 — enforced here too,
    /// returning nil, so no future caller can bypass it).
    static func resolvedLabel(value: String, choice: Choice) -> String?

    /// Remembered choices, keyed by the RAW source string (deviation D7 —
    /// LR localizes label names, so "Red" and "Rouge" are distinct keys; a
    /// remembered "Rouge" mapping is exactly what a French-LR user wants).
    /// UserDefaults JSON blob under AppSettings.importLabelChoicesKey.
    static func loadChoices() -> [String: Choice]
    static func saveChoices(_ c: [String: Choice])
}
```

### 3.3 The sheet flow (`Import/LabelMappingCard.swift` + model glue)

- During the scan the run model accumulates `labelPaths: [String: [String]]`
  (distinct raw `xmp:Label` value → alive paths). Memory: only labeled files, a
  string per — fine at 100k (no-RAM-residency rule honored: paths, not file data).
- Scan done → if `labelPaths` is empty, straight to apply/report. If every distinct
  value already has a remembered choice, **apply silently** (the "remember choice"
  point — the second import is ceremony-free). Otherwise
  `importModal = .labelMapping(LabelMappingRequest(values:…, counts:…))`.
- The card lists each value with its count and a three-way control (Skip /
  `Label: X` / Map to tag…). "Map to tag" opens the existing tag-autocomplete
  affordance (the `TagSuggest.rank` pool — which already excludes rating glyphs at
  the ranker, so the sheet inherits the guard; a hand-typed ★-run is refused with
  the same inline treatment the hero's create-tag field uses). Default selection
  per value: remembered choice, else `.namespaced` (the safe, collision-proof
  default). **Apply** persists choices via `saveChoices` and continues; **Skip All**
  applies `.skip` to this run without persisting.
- Application: per label value with a non-skip choice, one `queue.write` chunk over
  its paths — resolve scope via `MetadataImportApply.scope` (:25), write via
  `MetadataImportApply.applyKeywords` (insert-or-promote manual, :43) with the
  resolved label. Counts land in `report.labelCounts`.
- No VisionVocabulary rows (user words, verbatim — the keywords rule,
  `MetadataImportRules.swift:16-19` comment, applies).

---

## 4. Lightroom edit import — crs: → badged approximated `EditStack`s

### 4.1 `Import/LightroomXMP.swift` — the parser (pure over `CGImageMetadata`)

```swift
nonisolated struct LightroomEdits: Equatable, Sendable {
    // Geometry (EXACT tier)
    var hasCrop: Bool = false
    var cropLeft: Double?; var cropTop: Double?; var cropRight: Double?; var cropBottom: Double?
    var cropAngle: Double?                 // degrees
    var orientation: Int?                  // tiff:Orientation 1…8 from the same metadata
    // WB
    var temperatureKelvin: Double?         // crs:Temperature (RAW workflows)
    var tint: Double?                      // crs:Tint (RAW, ±150-ish)
    var incrementalTemperature: Double?    // crs:IncrementalTemperature (encoded, −100…100)
    var incrementalTint: Double?
    // Tone/color (DIRECTIONAL tier — PV2012 keys only; key presence IS the gate)
    var exposure2012: Double?              // EV
    var contrast2012: Double?              // −100…100
    var vibrance: Double?                  // −100…100
    var saturation: Double?                // −100…100
    // Curves (PORTABLE-AS-CURVES tier)
    var toneCurvePV2012: [CGPoint] = []    // 0…255 coordinate pairs, parsed from "x, y" strings
    var toneCurveRed: [CGPoint] = []
    var toneCurveGreen: [CGPoint] = []
    var toneCurveBlue: [CGPoint] = []
    // Disclosure (§4.2) — present-but-untranslatable keys found on this file
    var unsupported: Set<String> = []      // display names: "Highlights", "Clarity", "Dehaze", …
    var isEmpty: Bool
}

nonisolated enum LightroomXMP {
    /// From the SAME CGImageMetadata the keyword reader already resolved
    /// (sidecar-first) — zero extra I/O; the run hands it through.
    static func read(_ meta: CGImageMetadata) -> LightroomEdits
}
```

- All values via `CGImageMetadataCopyTagWithPath` with `crs:`-prefixed paths
  (Adobe's namespace is registered with ImageIO; the exiv2/adobe crs docs in
  foundation §15 are the field reference). Numeric strings like `"+0.85"` parse
  with an explicit `+`-tolerant Double parse.
- **The unsupported set is enumerated, not open-ended** — one named constant list:
  `Highlights2012, Shadows2012, Whites2012, Blacks2012, Clarity2012, Texture,
  Dehaze, GrainAmount, PostCropVignetteAmount, MaskGroupBasedCorrections (any),
  RetouchAreas (any), LookName (non-empty)` → mapped to localized display names for
  the report. This is the industry envelope made auditable: the report says exactly
  what was on the file and not translated (pre-spec acceptance: "unsupported
  sliders untouched and disclosed").
- PV gate: **presence of the `2012`-suffixed keys is the gate** — no
  `crs:ProcessVersion` parsing (older PV2010 files simply have none of the imported
  keys and yield geometry-only stacks; their old-PV tone keys land in
  `unsupported` display as "Legacy process version" when `crs:ProcessVersion`
  exists but no 2012 keys do).

### 4.2 The envelope (restated as code boundaries, from foundation §7 / DECIDED #11)

Imported: crop/angle/orientation (exact) · WB (directional) · Exposure2012
(≈ fraction of a stop) · Contrast2012 · Vibrance · Saturation · point tone curves
(with the base-look caveat surfaced in UI). **Never imported** (parse-detected only
for disclosure): the adaptive operators listed above. Matching the envelope is
defensible; exceeding it is not — this list may not grow without a foundation-doc
change.

### 4.3 `Import/LightroomEditMapper.swift` — crs → `EditStack` (pure, tested)

```swift
nonisolated enum LightroomEditMapper {
    struct Context {
        var isRAW: Bool
        /// As-shot neutral Kelvin from CIRAWFilter, resolved by the run for RAW
        /// files carrying crs:Temperature (§4.5); nil → temperature not mapped.
        var asShotKelvin: Double?
        var asShotTint: Double?
    }
    /// nil when the result would be neutral (nothing worth writing).
    static func map(_ lr: LightroomEdits, context: Context) -> EditStack?

    // Named conversion constants — single declaration site (house rule):
    static let lrContrastScale = 100.0     // Contrast2012 / 100 → ColorParams-range −1…+1
    static let lrVibranceScale = 100.0
    static let lrSaturationScale = 100.0
    static let lrIncrementalWBScale = 100.0
    static let lrTintScale = 150.0         // crs:Tint ±150 → tint slider ±1 (directional)
    static let curveDomain = 255.0
}
```

Mappings, exactly:

- **Geometry** — `GeometryParams.crop = CropRect(x: cropLeft, y: cropTop,
  w: cropRight−cropLeft, h: cropBottom−cropTop)` when `hasCrop` (values are already
  normalized 0…1); `straightenDegrees = −cropAngle` (sign verified against fixture
  renders — owner step §15, the fixture test pins whichever sign survives);
  `quarterTurns`/`flipH`/`flipV` from `orientation` via a pure EXIF-orientation →
  (turns, flips) table (`orientationToGeometry(_:)`, tested for all 8). LR crop
  coordinates are expressed in the oriented frame — the same frame
  `GeometryParams` uses (Spec 04 §1.1); the fixture render comparison (§15) is the
  proof, not an assumption.
- **Exposure** — `ToneParams.exposureEV = clamp(exposure2012, −5…+5)` (both are
  real EV; the one direct-units transfer).
- **Contrast / Vibrance / Saturation** — `value / scale`, clamped −1…+1.
- **WB, encoded sources** — `ColorParams.temperature = incrementalTemperature /
  lrIncrementalWBScale`, `tint = incrementalTint / lrIncrementalWBScale` (both
  directional approximations, clamped).
- **WB, RAW** — requires `asShotKelvin`: `ColorParams.temperature =
  clamp((mired(temperatureKelvin) − mired(asShotKelvin)) /
  TemperatureMap.miredPerUnit, −1…+1)` where `TemperatureMap.miredPerUnit` is **the
  renderer's own constant** (Spec 04 §4.4's mired mapping, hoisted to a named
  constant in `Editing/Render/` — one declaration site shared by renderer and
  importer, so the imported number means what the slider means).
  `tint = clamp((tint − asShotTint) / lrTintScale, −1…+1)`. Context without
  `asShotKelvin` → temperature/tint skipped (recorded in the report notice).
- **Curves** — points `/curveDomain` → `CurveParams` unit points; identity curves
  (`(0,0),(255,255)` ± ε) → empty; > `CurveParams.maxPoints` (16) → endpoints kept,
  interior evenly subsampled (recorded in the report notice — LR's default curves
  are well under 16).
- Output stack: `EditStack.fresh()` + the mapped groups, `normalized()`,
  `origin = .lightroom` (§4.4). `rawParams` stays nil — the importer never pins a
  decoder version; first *user* edit does (Spec 04 §1.1 rule untouched).

### 4.4 Provenance — `EditStack.origin` (deviation D2)

```swift
// Editing/EditStack.swift — one added optional field
nonisolated enum EditOrigin: String, Codable, Sendable { case lightroom }
// EditStack gains:
var origin: EditOrigin? = nil
```

- **Hash-stability is preserved:** synthesized Codable omits nil optionals, so every
  existing stack's canonical `.sortedKeys` bytes — and therefore `stack_hash` and
  every edited-thumbnail cache key — are byte-identical. The pinned
  `EditStackCodecTests` fixture hash **must not change**; a second pinned fixture
  WITH origin is added (§13). Older (Spec 04-only) builds decode a stack carrying
  `origin` fine (synthesized decoders ignore unknown keys) and drop it on re-save —
  badge lost, edits intact; acceptable.
- Rides sidecars for free (the stack JSON is the sidecar field), so the badge syncs.
- **Never transfers:** `EditTransfer.apply` output keeps the TARGET's origin
  (copying adjustments from an imported photo doesn't make yours "approximated");
  preset save (§7.4 Spec 04) strips origin along with geometry. Reset deletes the
  row → badge gone (a neutral imported stack is never written in the first place —
  `map` returns nil).
- UI: the editor shows a small "Approximated from Lightroom" badge line in the
  Light tab header + the hero INFO card when `stack.origin == .lightroom`
  (localized; `Theme`-styled). The stack is otherwise a perfectly ordinary stack —
  every slider live, every consumer unchanged.

### 4.5 The apply path (inside the §2.5 run)

Per file, after the metadata legs, when the LR toggle is on AND Spec 04 is present:

1. `LightroomXMP.read` on the already-resolved metadata (sidecar-priority — LR's
   sidecar is the truth for RAW; embedded XMP covers DNG/JPEG workflows).
2. `lr.isEmpty` → skip. Existing Muse edit for this `(file, parent_dir)`
   (`EditRecordStore.read` non-nil) → **skip and count `editsSkippedExisting`** —
   an import never clobbers user edits (the `NoteStore.carry` INSERT-OR-IGNORE
   philosophy at the feature level). Re-runs are therefore idempotent: the first
   import wrote a stack, the second sees it and skips.
3. RAW with `temperatureKelvin` present: resolve `asShotKelvin/asShotTint` via
   `CIRAWFilter(imageURL:)` neutral properties, **off-main, budget-gated** — this
   is a header-scale RAW init, not a decode, but it is the run's most expensive
   per-file step; it happens only for RAW files whose sidecar actually moves WB.
4. `LightroomEditMapper.map` → non-nil → `EditStore.shared.save(stack, for: url)`
   — the full Spec 04 §3.5 save sequence per file (row write, provider index,
   `markContentChanged`, `generation += 1`, sidecar export). Sequential like the
   batch-sync sweep (Spec 04 §7.3); tiles refresh as it progresses; no progress UI
   beyond the run card's counter (the status pill stays background-work-only).
5. `unsupported` merges into `report.unsupportedSliders`.

### 4.6 One-click compare against the embedded rendered preview

The pre-spec's check on the approximation. Delivery: the Spec 04 **before/after
suite** (compare against "Original or any snapshot") gains one more source,
**"Lightroom preview"**, offered when `stack.origin == .lightroom` AND the file has
an embedded preview:

- `Import/EmbeddedPreview.swift`: `static func image(for url: URL, maxPixel: Int)
  -> CGImage?` — `CGImageSourceCreateThumbnailAtIndex` with
  `kCGImageSourceCreateThumbnailFromImageIfAbsent: false` (embedded preview ONLY —
  never a decode of the primary image; RAW files carry Adobe-rendered previews,
  JPEGs typically return nil and the source simply isn't offered), through
  `withinDecodeBudget` first (a hostile header can't OOM the compare).
- Rendered into the compare's cached-texture slot exactly like a snapshot render;
  the wipe/side-by-side machinery is untouched.
- The caveat line ("Lightroom's base look is not applied — results shift",
  foundation §7) renders under the compare picker when this source is active.

---

## 5. Lightroom preset (.xmp) import → `edit_presets`

The Spec 05 deferral lands here, nearly free on §4's parser:

- Menu item → `NSOpenPanel`, `.xmp` files, multi-select →
  `importModal = .lightroomPresets(urls)` → run card.
- Per file: `CGImageMetadataCreateFromXMPData` → `LightroomXMP.read` →
  `LightroomEditMapper.map(context: Context(isRAW: false, asShotKelvin: nil …))`
  — presets are absolute recipes with no as-shot reference: `crs:Temperature`
  in a preset (rare; most presets store incremental or no WB) is unmappable and
  lands in the notice; incremental WB maps normally.
- Non-nil stack → strip geometry (presets never carry crops — Spec 04 §7.4 rule)
  → `origin = .lightroom` → insert `EditPresetRow` named from `crs:Name` (Alt,
  first) else the filename stem, via `EditPresetStore` (Spec 04 §7.4). Name
  collisions get the ` 2` suffix ladder (NOCASE — no UNIQUE constraint exists,
  the ladder is courtesy).
- Per-file failures surface by filename in the report (`LutStore.importCubes`
  pattern); the Looks tab shows imported presets like any user preset, live-thumbed
  by the Spec 05 browser. Applying one is the standard copy-by-value
  `EditTransfer.apply` — DECIDED #9/#10 satisfied with zero new machinery.

---

## 6. Apple Photos import

### 6.1 Access (target changes)

- Entitlement `com.apple.security.personal-information.photos-library` added to
  **both** `Muse.entitlements` and `Muse-Debug.entitlements`; `NSPhotoLibraryUsageDescription`
  added to Info.plist (localized: "Muse reads your Photos library only to copy the
  photos you choose into a folder you choose.").
- `PHPhotoLibrary.requestAuthorization(for: .readWrite)` (PhotoKit has no read-only
  level that grants asset reads; `.readWrite` is the read level — stated in the
  card's privacy note). `.limited` selection works transparently (we enumerate what
  we're given).
- **Network doctrine note (recorded, not a new path):** PhotoKit may pull
  iCloud-Photos originals when `isNetworkAccessAllowed = true` — OS-mediated
  system traffic in the same class as StoreKit and `bird` (DECISIONS network
  doctrine: OS-level, not an app network path). The app itself opens no
  connection.

### 6.2 The flow — `Import/ApplePhotosImportModel.swift` + `ApplePhotosImportCard`

Options card (pre-run form): destination folder picker (required; added as a root
if uncovered — the `importKeywordsAndRatings` add-root rule verbatim) · "Recreate
albums as collections" toggle (default on) · favorites handling picker: **tag
`Favorite` / skip** (default tag — deviation D4: Photos' favorite is a binary
flag; mapping it to any star count would fabricate a rating the user never gave,
and rating-glyph writes outside `setRating` are forbidden anyway; a manual tag is
the honest translation and instantly filterable) · people-keywords note (§6.3).

Run, per `PHAsset` (`.image` + `.video`, fetched newest-first, cancellable):

1. **Export current version** — images: `PHImageManager.requestImageDataAndOrientation`
   (`version: .current`, `isNetworkAccessAllowed: true`, synchronous inside the
   worker) → bytes + UTI → filename from `PHAssetResource.originalFilename`
   (extension corrected to match the returned UTI when Photos rendered an edit into
   a different container), collision ladder ` 2`, ` 3`… (case-insensitive) →
   atomic write into the destination. Videos: `PHAssetResourceManager` streaming
   the `.fullSizeVideo` (edited/rendered) resource when present, else `.video`.
2. **Index deterministically** — batch the written URLs through
   `Indexer.shared.indexBatch(pairs, priority: .high)` every 50 files (the
   Edit-a-Copy "never wait for FSEvents" rule).
3. **Supplement** — `ImportSupplement.apply` with
   `External(lat/lon: asset.location?.coordinate, captureDate:
   asset.creationDate)` — rendered exports usually embed EXIF (header wins);
   the supplement covers the ones Photos stripped.
4. **Favorite** → per the option, `MetadataImportApply.applyKeywords` with
   `["Favorite"]` (canonical English storage; localized at display via the normal
   tag display path — no VisionVocabulary row, user-word rule).
5. **Albums → collections** (toggle on): enumerate `PHAssetCollection` user albums
   containing imported assets; per album, find-or-create a manual collection by
   case-insensitive name (the `confirmNewCollection` matching rule;
   `CollectionStore.createManual(queue:name:fileID:)`
   `CollectionStore.swift:140` for the first member, `addFile` :92 for the rest —
   `added_by: 'manual'`, protected from the reclusterer). Smart albums are skipped
   (saved searches, the Eagle smart-folder rule).
6. Analysis is NOT triggered inline — the normal automatic pipeline picks the new
   files up (import instant, analysis background — DECIDED #22), and the FYI (§9)
   fires if the batch is big.

Idempotency: a destination file whose name already exists is skipped and counted
(re-running completes a cancelled import without duplicating).

### 6.3 Stated plainly (report notices, fixed strings)

- "Apple Photos edits are applied to the imported image; the individual adjustments
  can't be recovered (private format)." — the pre-spec's required message, shown on
  the options card AND in the report.
- "Keywords assigned in Photos aren't available to other apps and were not
  imported." — PhotoKit exposes no keyword API (deviation D5 against the pre-spec's
  optimistic "keywords" mention; verified at build time — if a supported path
  exists on the deployment floor, this notice is replaced by the import).

---

## 7. Google Takeout import

### 7.1 `Import/TakeoutJSON.swift` — parser + matcher (pure, heavily tested)

```swift
nonisolated struct TakeoutMeta: Equatable, Sendable {
    var photoTakenTime: Int64?         // .photoTakenTime.timestamp (string epoch!)
    var lat: Double?                   // .geoData.latitude — 0.0 ⇒ absent (with lon)
    var lon: Double?                   //  falls back to .geoDataExif
    var description: String?           // .description, trimmed, empty ⇒ nil
    var favorited: Bool = false        // .favorited
    var people: [String] = []          // .people[].name
}
nonisolated enum TakeoutJSON {
    static func parse(_ data: Data) -> TakeoutMeta?    // JSONSerialization, tolerant

    /// The filename-quirk ladder (pre-spec: "known filename quirks"), best-first:
    ///  1. "<name>.<ext>.supplemental-metadata.json"   (current Takeout)
    ///  2. "<name>.<ext>.json"                          (older Takeout)
    ///  3. duplicate-counter swap: "IMG(1).jpg" → "IMG.jpg(1).json" (both suffixes)
    ///  4. edited-suffix strip: "IMG-edited.jpg" → IMG.jpg's candidates
    ///     (localized variants "-bearbeitet"/"-modifié"/… via a suffix list constant)
    ///  5. 46-char truncation: Takeout truncates the json's base name — candidates
    ///     re-derived from the truncated stem
    static func jsonCandidates(for mediaName: String) -> [String]
}
```

Each rule is pinned by its own test case; the ladder returns candidates in order
and the run takes the first that exists beside the file. `(0,0)` → nil coordinate
(§2.4 rule, applied at parse).

### 7.2 The flow — `Import/TakeoutImportModel.swift` + card

Input: the user's extracted Takeout folder (NSOpenPanel, directories; the folder is
added as a root if uncovered — Takeout output IS the photo pool; **files are
imported in place, not copied** — they're already ordinary files on disk, and the
no-catalog story means Muse just references them where they live). Options: people
names → **plain tags / skip** picker, default **skip** (pre-spec: "user choice;
NOT face identities" — a `People: ` namespace was considered and rejected: these
are Google's labels, not Muse taxonomy; plain tags or nothing).

Run: enumerate recursive (media kinds) → `indexBatch` → per file: match JSON via
the ladder → parse → apply in one `queue.write`:

- supplement (`ImportSupplement.apply`: `photoTakenTime` + geo — the acceptance
  case "dates/GPS restored to files that lack them" lands here, header-wins as
  always),
- `description` → note (fill-gaps, §2.3 — `ImportedText.note(title: nil,
  caption: description, creator: nil)`),
- `favorited` → `Favorite` manual tag (same translation as §6.2, consistency over
  configurability — one toggle governs both flows' favorites? No: each card has
  its own picker, both defaulting sensibly; remembered per-card in UserDefaults),
- people → per the option, `applyKeywords` with the names (rating-glyph filter
  inherited).
- `-edited` siblings: both the edited and original files are ordinary library
  files (they're both on disk); the edited one matches the original's JSON via
  ladder rule 4 — both get the metadata. No stacking in v1 (Spec 02's manual
  stacking can group them by hand; auto-pairing is a recorded non-goal).

Report: counts + notice "Google Photos edits are already baked into the edited
files; originals are unmodified."

---

## 8. Eagle library import

Per the approved design (`docs/future-features/eagle-library-import.md`) with two
updates for code that has shipped since it was written: **annotations now import**
(→ notes — the doc's "Muse has no field" reason expired with Polish 21; deviation
D1) and the report/card/localization boilerplate follows this spec's shared
machinery instead of the old sheet rules.

### 8.1 `Import/EagleLibrary.swift` — reader (pure over the package layout)

```swift
nonisolated struct EagleItem: Equatable, Sendable {
    var id: String                    // the .info directory name
    var fileURL: URL                  // the original file inside it
    var name: String                  // metadata.json "name" + "ext"
    var tags: [String] = []
    var star: Int?                    // 1…5, normalized via MetadataImportRules.normalizeRating
    var annotation: String?
    var folderIDs: [String] = []
}
nonisolated struct EagleFolder: Equatable, Sendable {
    var id: String; var name: String; var childIDs: [String]
}
nonisolated enum EagleLibrary {
    /// Parses <lib>.library: per-item images/<id>.info/metadata.json + the root
    /// metadata.json folder tree. Tolerant per item (a corrupt item is skipped
    /// + counted, never fails the run).
    static func read(at libraryURL: URL) throws -> (items: [EagleItem], folders: [EagleFolder])
    /// Nested folders flatten to "Parent – Child" (Muse collections are flat).
    static func flattenedNames(_ folders: [EagleFolder]) -> [String: String]  // folderID → name
}
```

**Verification-first (owner step §15, binding):** the format description is from
training knowledge — the doc itself says "step 1 of any build is creating a scratch
library with the real Eagle app and confirming this." The parser is written against
the scratch library's actual JSON; field names above are the starting hypothesis,
and the fixture in `MuseTests` is a (miniaturized) real library.

### 8.2 The flow — `Import/EagleImportModel.swift` + card

Panel 1: the `.library` package (`canChooseDirectories` — a `.library` is a
directory; message per the doc). Panel 2: destination folder (added as root if
uncovered). Then, per the approved sequencing (copy → index → apply):

1. **Copy once, flat** into the destination via `FileManager.copyItem` (not
   `FileMover.move` — the source library is read-only by contract). Name collision
   with a *different* item → ` 2` ladder; destination file already present with the
   item's name → **skip + count** (the doc's idempotency rule).
2. `indexBatch` the copied URLs (every 50).
3. Apply per item in `queue.write` chunks: tags → `applyKeywords` (manual tier);
   star → the `hasRating`/`ratingToApply` gap-fill + `TagStore.setRating`;
   annotation → note (fill-gaps, §2.3); folder memberships → find-or-create manual
   collections by flattened name (the §6.2 album seam — one image in three Eagle
   folders = one file in three collections, never copies).
4. Dropped, per the approved design: URLs, smart folders, Eagle palette data.

Report: "214 imported, 2 skipped" register + collections created + tags/ratings/
notes counts.

---

## 9. Import-size FYI + analysis throttling (DECIDED #22/#23)

### 9.1 `Components/ThrottlePolicy.swift` — pure policy

```swift
nonisolated enum ThrottlePolicy {
    enum Mode: Equatable { case normal, reduced, paused }
    /// userPaused or thermal .serious/.critical → .paused
    /// else onBattery OR lowPower            → .reduced
    /// else                                   → .normal
    static func mode(thermal: ProcessInfo.ThermalState,
                     onBattery: Bool, lowPower: Bool, userPaused: Bool) -> Mode
    /// .normal → AnalyzePipeline.analyzeConcurrency (3) · .reduced → 1 · .paused → 0
    static func concurrency(_ m: Mode) -> Int
}
```

### 9.2 `Models/WorkThrottleStore.swift` — Pattern B monitor

`@MainActor final class WorkThrottleStore: ObservableObject`, `static let shared`:

- `@Published private(set) var mode: ThrottlePolicy.Mode` — recomputed from:
  `ProcessInfo.thermalStateDidChangeNotification`,
  `NSNotification.Name.NSProcessInfoPowerStateDidChange` (Low Power Mode),
  battery vs AC via IOKit power sources
  (`IOPSCopyPowerSourcesInfo`/`IOPSGetProvidingPowerSourceType`, re-read on
  `IOPSNotificationCreateRunLoopSource` callbacks — public IOKit.ps API, sandbox-
  clean, no entitlement), and the user flag.
- `var userPaused: Bool` — persisted (`AppSettings.analysisPausedKey`, default
  false): a pause survives relaunch (deviation D10 — "pausable" that silently
  un-pauses on relaunch reads as broken; resuming is one visible click in two
  surfaces). **This is not an analysis off switch**: nothing is skipped or marked,
  no data path changes — work holds and resumes exactly where the markers say.
  DECIDED #22's "no off switch" is honored because pause changes *when*, never
  *whether*.
- `func waitUntilRunnable() async` — suspends while `.paused` (AsyncStream over
  `$mode` values; cancellation-safe — a cancelled awaiter just returns and the
  caller's own `shouldStop`/`Task.isCancelled` checks do their normal job).
- Zero AppState integration (not even a forwarded cancellable — the only consumers
  are the pipeline, the backfills, and the two §9.4 surfaces, which observe the
  store directly).

### 9.3 Consumers — the spawn gates

- **`AnalyzePipeline.analyze(folder:)`** (the loop at
  `AnalyzePipeline.swift:289-314`): both spawn sites (the priming `while` and the
  one-replacement-per-completion) gate on
  `await WorkThrottleStore.shared.waitUntilRunnable()` **before** `iterator.next()`,
  and the priming width becomes
  `ThrottlePolicy.concurrency(mode)` re-read per spawn — under `.reduced` the
  window naturally drains to 1 as completions outpace replacements; under
  `.paused` no new file starts and in-flight files finish (exactly the
  `shouldStop` semantics, but resumable). The pass-claim (`acquirePass`) is
  **held across a pause** — a paused pass is still the active pass; cancel still
  works on it.
- **`PhotoHeaderBackfill` / `GeocodeBackfill` / `DeepAnalysisBackfill`
  (Spec 02/03)**: one `waitUntilRunnable()` per selection chunk (their write-chunk
  loops already checkpoint every 200 rows). Their `.utility` priority is
  unchanged — the throttle is additive to the existing posture (DECISIONS:
  "battery/thermal-aware pausing is Spec 06's work", now done).
- The **import runs themselves are NOT throttled** — they are foreground,
  user-initiated, card-visible work with a Cancel button; pausing them would look
  like a hang.

### 9.4 Progress + pause/resume surfaces

**`Models/AnalysisStatusStore.swift`** (Pattern B):

```swift
@MainActor final class AnalysisStatusStore: ObservableObject {
    static let shared = AnalysisStatusStore()
    @Published private(set) var analyzableTotal = 0     // alive image/raw/psd files
    @Published private(set) var pending = 0             // analyzed_hash NULL or ≠ content_hash
    private(set) var secondsPerFile: Double?            // EMA, α = 0.1 — not @Published (no UI per tick)
    func refresh()                                      // one off-main count query, ≤ 1 per 5 s, token-guarded
    func recordCompletion(duration: TimeInterval)       // called by analyzeOne per file
    var estimateSeconds: TimeInterval?                  // AnalysisEstimator.estimate(pending, secondsPerFile)
}
```

`refresh()` triggers: end of every index batch, every analyze-pass completion, and
each 200-row backfill chunk — fire-and-forget, single flight.

- **Settings** gains a **Library** section row: "34,000 of 100,000 analyzed"
  (`analyzableTotal − pending` of `analyzableTotal`, monospacedDigit) + a
  Pause/Resume button bound to `WorkThrottleStore.userPaused` + a `.secondary`
  state line ("Paused" / "Reduced speed on battery" / estimate when running and
  calibrated). Copy note per foundation: "Photos are ready to browse now — search
  and colors get smarter as analysis finishes."
- **Sidebar footer row** (in `SidebarView` above the `CreateNewMenuButton` at
  `SidebarView.swift:626`): visible only while `pending > 0 AND (a pass is running
  OR userPaused)` — a one-line count + a `pause.circle`/`play.circle` icon button
  (with `.help` + `.accessibilityLabel`). Shared geometry constants; observes the
  two stores directly (zero AppState cost). **The status pill is untouched** — its
  background-work-only rule and phase inputs don't change; this row is the
  *findable* long-horizon surface, the pill remains the transient one.

### 9.5 `Components/AnalysisEstimator.swift` + the FYI card (DECIDED #23, exact)

```swift
nonisolated enum AnalysisEstimator {
    static let calibrationMinimum = 200          // completions before an estimate exists
    static let fyiThresholdSeconds: TimeInterval = 25 * 60   // "~20–30 min" → 25, owner-tunable
    static func estimate(pending: Int, secondsPerFile: Double?,
                         completions: Int) -> TimeInterval?  // nil until calibrated
    static func shouldOffer(estimate: TimeInterval?) -> Bool // estimate > threshold
}
```

- **Measured on-device, never hardcoded** (#23): `secondsPerFile` is the EMA over
  this machine's actual `analyzeOne` completions this launch; the estimate exists
  only after `calibrationMinimum` completions (the foundation's "analyze first
  ~200 files, measure, extrapolate" — the first 200 of the batch ARE the sample).
- **Trigger:** after each `refresh()`, when (a) an estimate exists, (b)
  `shouldOffer`, (c) the FYI hasn't been shown this launch (`shownThisLaunch`
  flag), and (d) pending grew by ≥ `calibrationMinimum` since launch (a stable
  backlog that was already there at launch doesn't re-nag) — raise the card.
- **The card** (via the `MuseAlert`/`alertRequest` seam — `ModalMessageCard`, one
  button "OK", registered in `modalPresented` through the existing alertRequest
  presenter): *"Heads up: analyzing 40,000 photos will take about 2 hours. They're
  ready to browse now — search and colors get smarter as it finishes."* — count and
  duration interpolated (duration via `DateComponentsFormatter` approximation,
  "about 2 hours" register), fully localized. One button, FYI only — **no choice,
  no skip, no off switch** (#22). Below threshold: nothing, ever (silent).

---

## 10. What Spec 06 explicitly does NOT change

- `MetadataImportRules` semantics (normalize/clamp/gap-fill) — extended callers,
  identical functions; the NaN-trap clamp comment stands.
- `MetadataImportApply` — same two writers, reused by every source; the
  rating-glyph drop is inherited by labels, people-tags, Eagle tags, and the
  Favorite tag by construction.
- The analyze pass's semantics: no new analysis, no skipped analysis, no new
  toggles. Throttle changes *scheduling* only; `analyzed_hash`/marker semantics
  untouched.
- The status pill (`WorkProgress`) — inputs, shares, idle-grace all unchanged.
- Search behavior for non-label queries: the tag leg's only change is the
  `LabelTag` exclusion (pinned); FTS/semantic/note legs untouched.
- Sidecar schema: no new fields (notes and edit stacks already ride;
  `photo_meta`/`places` stay excluded by the data-grain rule).
- The Drive share, exports, backup: imported files are ordinary files; edited
  imports flow through the existing Spec 04 consumer sweep with zero new cases.
- `Housekeeping`, reconcilers, carry seams: `Label: `/`Favorite` tags and imported
  notes/edits are ordinary rows — every existing carry/split/rename rule covers
  them because nothing new is keyed differently.

---

## 11. Performance (recorded, never asserted — `PerfBaseline` rows)

- Metadata scan (keywords+rating+label+GPS+note fields, sidecar present): ≥ 30
  files/s sustained on the reference M1 Air.
- `LightroomXMP.read` + `LightroomEditMapper.map`: < 2 ms/file (excl. the RAW
  as-shot resolve, recorded separately: < 80 ms/file, RAW-with-WB files only).
- `TakeoutJSON.jsonCandidates` + parse: < 1 ms/file.
- Apple Photos export throughput: recorded (PhotoKit/iCloud-bound — no target).
- Eagle copy throughput: recorded (disk-bound).
- `AnalysisStatusStore.refresh` count query at 100k rows: < 30 ms.
- Throttle mode flip → no new spawns: same pass iteration (observed via trace).

---

## 12. New durable constraints (added to `CLAUDE.md` on merge)

- **Every import writes through the existing seams only** — tags via
  `MetadataImportApply.applyKeywords`, ratings via `TagStore.setRating`
  (gap-fill, `ratingToApply`), notes via `NoteStore` (fill-gaps, never overwrite),
  edits via `EditStore.save` (never clobber an existing stack), collections via
  `CollectionStore.createManual`/`addFile`. A new source is a reader + a mapper,
  never a new writer.
- **Label tags carry the `Label: ` prefix and the tag-search leg excludes them**
  unless the query targets labels (`LabelTag.queryTargetsLabels`) — LR workflow
  markers must never answer content color queries (DECIDED #12). The prefix is
  canonical-English storage; the exclusion is pinned by test.
- **Supplement writes are header-wins/fill-gaps and stamp both scan markers**;
  `analyzeOne`/`PhotoHeaderBackfill` skip photo_meta/coords writes when both
  markers are fresh (else the first analyze pass clobbers imported GPS/dates).
  `(0,0)` coordinates are absent, not null island.
- **`EditStack.origin` is provenance, not data**: nil-omitted (hash-stable for
  all pre-existing stacks — the pinned fixture hash must never change), never
  copied by `EditTransfer.apply`, stripped at preset save, gone on Reset.
- **The LR import envelope is the enumerated list in `LightroomXMP`** — crop/
  orientation exact; WB/exposure/contrast/vibrance/saturation/point-curves
  approximated + badged; everything else disclosed in the report, never
  translated. Do not grow the list without a foundation-doc change.
- **Analysis pause is scheduling, never an off switch**: `WorkThrottleStore`
  gates spawns (`waitUntilRunnable`), markers and selection logic untouched;
  user pause persists; thermal `.serious`+ pauses; battery/Low Power reduces to
  concurrency 1. Import runs themselves are never throttled (foreground,
  cancellable).
- **The FYI is one-button, time-gated, on-device-calibrated** (#22/#23): shown
  only when the measured estimate exceeds `fyiThresholdSeconds`, at most once
  per launch, never below threshold, never a choice dialog.

---

## 13. Tests (`MuseTests`, pure-logic per house rule)

- `MetadataKeywordReaderTests` (extended): keywords/rating behavior pinned
  byte-identical on the existing fixtures; new-field extraction (sidecar-beats-
  embedded per field; Alt/Seq/Bag walks; IPTC fallbacks; label passthrough).
- `XMPGPSTests`: format variants, hemisphere signs, malformed → nil, range
  rejection.
- `ImportedTextTests`: join order, dedupe, trim, cap, all-empty → nil.
- `ImportSupplementTests` (in-memory GRDB, Spec 02 schema): header-wins,
  fill-gaps, marker stamping, hash-guard on mid-run edit, (0,0) rejection;
  **A1 regression**: supplement → analyzeOne-shaped rewrite skips fresh rows.
- `LabelTagTests` + `SearchService` pin: "red" ∌ `Label: Red`; "label: red" ∋;
  chips/rules unaffected paths compile-time-referenced.
- `LabelMappingTests`: choice resolution, ★-run refusal, persistence round-trip,
  remembered-choice silent-apply decision function.
- `LightroomXMPTests`: fixture sidecars (owner-generated, §15) → field extraction,
  unsupported-set enumeration, PV-gate (2012-key presence).
- `LightroomEditMapperTests`: every conversion constant, clamps, identity-curve
  drop, >16-point subsample, orientation table (all 8), neutral → nil, RAW WB
  with/without as-shot context.
- `EditStackCodecTests` (extended): original pinned fixture hash UNCHANGED;
  second pinned fixture with `origin`; older-shape decode drops origin cleanly.
- `EditTransferTests` (extended): origin never transfers; preset save strips it.
- `TakeoutJSONTests`: all five ladder rules, epoch-string parse, geoDataExif
  fallback, favorited/people extraction, description trim.
- `EagleLibraryTests`: miniature real-library fixture parse, folder flattening
  ("Parent – Child"), corrupt-item tolerance.
- `ImportReportTests`: accumulation arithmetic; LabelOutcome formatting inputs.
- `ThrottlePolicyTests`: full mode/concurrency truth table.
- `AnalysisEstimatorTests`: calibration gate, extrapolation, threshold edge,
  offer-once inputs.
- Idempotency pins: second metadata run → zero new writes; second Eagle run →
  all-skip; LR edit re-import → `editsSkippedExisting == first run's writes`.

House rules throughout: English-host assertions on typed values, not display
strings; no UI unit tests; every new user-facing string localized at introduction
and the French `-exportLocalizations` pass reports 0 untranslated before any step
is "done".

---

## 14. Build order (each step leaves the app releasable)

1. **Universal layer + report + submenu** (§1, §2 minus supplement): reader
   extension, note leg, `ImportModal` swap-in, `ImportRunCard`, `ImportReport`.
   *(No spec dependencies.)*
2. **Supplement + Spec 02 amendment A1** (§2.4): after Spec 02 lands.
3. **Label mapping** (§3): `LabelTag` + search exclusion + sheet + chip styling.
4. **Throttle + FYI + progress surfaces** (§9): policy/store/gates/estimator/
   Settings + sidebar rows. *(Independent of 2–3; can run any time after 1.)*
5. **Google Takeout** (§7). **Eagle** (§8, verification-first). *(Order between
   them free; both after 1–2.)*
6. **Apple Photos** (§6): entitlement + card + flow. *(After 1–2.)*
7. **LR edit import** (§4) then **LR preset import** (§5): after Spec 04.
   Mapper + origin + apply path + embedded-preview compare source.

---

## 15. Owner-only steps

- **Eagle scratch library** (binding, §8.1): create one in the real Eagle app,
  confirm the package layout/field names, miniaturize into the test fixture.
- **Lightroom fixture set** (§4): export a small set from LR — RAW+sidecar and
  JPEG-embedded, covering crop+angle+orientation, WB (RAW Kelvin + JPEG
  incremental), the four tone/color sliders, RGB + per-channel curves, and files
  carrying unsupported sliders. Verify `CropAngle` sign + crop frame against LR's
  own render; the fixture test pins the verified sign.
- **Approximation eyeball pass**: imported edits on the fixture set land
  "visually close" (pre-spec acceptance) via the embedded-preview compare.
- **Takeout sample**: one real Takeout archive to sanity-check the ladder against
  current Google output (the ladder's rules are test-pinned; the archive confirms
  Google hasn't invented a sixth quirk).
- **Threshold + copy review**: `fyiThresholdSeconds` (25 min default) and the FYI/
  Settings/notice strings.
- **Apple review-time check** (from foundation §11, restated): the Photos-library
  entitlement + usage string pass App Review alongside the existing sandbox story.
- French translations for the new keys (export → fill → 0 untranslated).

---

## 16. Deliberate deviations (recorded, per house convention)

| # | Deviation | Why |
|---|---|---|
| D1 | Eagle annotations import as notes (the 2026-07-07 design dropped them) | The "Muse has no field" premise expired — per-file notes shipped (v11). The rest of the approved design is unchanged. |
| D2 | `EditStack` gains optional `origin` (DECISIONS lists five fields) | The badge must survive save/carry/sidecar-sync and cost no migration; nil-omission keeps every existing hash byte-identical (pinned). Provenance-in-stack was chosen over an `edits` column because sidecars carry the stack, not the row. |
| D3 | Spec 02 amendment A1: `analyzeOne`/`PhotoHeaderBackfill` skip photo_meta/coords writes when both markers are fresh | Without it the first analyze pass clobbers supplement-imported GPS/dates with header NULLs. Fresh-marker rows have nothing to gain from a rewrite; edit-in-place still re-reads (markers go stale with the hash). |
| D4 | Favorites → `Favorite` manual tag, never a star | A binary flag mapped to any star count fabricates a rating; ratings are mutually-exclusive and gap-fill-only by shipped rule. A manual tag is honest, filterable, and reversible. Offered as a per-card choice (tag/skip). |
| D5 | Apple Photos keywords not imported | PhotoKit exposes no keyword API (pre-spec listed keywords optimistically). Stated plainly in the card + report; revisited only if a supported API exists at build time. |
| D6 | One `ImportModal` enum replaces `metadataImportRequest` | Five flows would otherwise cost five AppState flags; the enum keeps the frozen-AppState ledger at net zero and matches the `collectionModal` seam. |
| D7 | Label choices remembered by raw source string | LR localizes label names; per-string memory is what a non-English-LR user expects, and mapping-sheet rows show exactly what the files contain. |
| D8 | Takeout imports in place (no copy step) | Takeout output is already ordinary files in a user folder — copying would duplicate gigabytes for nothing; referencing in place IS the product's no-catalog story. (Apple/Eagle copy because their sources are opaque packages/libraries.) |
| D9 | Universal GPS leg fills gaps only, header wins | File bytes are stronger provenance than sidecar XMP; LR sidecar GPS exists precisely for files whose headers lack it, so fill-gaps loses nothing. |
| D10 | User pause persists across relaunch | A pause that silently self-clears reads as broken; resume is one click in two visible surfaces. Thermal/battery states are re-evaluated live and never persisted. |
| D11 | "One coherent surface" = one submenu + one shared report card | A single hub window buys nothing over five focused cards sharing one report/model vocabulary, and the submenu keeps each flow one click from its picker (the shipped item's pattern). |

---

## 17. Acceptance mapping (from `pre-spec-06-import-migration.md` §Acceptance)

| Pre-spec acceptance | Delivered by |
|---|---|
| LR: ratings/keywords/captions/GPS lossless | §2 universal layer (keywords/ratings shipped seams; captions → notes §2.3; GPS → supplement §2.4) |
| LR: crop pixel-exact | §4.3 geometry mapping (exact tier) + fixture verification §15 |
| LR: tone approximations visually close + badged | §4.3 mapper + §4.4 origin badge + §15 eyeball pass |
| LR: unsupported sliders untouched + disclosed | §4.1 enumerated `unsupported` set → `report.unsupportedSliders` |
| Label sheet: mappings work, remembered, report accurate | §3.2 persistence, §3.3 flow, §1.3 `labelCounts` |
| Apple: rendered edits + metadata; message displayed | §6.2 flow, §6.3 notices |
| Takeout: dates/GPS restored to files that lack them | §7.2 supplement (header-wins means exactly "files that lack them") |
| 100k import: browsable in seconds | in-place/copy-then-index flows; analysis fully backgrounded (§9) |
| FYI appears with calibrated estimate | §9.5 estimator (measured EMA, 200-completion calibration) |
| Pause/resume works | §9.2–§9.4 (store, spawn gates, two surfaces) |
| Battery throttle observable | §9.1–§9.3 (`.reduced` → concurrency 1; Settings state line names it) |
