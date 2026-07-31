# Spec 07 — Share Page Expansion & Social Export: full implementation spec

*Derived from `pre-spec-07-sharing-social-export.md` + `muse-photo-foundation.md`
(§10 sharing; §11 commerce; §13 decision log is authoritative) + `DECISIONS.md`
(the binding build-level layer from Specs 01–06). Build-level expansion: exact
files, exact seams, exact tests. Written before implementation. Verified against
the codebase at `cefa008` (`feat/editing`) — as of that commit **no Spec
01/02/03/04/05/06 code exists in the tree** (migrations end at
`v12_smart_collections`); everything referenced from Specs 01–06 is referenced
exactly as specified there, and every reference to existing code was read from
the actual source (`Sharing/Drive/DriveShareManifest.swift`,
`DriveShareService.swift`, `DriveClient.swift`, `DriveShareRecord.swift`,
`DriveConfig.swift`, `DriveExpirySweeper.swift`, `GoogleOAuth.swift`,
`ImageMetadataStripper.swift`, `Views/DriveShareForm.swift`,
`Views/ManageDriveSharesView.swift`, `Views/ShareCollectionButton.swift`,
`Views/SelectionMenu.swift`, `Views/Viewer/ShareButton.swift`,
`Views/Modal/ModalChrome.swift`, `Models/AppState.swift` (`modalPresented`),
`Settings/AppSettings.swift`, `Settings/SettingsView.swift`, `web/share/share.js`,
`web/share/index.html`, `web/share/share.css`, `web/share/_headers`,
`web/share/share.test.mjs`, `Muse/MuseTests/DriveShareManifestTests.swift`).*

---

## 0. What this spec does, does not, and depends on

**Does:** three **share-page layouts** (grid / contact sheet / single-column
essay) chosen at publish time, encoded in the manifest, rendered by the static
page with the CSP and dependency-freedom intact; **portfolio mode** — a
persistent, non-expiring share that is **updatable in place at a stable URL**
with zero server state (the manifest moves from the URL fragment to a
pointer-addressed `manifest.json` in the user's own Drive, with the fragment
carrying a full inline snapshot as fallback — §2.1 records the decision);
**social export presets** — the full preset table from the pre-spec, with the
DECIDED interactive in-flow crop, Matte and Blur-extend fit modes, output
sharpening, sRGB/baked-orientation JPEG delivery, the X no-recompress target,
metadata stripped by default with a photography-platform EXIF toggle, and a
"temporary social version" that persists nothing unless explicitly saved; and
the **Google on-ramp polish** — a clear signed-out explainer ("photos upload to
YOUR Google Drive; we never see them"), guided sign-in, and graceful
unverified-scope messaging.

**Does not:** custom domains, `username.muse.app` subdomains, or the
provisioning Worker (all Spec 08) · any new share backend (Google Drive only,
DECIDED #19) · any server-side share state, ever · a download-originals feature
(the owner's Drive gates that; §4.3 explains it in UI copy instead) · video
export presets (photo-first) · new search tokens, smart-rule cases, analysis
modes, migrations, or AppState `@Published` properties beyond the one sanctioned
shell-modal flag (§3.6, the `openWithForkRequest` class).

**Migrations: NONE.** Social export writes no rows (an explicitly saved
"temporary social version" goes through Spec 04's existing `edit_versions`
seam); portfolio records ride the existing `driveShares.json`
(`DriveShareStore`), never SQLite. Future specs still continue at **v24**.

**Depends on:**

| Dependency | Needed by | Nature |
|---|---|---|
| Shipped Drive share (`Sharing/Drive/`, `web/share/`, Polish 18) | everything in §1–§2, §4 | **Hard** — already in the tree. All security invariants carry (§5). |
| Spec 01 §3.4 (`OutputRender` choke point) | §3.3 (social export renders through it) | **Hard.** If Spec 07 builds before Spec 01, it builds `Export/OutputRender.swift` to Spec 01's text verbatim as step 0 (the Spec 04 §13 convention) — identity behavior today, edit-aware when Spec 04 lands. |
| Spec 04 (`EditStack`, `EditStore.saveVersion`, `EditRenderer`) | the §3.6 "save crop as version" affordance; the edited-pixels acceptance ("export of an edited RAW goes out WITH edits applied") | **Soft/severable.** Social export compiles and ships without Spec 04 — `OutputRender.forOutput` is identity, the save-as-version button is **absent, not disabled** (house rule). The acceptance line is only *verifiable* once Spec 04 exists. |
| Spec 01 commerce (`CommerceStore`) | §2.9 portfolio tier seam | **Soft.** `SharingTier` reads it when present; computes-but-never-blocks until Spec 09 either way. |
| Specs 02/03/05/06 | nothing | None. |

**Independently shippable:** each numbered build-order step (§9) maps to one
pre-spec item and leaves the app releasable.

---

## 1. Share-page layout options — grid / contact sheet / essay

### 1.1 Manifest v2 — two new optional keys (`y`, `s`)

`DriveShareManifest` (Sharing/Drive/DriveShareManifest.swift) gains two optional
fields; **every new manifest field in this spec is optional with a nil default**,
so a manifest that doesn't use the new features encodes to JSON containing none
of the new keys (synthesized `Codable` uses `encodeIfPresent`) and old links /
old page deployments are unaffected:

```swift
struct DriveShareManifest: Codable, Equatable {
    var intro: String
    var label: String
    var name: String
    var date: String
    var expiry: String                  // "" for portfolio manifests — see §2.2
    var imageIDs: [String]
    var filenames: [String]? = nil      // "f" (shipped)
    var pdfID: String?
    var layout: String? = nil           // "y" — DriveShareLayout.rawValue; absent = grid
    var bodyText: String? = nil         // "s" — intro paragraph (essay header / portfolio intro)
    var manifestID: String? = nil       // "m" — §2: Drive file id of the live manifest.json

    enum CodingKeys: String, CodingKey {
        case intro = "i", label = "l", name = "n", date = "d",
             expiry = "e", imageIDs = "g", filenames = "f", pdfID = "p",
             layout = "y", bodyText = "s", manifestID = "m"
    }

    /// App-side caps mirroring the page's validator (share.js MAX_FIELD /
    /// MAX_NAME / grid cap). Enforced at publish time (§1.4, §2.6) so the app
    /// can never mint a link its own page rejects.
    static let maxImages = 1000
    static let maxFieldLength = 4096
}

/// The three page layouts. Raw values are the manifest wire values — the page's
/// `layoutOf` must match them exactly (the `ClipTokenizer`-fixture rule class:
/// two implementations of one contract, pinned by tests on both sides).
enum DriveShareLayout: String, CaseIterable, Codable {
    case grid, sheet, essay
}
```

- `expiry` stays non-optional in the struct (the shipped shape). Portfolio
  manifests set it to `""` and the encoder **omits empty-`e` at the page layer
  by rule** — concretely: `encoded()` is unchanged; the page treats `m`-present
  manifests as non-expiring and never consults `e` (§2.2). Classic shares keep
  a real date.
- `DriveShareManifest.jsonData() -> Data` (new): the plain, uncompressed,
  un-base64'd JSON encoding — the bytes uploaded as `manifest.json` (§2.6). The
  fragment keeps using `encoded()` (base64url + optional DEFLATE) untouched.
- The pre-publish guard: `imageIDs.count ≤ maxImages` and every free-text field
  trimmed + hard-capped at `maxFieldLength` (`filenames` at 1024, matching
  `MAX_NAME`). Today the app can mint a >1000-image link that the page rejects
  as "no longer available" — fixed here with a clear pre-publish error
  (`.failed(String(localized: "Shares are limited to 1,000 images. This view has %d."))`).

### 1.2 Page-side validation + layout resolution (`web/share/share.js`)

`validateManifest` grows exactly three rules (all additive — every shipped
manifest still validates, pinned by the existing tests):

```js
// New optional keys. Unknown layout VALUES are allowed (forward-compat: an
// older page render of a newer link falls back to grid via layoutOf) — but the
// key, when present, must be a short string; `s` is display text (field cap);
// `m` must be a well-formed Drive id (same charset gate as image ids).
if (m.y != null && (typeof m.y !== 'string' || m.y.length > 16)) return false;
if (m.s != null && (typeof m.s !== 'string' || m.s.length > MAX_FIELD)) return false;
if (m.m != null && !VALID_ID.test(m.m)) return false;
```

and the expiry rule becomes portfolio-aware (§2.2):

```js
// `e` is REQUIRED for classic shares (the fail-open guard: an absent/malformed
// date must never yield a never-expiring link by accident). A portfolio
// manifest (`m` present) is non-expiring BY DESIGN and carries no meaningful
// `e`; `opts.portfolio` covers manifests fetched from Drive, which never ride
// a fragment and have no `m` of their own.
export function validateManifest(m, opts = {}) {
  ...
  const portfolio = opts.portfolio === true || m.m != null;
  if (!portfolio) {
    if (typeof m.e !== 'string' || !DATE_ONLY.test(m.e) || isNaN(Date.parse(m.e))) return false;
  } else if (m.e != null && m.e !== '') {
    if (typeof m.e !== 'string' || m.e.length > 32) return false;  // tolerated, ignored
  }
  ...
}

export function layoutOf(m) {
  return (m.y === 'sheet' || m.y === 'essay') ? m.y : 'grid';
}
```

`isExpired` is **only called when the manifest is not a portfolio** (render glue
change in §2.3). The existing strict-`e` tests keep passing because the sample
manifests carry no `m`.

### 1.3 Rendering the three layouts (share.js glue + share.css + index.html)

One mechanism: the render glue sets `root.dataset.layout = layoutOf(m)` next to
the existing `data-state`, fills the new intro node, and everything else is CSS.
No new DOM construction paths — the same tile `<button>` builder serves all
three layouts (captions, lightbox, deterrents, and `sanitizeText` all inherit).

- **index.html:** one new node under the header —
  `<p id="body" class="body"></p>` (filled via `set('body', m.s ?? '')`, i.e.
  `textContent` + `sanitizeText`, like every other field; empty → CSS hides it
  via `:empty`). Everything else (grid node, sizer, lightbox) is reused.
- **`grid` (default):** exactly today's rendering. `data-layout="grid"` styles
  are the current rules moved under the attribute selector — a legacy link (no
  `y`) must render byte-for-byte the same page it does today.
- **`sheet` (contact sheet):** the photographer's proof-sheet look. Same
  `.grid` node, denser: the sizer's column range becomes 4–10 (default 7 —
  the sizer reads per-layout `MIN`/`MAX`/default from a small
  `SIZER_BY_LAYOUT` table in share.js), square thumbnail boxes
  (`aspect-ratio: 1`), filename caption **always visible** under every tile at
  10px mono-numeric styling, tight 8px gaps, and a frame number
  (`counter-increment` on the tile, rendered via `::before`) — contact sheets
  are for referencing frames by number. Print: 6 columns.
- **`essay` (single column):** `.grid` becomes a centered single column
  (`max-width: 860px`), images at natural aspect in document order, generous
  vertical rhythm (48px), captions (when filenames exist) small + centered
  under each image, `#body` renders as a lead paragraph under the title. The
  grid sizer is hidden (`[data-layout="essay"] .grid-sizer { display: none }`)
  — column density is meaningless in a single column. Print: one image per
  block, `break-inside: avoid`, same as the atomic-tile print rule today.
- The backdrop switcher, lightbox, download deterrents, expired/unavailable
  states, and the print "Save PDF" flow are layout-independent and untouched.
- **CSP is unchanged by §1** (no new origins, no inline anything). The page
  stays dependency-free: no new script, `fflate` untouched.

### 1.4 Choosing a layout at publish time (`Views/DriveShareForm.swift`)

- The service-side value type grows two fields (DriveShareService.swift):

```swift
struct DriveShareForm {
    var intro: String
    var label: String
    var name: String
    var date: Date
    var expiry: Date
    var layout: DriveShareLayout = .grid
    var bodyText: String = ""          // shown on essay + portfolio pages
}
```

- The sheet's form gains, between "Page Title" and "Label": a **Layout**
  segmented `Picker` (three options, SF Symbols `square.grid.2x2` /
  `rectangle.grid.3x2` / `rectangle.portrait.on.rectangle.portrait` with
  localized labels "Grid" / "Contact Sheet" / "Essay") and — only when Essay is
  selected, plus always in portfolio mode (§2.8) — an **Intro** multi-line
  `TextField(axis: .vertical)` (`lineLimit(3...6)`), capped at
  `DriveShareManifest.maxFieldLength` on publish.
- Last-used layout is remembered: `AppSettings.driveShareLayout`
  (`String`, default `"grid"`, the `driveShareLabel` pattern at
  AppSettings.swift:65). The intro paragraph is NOT remembered (it's
  per-collection prose, not identity like name/label).
- `DriveShareService.run` maps them into the manifest:
  `layout: form.layout == .grid ? nil : form.layout.rawValue` (grid stays
  key-absent so plain shares keep minimal fragments) and
  `bodyText: form.bodyText.isEmpty ? nil : form.bodyText`.

---

## 2. Portfolio mode — persistent, updatable, zero server state

### 2.1 The mechanism (the decision the pre-spec delegates here)

The pre-spec asks for "non-expiring, updatable in place … re-publish replaces
the Drive folder contents + the user re-shares the same link, or link
versioning within the fragment — spec the cleanest zero-server approach," and
acceptance wants the **URL to survive a content update**.

A fragment-only manifest cannot do that: adding or removing an image changes
the id list, which changes the fragment, which changes the URL. Drive's
`files.update` keeps a file's **id** stable across content rewrites — so the
one place a mutable manifest can live with zero developer-side state is **a
`manifest.json` inside the share's own Drive folder**, addressed by id from the
fragment. The state lives in the *user's* Drive, exactly like the images —
the developer still runs nothing and receives nothing.

**Decision (D5): a portfolio share = Drive folder (images + `manifest.json`) +
a fragment that carries the manifest file's id (`m`) AND a full inline snapshot
of the manifest.** The page tries to fetch the live manifest; on any failure
(offline recipient, API change, quota) it renders the inline snapshot — a
portfolio link can *degrade* to last-published state but can never go blank.
Updating in place = rewrite `manifest.json` via `files.update` (id unchanged →
URL unchanged), upload new images, delete removed ones.

Alternatives rejected, for the record: *folder-listing from the page* (needs
the same API key plus more surface, and couples rendering to Drive list
semantics); *in-place image-content updates only* (cannot add/remove — not a
portfolio); *a Worker serving manifests* (server-side share state — NEVER);
*new-URL-per-update* (fails the acceptance line outright).

**The fetch endpoint and the API key.** The page fetches
`https://www.googleapis.com/drive/v3/files/<id>?alt=media&key=<key>` — Google's
documented browser path for public-file content (CORS-enabled; the bare
`drive.google.com/uc` download path does not serve CORS headers and must not be
used). That requires a **Drive API key in share.js**. This revises the shipped
"no API key" line in the CLAUDE.md invariants — deviation **D1**, recorded with
its rationale: an API key for public data is **not a secret** (Google's own
docs: embeddable in client code with restrictions); it authenticates nobody and
unlocks nothing non-public (the files are already anyone-readable by design);
it is **referrer-restricted** to the share origins and **API-restricted** to
the Drive API (owner step §10); worst case is quota noise, not data exposure.
The load-bearing invariant — *no secret on the page* — is intact and restated
in §7.

### 2.2 Portfolio manifest shape

A portfolio fragment is a v2 manifest with `m` set and `e` empty; the uploaded
`manifest.json` is the **same object minus `m`** (it doesn't know its own id,
and the page never chains fetches):

```
fragment  = base64url(deflate?({i,l,n,d,e:"",g,f,y?,s?,m}))   // inline snapshot + pointer
manifest.json = raw JSON {i,l,n,d,e:"",g,f,y?,s?}             // the live truth, rewritten on update
```

Rules (page side, all pinned by tests):

- `m` present ⇒ portfolio ⇒ **never expires**: `isExpired` is not consulted.
  `e` required otherwise (the fail-open guard, §1.2 — unchanged for classic
  shares).
- A **fetched** manifest is validated with `validateManifest(obj, {portfolio:
  true})` — full structural validation (id charsets, caps, grid cap, filename
  pairing) with the expiry requirement waived. Its `m`, if somehow present, is
  **ignored** — exactly one fetch, no chaining, no recursion.
- The fetched manifest replaces the inline one wholesale on success (layout,
  text, and images all come from it); on any failure the inline snapshot
  renders. Trust is unchanged: whoever crafts a fragment already controls the
  inline manifest, so a fetched manifest reachable only via that same fragment
  adds no new attacker capability — but it gets the *same* full validation
  anyway.

### 2.3 Page fetch (share.js) + CSP change

```js
// §2: portfolio manifests live in the user's Drive so the share can update
// without changing its URL. Quota-only, referrer-restricted browser API key —
// grants access to nothing non-public (see README); NOT a secret. The ONLY
// fetch this page ever makes.
const DRIVE_API_KEY = 'REPLACE_AT_DEPLOY';          // owner step — §10
const MAX_MANIFEST_BYTES = 512 * 1024;              // bounded read (bomb-guard rule class)
const MANIFEST_FETCH_TIMEOUT_MS = 6000;

export function manifestFetchURL(id) {
  // VALID_ID-gated by the caller; the charset makes interpolation URL-safe
  // (the thumbURL rule class).
  return `https://www.googleapis.com/drive/v3/files/${id}?alt=media&key=${DRIVE_API_KEY}`;
}

// Pure: parse + bound + validate a fetched manifest body. null → caller falls
// back to the inline snapshot. Exported for tests.
export function acceptFetchedManifest(text) {
  if (typeof text !== 'string' || text.length > MAX_MANIFEST_BYTES) return null;
  try {
    const obj = JSON.parse(text);
    if (obj && typeof obj === 'object') delete obj.m;   // never chain
    return validateManifest(obj, { portfolio: true }) ? obj : null;
  } catch { return null; }
}
```

Render glue: when `m.m` is a valid id, `fetch(manifestFetchURL(m.m), {signal})`
under an `AbortController` timeout; `acceptFetchedManifest(await r.text())`
picks the render source. While the fetch is in flight the inline snapshot
renders **immediately** (no blank waiting state); a successful fetch that
differs re-renders the grid (clear + rebuild via the one tile builder — cheap,
and typically identical so no visible change). Expired/unavailable branches:
portfolio manifests skip the expired branch entirely.

**CSP:** both `_headers` and the `index.html` meta fallback gain exactly
`; connect-src https://www.googleapis.com`. Nothing else changes —
`default-src 'none'`, `script-src 'self'`, frame-ancestors, referrer policy all
stay. fflate stays a `'self'` module import.

### 2.4 `DriveClient` additions (Sharing/Drive/DriveClient.swift)

Three calls, same house style (authed, `fields=`-scoped, status-checked). The
image-upload path is untouched — **`uploadFile` remains the only way image
bytes reach Drive, strip-verified fail-closed**; the new JSON upload is
deliberately named and typed so it can't become a strip bypass:

```swift
/// Upload/replace the portfolio's manifest.json. NEVER for images — image
/// bytes go through uploadFile's metadata strip, fail-closed. Enforced by the
/// narrow signature (takes Data that the caller just encoded, mime pinned).
func uploadManifest(_ json: Data, parent: String) async throws -> String
    // POST uploadEndpoint, multipartBody(metadata: ["name": "manifest.json",
    // "parents": [parent]], fileData: json, mime: "application/json", ...)

func updateManifest(id: String, json: Data) async throws
    // PATCH https://www.googleapis.com/upload/drive/v3/files/<id>?uploadType=media
    // Content-Type: application/json; body = json. 200 → ok, else DriveError.http.

/// Children of a folder Muse created (drive.file sees only its own files).
/// Used by the portfolio update to sweep replaced images.
func listChildren(of folderID: String) async throws -> [(id: String, name: String)]
    // GET filesEndpoint?q='<folderID>'+in+parents+and+trashed=false
    //     &fields=files(id,name)&pageSize=1000   (built via URLComponents;
    // one page is enough: shares are capped at maxImages=1000 + manifest)
```

### 2.5 `DriveShareRecord` growth + store lookup (DriveShareRecord.swift)

```swift
struct DriveShareRecord: Codable, Identifiable, Equatable {
    let id: String
    let collectionName: String
    let folderID: String
    let pageURL: String
    let itemCount: Int
    let createdAt: Date
    let expiry: Date                    // .neverExpires sentinel for portfolios
    // Spec 07 — all optional so pre-existing driveShares.json decodes unchanged.
    var kind: String? = nil             // "portfolio"; nil/anything else = classic share
    var manifestFileID: String? = nil   // the stable pointer (files.update target)
    var collectionID: String? = nil     // binds "Update Portfolio…" to its collection
    var layout: String? = nil           // prefill for the update form
    var introTitle: String? = nil       // prefill
    var bodyText: String? = nil         // prefill

    var isPortfolio: Bool { kind == "portfolio" }
    /// 2100-01-01T00:00:00Z. A SENTINEL, not an optional: an optional expiry
    /// would make new-format records undecodable by the previous build's
    /// non-optional field (whose load() failure silently drops the WHOLE list
    /// on next save). The sentinel keeps old builds fully working, and the
    /// sweeper needs no portfolio special-case — `expiry < now` is simply
    /// never true. Deviation D4.
    static let neverExpires = Date(timeIntervalSince1970: 4_102_444_800)
}
```

`DriveShareStore` gains one query, same lock/queue discipline:

```swift
func portfolio(forCollectionID id: String) -> [DriveShareRecord] {
    queue.sync { load().filter { $0.isPortfolio && $0.collectionID == id }
                       .sorted { $0.createdAt > $1.createdAt } }
}
```

`DriveExpirySweeper` and `DriveExpiry.expired` are **byte-untouched** — the
sentinel is the whole design (pinned by `DriveShareStoreTests`, §8).

### 2.6 Publish flow — `DriveShareService.publishPortfolio`

Same service, same `Phase` enum, same generation guard, same cancel-on-dismiss
invariant (the sheet's `.onDisappear { service.cancel() }` covers portfolio
publishes for free — a dismissed sheet must never leave a headless upload going
public unseen). Ordered, fail-closed:

```swift
func publishPortfolio(form: DriveShareForm, title: String,
                      collectionID: String?, urls: [URL])
```

1. Guard `urls` non-empty, `urls.count ≤ DriveShareManifest.maxImages`, fields
   capped (§1.1). Sign in if needed (`.signingIn`), `ensureMuseRoot`.
2. `createFolder(name: "\(title) — Portfolio", parent: root)`.
3. Upload every image via the **unchanged** `uploadFile` (strip, fail-closed,
   `.uploading(i, n)` progress, `PublishError.unshareableImage` naming, cancel
   → `cleanupFolder` — all shipped behavior).
4. Build the live manifest (no `m`, `expiry: ""`, layout/bodyText per form) →
   `uploadManifest(manifest.jsonData(), parent: folderID)` → `manifestID`.
5. `.finalizing` → `setAnyoneReader(fileID: folderID)` (children inherit — the
   shipped single-permission pattern; `manifest.json` is world-readable by the
   same inheritance, which is required for the page fetch and leaks nothing the
   fragment didn't already carry).
6. Fragment manifest = live manifest + `manifestID` → `pageURL` → `store.add`
   a record with `kind: "portfolio"`, `expiry: .neverExpires`,
   `manifestFileID`, `collectionID`, `layout`, `introTitle: form.intro`,
   `bodyText: form.bodyText` → `.done(pageURL)` / `.doneUntracked(pageURL)`
   (the shipped copy-now warning; an untracked PORTFOLIO additionally can never
   be updated — the warning string gains a localized portfolio variant).

Any failure after step 2 → the existing `cleanupFolder` (fresh unstructured
Task — the cancelled-URLSession rule) then the error phase. No partial share.

### 2.7 Update flow — `DriveShareService.updatePortfolio`

```swift
func updatePortfolio(record: DriveShareRecord, form: DriveShareForm, urls: [URL])
```

Ordered so a visitor mid-update always sees a coherent page, and so failure
never damages the live share:

1. Same guards; sign-in; **no folder creation** — `record.folderID` is the
   target. `folderExists(id:)` first; a 404 (deleted in Drive / switched
   account) → `.failed` with a localized "this portfolio no longer exists —
   publish a new one" message (the account-switch orphan doctrine: a 404 folder
   is unreachable forever under `drive.file`).
2. Upload ALL current images as new files (`.uploading` progress). v1
   re-uploads everything — content diffing is an optimization with real
   correctness risk (edit-aware bytes change without filenames changing), not
   v1 scope. Failure here → delete just-uploaded files (fresh-Task cleanup),
   old share untouched, `.failed`.
3. Build the new live manifest (new ids/filenames, form's layout/text) →
   `updateManifest(id: record.manifestFileID!, json:)`. **This is the atomic
   swap** — before it, the page serves the old set (old files still present);
   after it, the new set (new files present). Failure → same rollback as 2.
4. Sweep: `listChildren(of: record.folderID)`, delete every child whose id is
   neither a just-uploaded image nor `manifestFileID`. A per-file delete
   failure is non-fatal: keep going, then surface one notice in the done view
   ("Some previous images couldn't be removed from Drive; they'll be cleaned
   up on the next update") — the next update's list-driven sweep is the retry.
5. Update the record in place (`store.add` replaces by id/folderID — shipped
   upsert semantics): new `itemCount`, `layout`, `introTitle`, `bodyText`,
   same `pageURL`, same `manifestFileID`, same `createdAt`. →
   `.done(record.pageURL)`.

The URL never changes — that is the acceptance test. Old copies of the link
keep working through every update (they fetch the live manifest; their inline
snapshot only matters offline, where it shows last-published state — recorded
limitation, §11 D5 note).

### 2.8 UI seams

- **`CollectionModal`** (Views/Modal/ModalChrome.swift): the payload becomes a
  struct so mode and collection identity travel to the shell (the shipped
  hoisting rule — a card presented from a 240pt sidebar row must be built by
  `ContentView`):

```swift
enum DriveShareMode: Equatable {
    case share
    case portfolioNew
    case portfolioUpdate(DriveShareRecord)
}
struct DriveShareRequest: Equatable {
    var title: String
    var urls: [URL]
    var mode: DriveShareMode = .share
    var collectionID: String?
}
// CollectionModal:
case driveShare(DriveShareRequest)          // id: "drive-\(request.title)-\(modeTag)"
```

  Both existing setters (`ShareCollectionButton.presentDriveShare`,
  `CollectionSidebarRow:260`) construct `DriveShareRequest(title:urls:)` —
  behavior identical.
- **`ShareCollectionButton`** menu (the only share entry inside a collection)
  becomes:

```
Save to…                       // PDF export — untouched
Share Drive Link               // classic expiring share — untouched
─────
Publish Portfolio…             // when no portfolio record exists for this collection
Update Portfolio…              // when one exists (most recent record)
Copy Portfolio Link            // when one exists — NSPasteboard, no network
```

  Records resolved via `DriveShareStore.default.portfolio(forCollectionID:
  appState.activeCollectionID)`; items are **absent, not disabled** when they
  don't apply (house rule). Payload uses the same `driveShareURLs` filter
  (raster kinds only — the stripper-abort rule).
- **`DriveShareSheet`** branches on mode: portfolio forms show Title · Layout ·
  Intro (multi-line, always shown) · Label · Name — **no expiry field** — and
  the header reads "Publish Portfolio" / "Update Portfolio". Update mode seeds
  the form from the record (`introTitle`/`bodyText`/`layout` + the standing
  `AppSettings.driveShareName`/`driveShareLabel`), and its footer states
  plainly: *"Updating replaces the portfolio's images and text. The link stays
  the same."* Publish button calls `publish`/`publishPortfolio`/
  `updatePortfolio` per mode.
- **`ManageDriveSharesView`:** portfolio rows show a small "Portfolio"
  capsule tag beside the name and "Never" (localized) in the Expires column
  (`record.isPortfolio` gates both; the sentinel date never renders).
  Everything else — Open Link prefix validation, prune-on-404, unpublish
  trash button (which correctly deletes the whole folder, manifest included) —
  works on portfolios unchanged.

### 2.9 The tier seam — `Commerce/SharingTier.swift` (pure)

Portfolio (with Spec 08's custom domains) is the upsell tier (foundation §11).
Enforcement policy is **Spec 09's decision**, so Spec 07 ships the seam in the
`TrialGate` posture — computes, never blocks:

```swift
enum SharingTier {
    /// Spec 09 flips `enforced`. Until then every caller gets `true` and the
    /// portfolio UI is fully available (TestFlight validation needs it).
    static let enforced = false
    static func portfolioAvailable(entitledToSharing: Bool) -> Bool {
        enforced ? entitledToSharing : true
    }
}
```

The single call site is `ShareCollectionButton` (menu-item visibility), passing
`CommerceStore.shared.entitlements.sharing` when Spec 01's commerce exists,
`false` otherwise (irrelevant while unenforced). No other surface asks.

---

## 3. Social export presets

### 3.1 Module + the preset table — `Export/Social/SocialPreset.swift` (pure)

New folder `Export/Social/` (platform-neutral: Foundation / CoreGraphics /
CoreImage / ImageIO / UniformTypeIdentifiers only — no AppKit; the
`Editing/`-module import rule class). The preset table is **exactly the
pre-spec's table**, expressed as data and pinned entry-by-entry by
`SocialPresetTests` (a changed number is a failing test, so the table can't
drift from the spec silently):

```swift
struct SocialPreset: Identifiable, Equatable {
    enum Kind: Equatable {
        case fixed(width: Int, height: Int)   // aspect-mismatch → crop step applies
        case longEdge(Int)                    // downscale-only; no crop step
        case original                         // no resize at all
    }
    enum SharpenLevel { case none, light, standard }

    let id: String            // stable ("ig-feed-portrait" …) — used in filenames + prefs
    let nameKey: String       // localization key; display via String(localized:)
    let kind: Kind
    let quality: Double       // initial JPEG quality (0…1)
    let byteTargetKB: Int?    // nil = no target; ladder in §3.3
    let sharpen: SharpenLevel
    let exifDefaultOn: Bool   // photography platforms — foundation table
    let uniformMulti: Bool    // carousel: every selected image, same ratio
    let storySafeZones: Bool  // 250px top/bottom guides in the crop UI
    let warningKey: String?   // localized advisory shown in the card

    static let all: [SocialPreset] = [
        .init(id: "ig-feed-portrait", nameKey: "IG Feed Portrait",
              kind: .fixed(width: 1080, height: 1350), quality: 0.88,
              byteTargetKB: 800, sharpen: .standard, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: false,
              warningKey: "Keep key content centered — grid previews crop to 3:4."),
        .init(id: "ig-grid", nameKey: "IG Grid-Optimized",
              kind: .fixed(width: 1080, height: 1440), quality: 0.88,
              byteTargetKB: 800, sharpen: .standard, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: false,
              warningKey: "The feed crops this to 4:5 — grid tiles show the full 3:4."),
        .init(id: "ig-square", nameKey: "IG Square",
              kind: .fixed(width: 1080, height: 1080), quality: 0.88,
              byteTargetKB: 800, sharpen: .standard, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: false, warningKey: nil),
        .init(id: "ig-landscape", nameKey: "IG Landscape",
              kind: .fixed(width: 1080, height: 566), quality: 0.88,
              byteTargetKB: 800, sharpen: .standard, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: false, warningKey: nil),
        .init(id: "ig-story", nameKey: "IG / Threads Story & Reel",
              kind: .fixed(width: 1080, height: 1920), quality: 0.88,
              byteTargetKB: 800, sharpen: .standard, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: true, warningKey: nil),
        .init(id: "ig-carousel", nameKey: "IG Carousel",
              kind: .fixed(width: 1080, height: 1350), quality: 0.88,
              byteTargetKB: 800, sharpen: .standard, exifDefaultOn: false,
              uniformMulti: true, storySafeZones: false,
              warningKey: "The first slide locks the ratio — every slide exports at 4:5."),
        .init(id: "threads", nameKey: "Threads",
              kind: .fixed(width: 1080, height: 1350), quality: 0.88,
              byteTargetKB: 800, sharpen: .standard, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: false, warningKey: nil),
        .init(id: "x", nameKey: "X",
              kind: .longEdge(4096), quality: 0.90,
              byteTargetKB: nil, sharpen: .light, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: false,
              warningKey: nil),        // §3.4 hard invariants apply instead
        .init(id: "facebook", nameKey: "Facebook",
              kind: .longEdge(2048), quality: 0.85,
              byteTargetKB: 1000, sharpen: .standard, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: false, warningKey: nil),
        .init(id: "pinterest", nameKey: "Pinterest",
              kind: .fixed(width: 1000, height: 1500), quality: 0.90,
              byteTargetKB: nil, sharpen: .standard, exifDefaultOn: false,
              uniformMulti: false, storySafeZones: false, warningKey: nil),
        .init(id: "flickr", nameKey: "Flickr / 500px",
              kind: .original, quality: 0.95,
              byteTargetKB: nil, sharpen: .none, exifDefaultOn: true,
              uniformMulti: false, storySafeZones: false, warningKey: nil),
        .init(id: "glass", nameKey: "Glass",
              kind: .longEdge(4096), quality: 0.92,
              byteTargetKB: nil, sharpen: .light, exifDefaultOn: true,
              uniformMulti: false, storySafeZones: false, warningKey: nil),
    ]
}
```

Notes bound to the table:

- The IG-family byte target is **800 KB** — the foundation's pipeline note
  ("always hand IG a finished sRGB JPEG at exactly 1080w, 300–800 KB") is the
  tighter of the two stated bounds (the table's "<1 MB") and satisfies both.
- Glass's stated range is 2560–4096; the preset takes the 4096 ceiling and the
  global **never-upscale** rule (§3.3) supplies the floor behavior — a source
  under 2560 exports at its native size rather than being inflated.
- `warningKey` strings are advisory copy in the card, not blockers.

### 3.2 Fit modes + crop math — `Components/SocialCropMath.swift` (pure)

Three fit modes for `fixed` presets (long-edge/original presets change no
aspect, so the fit-mode control and crop step are hidden for them):

```swift
enum SocialFit: String { case crop, matte, blurExtend }
enum MatteShade: String { case white, black }

enum SocialCropMath {
    /// The normalized source-crop rect (unit coords, display-oriented) for a
    /// target aspect at a zoom/center chosen in the crop UI. zoom 1 = the
    /// minimal crop that fills the target frame (aspect-fill); zoom z > 1
    /// magnifies. Center is clamped so the rect never leaves the unit square.
    static func rect(sourceSize: CGSize, targetAspect: CGFloat,
                     zoom: CGFloat, center: CGPoint) -> CGRect
    static let zoomRange: ClosedRange<CGFloat> = 1...4

    /// §3.6 "save crop as version": compose the social rect into the photo's
    /// existing GeometryParams (the social rect is chosen in POST-geometry
    /// display space, so it maps inside the existing crop).
    static func composedCrop(existing: CGRect?, social: CGRect) -> CGRect
}
```

Both functions are pure and unit-tested (clamping, aspect exactness, identity
at zoom 1/center .5, composition against a pre-existing crop). Default state:
zoom 1, centered — i.e. a plain center-crop unless the user moves it.

- **Matte:** aspect-fit the image inside the exact target frame; fill the rest
  with the chosen shade (white default; black selectable; remembered in
  `AppSettings.socialMatteShade`). Output dims are exactly the preset dims —
  that is the acceptance line "Matte export matches target dims exactly."
- **Blur-extend:** target frame filled by an aspect-FILL copy blurred with
  `CIGaussianBlur` (radius = `SocialRender.blurExtendRadiusFraction (0.04)` ×
  target long edge, `clampedToExtent()` first so edges don't fade), with the
  aspect-fit sharp image composited over it.

### 3.3 The render pipeline — `Export/Social/SocialRender.swift`

One nonisolated enum; every step a named constant; **the choke point comes
first** — pixels enter via `OutputRender.forOutput(url)` so an edited photo
exports with its edits (identity until Spec 04; automatic after — the Spec 01
design doing its job):

```swift
enum SocialRender {
    struct Job {
        var sourceURL: URL          // ORIGINAL library URL (forOutput resolves edits)
        var preset: SocialPreset
        var fit: SocialFit          // fixed presets only; ignored otherwise
        var matte: MatteShade
        var cropRect: CGRect?       // normalized; nil = center (fixed+crop only)
        var includeEXIF: Bool
        var includeLocation: Bool   // only honored when includeEXIF (§3.5)
    }
    struct Result { let url: URL; let pixelSize: CGSize; let bytes: Int }

    static func export(_ job: Job, to directory: URL) throws -> Result

    // Constants (single declaration site; owner-tunable):
    static let neverUpscale = true
    static let decodeCeilingFactor = 4        // decode ≤ 4 × output long edge…
    static let decodeFloor = 4096             // …but never below 4096 (crop headroom)
    static let sharpenStandard = (radius: 1.2, intensity: 0.5)   // CIUnsharpMask
    static let sharpenLight    = (radius: 0.8, intensity: 0.25)
    static let qualityStep = 0.05             // byte-target ladder
    static let qualityFloor = 0.70            // generic floor; X uses 0.55 (§3.4)
    static let blurExtendRadiusFraction: CGFloat = 0.04
}
```

Pipeline order (code, fixed):

1. `let out = try OutputRender.forOutput(job.sourceURL)` — original bytes
   today, edit-rendered temp when a stack exists (Spec 04). Everything below
   reads `out.url`.
2. **Budget gate:** `ThumbnailCache.withinDecodeBudget` on `out.url` — this is
   a user-initiated flow, but it decodes at full/near-full raster, so the
   300 MP bomb guard applies (the "new automatic decode" rule read
   conservatively; a refusal surfaces per-file by name, the
   `unshareableImage` pattern).
3. **Decode display-oriented** via `CGImageSourceCreateThumbnailAtIndex`
   (`kCGImageSourceCreateThumbnailFromImageAlways: true`,
   `kCGImageSourceCreateThumbnailWithTransform: true` — orientation baked into
   pixels, so no output orientation tag ever exists) at
   `min(sourceLongEdge, max(decodeFloor, decodeCeilingFactor × outputLongEdge))`
   — full quality headroom for Lanczos + crop, without materializing 60 MP to
   make a 1080px JPEG. `.original` presets decode at full size. ImageIO handles
   RAW here identically to the shipped thumbnail path (Apple codec — the
   RAW-three-layers doctrine, layer 2).
4. **Fit compose** (fixed presets): crop → `SocialCropMath.rect` scaled into
   pixel space, cropped, Lanczos-scaled (`CILanczosScaleTransform`) to the
   exact target dims; matte / blurExtend per §3.2 composited at exact target
   dims. `longEdge(n)`: Lanczos scale so the long edge = `min(n, sourceLong)`
   (**never upscale** — a source smaller than the target exports at its native
   cropped size, with the card noting "smaller than the preset size";
   deviation D7). `.original`: no scale.
5. **Output sharpen** (`CIUnsharpMask`, per-level constants) — applied ONLY
   when step 4 actually downscaled (sharpening an un-resampled image would
   alter Flickr's "None" promise and X's byte-stability).
6. **Flatten + sRGB:** composite over the matte shade (white unless matte-black)
   whenever the source has alpha — JPEG has no alpha and X requires RGB;
   render via a `CIContext` into an 8-bit sRGB `CGImage`
   (`workingColorSpace` extended linear sRGB, `outputColorSpace` sRGB — the
   pinned-sRGB doctrine).
7. **Encode JPEG** (`CGImageDestination`, `kCGImageDestinationLossyCompressionQuality`
   = preset quality, sRGB profile embedded, metadata per §3.5). If
   `byteTargetKB` is set and the encode exceeds it: re-encode stepping quality
   down by `qualityStep` to `qualityFloor`; best effort — a floor-quality file
   over target still exports (never fail an export over a soft target).
8. **Verify + write:** default-metadata outputs must pass
   `ImageMetadataStripper.isClean(data)` (§3.5); write to
   `directory/<stem>-<preset.id>.jpg` with a `-2`, `-3`… case-insensitive
   collision ladder (the `EditCopyNaming` convention); carousel slides append
   `-1`…`-n` before the ladder.

### 3.4 The X no-recompress target (hard invariants)

X serves the uploaded JPEG's **original bytes untouched** when it satisfies the
documented rule — a real marketing line, so it's enforced as invariants, not
aspiration. For `preset.id == "x"` the encode loop additionally REQUIRES, before
writing:

- pixel dims ≤ 4096 × 4096 (guaranteed by `.longEdge(4096)`),
- encoded size < 5 MB (5 × 1024 × 1024 bytes) — the ladder continues below the
  generic floor to `xQualityFloor = 0.55` if needed,
- RGB, no alpha (step 6 guarantees),
- **no EXIF orientation tag** (step 3 bakes; §3.5 writes none — asserted on
  the output bytes in tests, not assumed),
- `bytes < width × height` (the bytes-per-pixel bound in the rule) — the same
  ladder enforces it.

A source that can't satisfy all five even at the floor (does not exist in
practice for photographic content) fails that file's export with a named
per-file error rather than shipping a file that will be recompressed.
`XPresetRuleTests` pins all five on fixtures including a 6000-px source;
the end-to-end upload byte-compare is the **manual owner protocol** (§10) —
the app cannot verify X's server behavior from a unit test.

### 3.5 Metadata policy — `Export/Social/SocialMetadata.swift` (pure)

- **Default (EXIF toggle off): clean by construction + verified.** The encode
  writes NO source properties (a fresh properties dict carrying only the
  compression quality), and the output must pass
  `ImageMetadataStripper.isClean` — reusing the shipped verifier (field-level +
  raw-byte needles) rather than trusting construction (the Drive-strip rule
  class: verify, don't assume). A verify failure throws per-file, fail-closed.
- **EXIF on (photography platforms):**
  `SocialMetadata.outputProperties(source: CFDictionary, includeLocation: Bool)
  -> CFDictionary` copies the source's EXIF + TIFF (camera/lens/exposure —
  what Glass renders) + IPTC (creator/copyright — what Flickr shows), and
  ALWAYS drops: every orientation key (top-level + TIFF — pixels are baked),
  thumbnail/preview dictionaries, and maker notes. **GPS is dropped unless
  `includeLocation`** — a separate "Include location" sub-toggle, default OFF
  even for photography platforms (deviation D6: publishing gear info is the
  user's stated intent; publishing home coordinates is a distinct decision,
  so it gets a distinct switch — the Drive-strip privacy posture applied to a
  public-posting flow).
- The toggle's default comes from `preset.exifDefaultOn`; the user's last
  choice is remembered **per preset id** in `AppSettings.socialExifChoices`
  (`[String: Bool]` in UserDefaults; absent → preset default). The location
  sub-toggle is never remembered (always reverts to OFF).

### 3.6 The card — `Views/Export/SocialExportCard.swift` + the shell seam

**AppState seam (deviation D2):** one new shell-modal flag — the sanctioned
class (`openWithForkRequest`, `collectionModal` precedents; a card raised from
a context menu can't present itself):

```swift
// Models/AppState.swift
struct SocialExportRequest: Identifiable, Equatable {
    let id = UUID()
    var urls: [URL]           // raster kinds only, grid order
}
@Published var socialExportRequest: SocialExportRequest?
// modalPresented gains: || socialExportRequest != nil
```

Presented at the shell via `.museModal` (width 720 — the crop stage needs
room), built only while presented, Escape → dismiss via the standard modal
resolution. The card owns a per-run `@StateObject SocialExportModel`
(non-singleton, the `MetadataImportModel` shape) that holds per-image crop
state and runs the export off-main.

Layout (two columns inside the card):

- **Left — the stage.** The current image decoded once at
  `previewMaxPixel = 2048` through `withinDecodeBudget` (direct decode, no
  `ThumbnailCache` entry — the compare-pane precedent; nothing here may touch
  `renderedVariants`). Fixed presets draw the target frame; in **crop** mode
  the image pans (drag) and zooms (scroll / pinch; `SocialCropMath.zoomRange`)
  under the fixed frame — the DECIDED interaction: frame shown, user positions
  the image. Matte / blur-extend modes preview the actual composite. Story
  presets overlay the two 250 / 1920-fraction safe-zone guides as translucent
  bands with a one-line caption. Multi-image runs get a pager ("2 of 7", ←/→)
  — each image keeps its own crop state; carousel mode locks every page to the
  uniform 4:5 frame (the enforcement the pre-spec demands — there is no
  per-slide ratio to diverge).
- **Right — controls.** Preset picker (grouped `Picker`: Instagram / Threads /
  X / Facebook / Pinterest / Photography); fit-mode segmented control
  (Crop · Matte · Blur, fixed presets only) with white/black shade dots in
  matte mode; the preset's `warningKey` advisory line; EXIF toggle (+ the
  location sub-toggle, indented, visible only when EXIF is on); the never-
  upscale notice when the source is smaller than the target; and the footer
  (`ModalButton`s, house rule): Cancel · **Export…**.
- **Export…** runs `NSOpenPanel` as a directory chooser (default Desktop —
  the PDF "Save to…" precedent), then exports every image sequentially
  off-main with a determinate `ProgressView` in the card. Per-file failures
  collect and surface by filename in one `ModalMessageCard` at the end (the
  `MuseAlert` seam); successes stay written. **The status pill is untouched**
  (background-work-only rule — this is a foreground, card-owned flow).
- **Temporary by default; "Save Crop as Version" is the explicit exception.**
  Nothing the card does persists: crop positions, zooms, fit modes and the
  location toggle all die with the card (DECIDED: never force a master crop,
  never auto-accumulate versions). The one opt-in: when Spec 04 is built, a
  small "Save Crop as Version" button appears under the stage (crop mode,
  fixed presets, editable kinds only — absent otherwise, never disabled). It
  composes the social rect into the photo's current stack's geometry via
  `SocialCropMath.composedCrop` and writes ONE `edit_versions` row through
  `EditStore.saveVersion(name: "<preset display name>", kind: "version",
  stack:, for:)` — the current stack is untouched, the grid unchanged, and the
  version appears in Spec 04's switcher like any other. No new write path.

### 3.7 Entry points

All three surface the same request; raster kinds only (`.image`/`.raw`/`.psd` —
the `driveShareURLs` filter):

- **Grid context menu** (`Views/SelectionMenu.swift`): "Export for Social…"
  directly under the existing "Share" item, operating on the effective
  selection; hidden when the selection contains no raster kinds (folders and
  other kinds are excluded by the filter — the effectiveSelection folder
  doctrine).
- **Hero viewer** (`Views/Viewer/ShareButton.swift` menu): "Export for
  Social…" under "Share", for the single displayed file.
- **Collection header** (`ShareCollectionButton` menu): "Export for Social…"
  under "Share Drive Link", over `driveShareURLs` (the visible set — matches
  what the user sees, the collapsed-stacks export rule).

### 3.8 Localization

Every string in §3 (preset display names, warnings, card copy, error strings)
is a `String(localized:)`/literal-position string at introduction; preset
`nameKey`s that are brand names ("Threads", "Glass", "X") still route through
the catalog (translation = identity) so the French export pass reports 0
untranslated. Feature is incomplete until that pass runs clean (house rule).

---

## 4. Google on-ramp polish

### 4.1 Signed-out explainer in the publish flow (`DriveShareForm.swift`)

When `service.isSignedIn == false` and the phase is `.idle`, the sheet shows —
**above the form, not instead of it** (the user can read the form they're about
to fill) — a compact explainer box:

- Title: "Your photos, your Drive."
- Body (localized, fixed copy): *"Publishing uploads the selected images to
  your own Google Drive and creates a private web page link. Muse's developer
  never sees or receives your photos. Location and camera metadata are removed
  from every uploaded image."*
- A "Continue with Google" `ModalButton` (prominent) that runs
  `auth.signIn()` directly (with the shipped busy-guard pattern from
  `SettingsView.runAuth`) so sign-in problems surface BEFORE the user has
  filled the form and pressed Publish. Publish itself still handles the
  signed-out case exactly as today (`.signingIn` mid-run) — the explainer is
  additive, not a new gate.
- A trailing footnote line answering the download-originals question in copy
  (DECIDED: explain, don't build): *"Recipients view web-sized images. To give
  someone the original files, share them from your own Google Drive."*

### 4.2 Unverified-scope messaging

Until Google's OAuth verification completes, the consent screen shows an
"unverified app" interstitial. `DriveConfig` gains
`static let consentScreenVerified = false` (owner flips it at §10 time). While
false, the explainer (and the Settings footer, §4.3) append: *"Google may show
an 'unverified app' step while Muse's verification is in review — choose
Advanced → Continue to proceed."* When true, the line vanishes. A constant,
not a Settings key — it describes the developer's console state, not a user
preference.

### 4.3 Settings copy (`SettingsView.swift` Google Drive section)

The existing footer sentence is extended with the same two facts (your-Drive/
never-ours + the unverified note while applicable), and the section gains a
static caption row when signed in: "Signed in — photos upload to your own
Drive." No new stored state; the section's sign-in/out mechanics are untouched.

---

## 5. What Spec 07 explicitly does NOT change

- **Every shipped Drive security invariant**: `drive.file` scope exactly; PKCE,
  no client secret; Keychain-only device-only tokens; metadata strip on every
  image upload (fail-closed, re-verify via `isClean`, single-frame re-encode /
  multi-frame lossless rules); `MAX_INFLATED` bomb cap; `sanitizeText` +
  per-field caps + id bounds; `textContent`-only rendering; mime token
  validation in `multipartBody`; Open-Link `shareBaseURL` prefix validation;
  cancel-on-dismiss; generation-guarded phases; fresh-Task cleanup.
- The **fragment-only privacy property of classic shares** — a non-portfolio
  publish still sends nothing but images to Drive and nothing at all to the
  page host. Only portfolios add the (user-owned, user-initiated) manifest
  file.
- **App network doctrine**: portfolio publish/update rides the existing Drive
  path (user-initiated). The page's manifest fetch is recipient-browser
  traffic, not an app network path — the four-path list in DECISIONS is
  unchanged.
- Expiry semantics of classic shares; `DriveExpirySweeper`; `DriveExpiry`.
- `OutputRender`'s contract, `ImageMetadataStripper`'s behavior, backup's
  exclusion from export rendering.
- `AppState` (beyond the one sanctioned flag), the status pill, search,
  analysis, migrations, `ThumbnailCache.renderedVariants`.
- The share page's zero-dependency stance (fflate remains the only vendored
  module; no new libraries).

---

## 6. Performance (recorded, never asserted — `PerfBaseline` rows)

| Row | Budget (recorded) |
|---|---|
| Social export, 24 MP → IG Feed Portrait (crop, standard sharpen) | 1.5 s |
| Social export, 24 MP → X (longEdge 4096, ladder to <5 MB) | 4 s |
| Carousel export, 10 × 24 MP | 15 s |
| Crop-stage preview decode (2048) | 250 ms |
| Byte-target ladder iterations, IG preset, 24 MP | ≤ 3 encodes |
| Portfolio update, 30 images (network-bound) | recorded, no target |
| share.js: fetched-manifest accept + re-render, 100 tiles | recorded manually (not CI) |

---

## 7. New durable constraints (added to `CLAUDE.md` on merge)

1. **The share page makes exactly ONE kind of network fetch** — the portfolio
   `manifest.json` GET to `www.googleapis.com`, `connect-src`-pinned, API-key
   quota-only + referrer-restricted, bounded read (`MAX_MANIFEST_BYTES`),
   re-validated via `validateManifest(_, {portfolio: true})`, `m`-stripped
   (never chained), inline-snapshot fallback always present. The key is NOT a
   secret; a real secret or OAuth credential on the page stays forbidden.
2. **`e` stays required for non-portfolio manifests** (fail-open guard);
   `m`-present manifests never expire and never consult `e`. Don't loosen the
   first to "optional" — an absent expiry on a classic share must fail
   validation, not become eternal.
3. **`uploadManifest` is the only non-image Drive upload and must stay
   JSON-typed and narrowly named** — image bytes reach Drive exclusively
   through `uploadFile`'s strip-verified path.
4. **Portfolio records use the `neverExpires` sentinel, not an optional
   expiry** — an optional would make new records undecodable by prior builds,
   whose failed `load()` silently drops the whole share list on next save.
5. **Portfolio update order is upload-new → swap manifest → delete-old** — the
   manifest `files.update` is the atomic cutover; reordering shows recipients
   a manifest whose images are gone.
6. **Social export renders through `OutputRender.forOutput` first** (edited
   pixels), never upscales, bakes orientation at decode, and default-metadata
   outputs must pass `ImageMetadataStripper.isClean` before writing. The X
   preset's five invariants (≤4096², <5 MB, RGB/no-alpha, no orientation tag,
   bytes < W×H) are test-pinned — don't trade them for quality.
7. **Nothing in the social export card persists unless the user explicitly
   saves a version** — no master-crop writes, no auto-accumulated versions,
   no remembered per-image state. The remembered bits are exactly: last
   preset-family EXIF choices, matte shade, share layout.
8. **Manifest v2 keys are optional-only** — a manifest without new features
   must encode with none of the new keys, and legacy fragments must decode
   forever (pinned by tests both sides).

---

## 8. Tests

**Swift (`MuseTests`, pure-logic house rule):**

- `DriveShareManifestTests` (extend): v2 round-trip with `y`/`s`/`m`; a
  manifest with nil new fields encodes JSON containing **no** `y`/`s`/`m` keys;
  legacy fragment fixtures decode unchanged; portfolio manifest with
  `expiry: ""` round-trips; `jsonData()` parses as the same object;
  `maxImages`/`maxFieldLength` guards.
- `DriveShareStoreTests` (extend): a pre-Spec-07 `driveShares.json` fixture
  decodes (all new fields nil); records with new fields round-trip;
  `portfolio(forCollectionID:)` filters and sorts; `DriveExpiry.expired`
  never returns a `neverExpires` record; upsert-by-folderID replaces a
  portfolio record in place.
- `DriveMultipartTests` (extend): `uploadManifest` body shape (json part,
  `application/json` mime pinned); `listChildren` query construction;
  `updateManifest` path/method (pure request-builder assertions).
- `SocialPresetTests` (new): pins the ENTIRE table — every id, dims, quality,
  byte target, sharpen level, EXIF default, uniformMulti, safe-zone flag —
  against the pre-spec values; exactly 12 presets; ids unique.
- `SocialCropMathTests` (new): zoom-1 center = maximal aspect-fill rect; rect
  never exits the unit square under extreme centers; exact target aspect at
  every zoom; `composedCrop` against nil and against a pre-existing crop;
  degenerate sizes → clamped, never NaN.
- `SocialRenderTests` (new, fixture-driven): matte output dims exactly equal
  preset dims (both shades); crop output dims exact; longEdge cap honored;
  never-upscale (small source keeps native size); sRGB profile embedded; no
  alpha channel; EXIF-oriented fixture renders rotated pixels with NO
  orientation tag in the output; byte-target ladder terminates and lands under
  target on a compressible fixture; sharpen level measurably changes bytes
  between `.none`/`.standard` (distinctness, not quality).
- `SocialMetadataTests` (new): default output passes
  `ImageMetadataStripper.isClean`; EXIF-on keeps camera make/model + IPTC,
  drops GPS and orientation; `includeLocation` keeps GPS; maker
  notes/thumbnails always dropped.
- `XPresetRuleTests` (new): the five §3.4 invariants on fixtures including a
  6000-px source and a synthetic high-entropy image that forces the ladder.
- `SharingTierTests` (new): unenforced → always available; enforced flag flips
  the entitlement read.

**Node (`web/share/share.test.mjs`, extend):**

- v2 acceptance: `y`/`s`/`m` optional; oversized `s` rejected; malformed `m`
  rejected; `layoutOf` maps `sheet`/`essay` and falls back to `grid` on
  absent/unknown values.
- Expiry rules: classic share without `e` still rejected (the pinned fail-open
  guard); `m`-present manifest without `e` accepted; portfolio ignores a stale
  `e`.
- `acceptFetchedManifest`: valid body accepted; body over `MAX_MANIFEST_BYTES`
  rejected; invalid JSON → null; embedded `m` stripped (no chaining); a body
  failing `validateManifest` → null.
- `manifestFetchURL` interpolation safety rides the existing `VALID_ID`
  charset pins.
- Every existing test still passes unmodified (legacy decode, bomb cap,
  sanitize, id charset — the regression floor).

**Compile-time:** social export cannot obtain pixels except through
`OutputRender` (the `RenderedOutput` fileprivate-init enforcement — no new
test needed; it's the type system, per Spec 01).

---

## 9. Build order (each step leaves the app releasable)

1. **Layout options.** Manifest v2 (`y`/`s`) + app guards; share.js
   `layoutOf`/validation + the three CSS layouts + `#body` node; form picker +
   `AppSettings.driveShareLayout`; Swift + node tests; deploy Pages. (No `m`
   yet — classic shares only.)
2. **Google on-ramp.** Explainer + unverified messaging + Settings copy.
   Small, independent.
3. **Portfolio.** `DriveClient` additions → record/store growth →
   `publishPortfolio`/`updatePortfolio` → page fetch (`m`, API key,
   `connect-src`) → `ShareCollectionButton` menu + sheet modes + Manage
   badges → `SharingTier` seam → tests both sides → deploy Pages + owner key
   step.
4. **Social export.** `Export/Social/` module (presets → crop math → metadata
   → render, with tests at each) → step 0 `OutputRender` if Spec 01 is
   unbuilt → card + `socialExportRequest` + three entry points → X invariants
   + fixtures → French pass.

---

## 10. Owner-only steps

- **Create the browser API key** (Google Cloud console, same project as the
  OAuth client): API restriction = Google Drive API only; application
  restriction = HTTP referrers `https://muse-share.pages.dev/*` (plus the
  Spec 08 domains when they exist). Paste into `share.js` at deploy. Rotating
  it later is a one-line redeploy.
- **Deploy** `web/share/` (share.js, share.css, index.html, `_headers`) to
  Cloudflare Pages after steps 1 and 3.
- **X no-recompress protocol** (manual, once per X-preset change): export a
  photo via the X preset → post it from x.com → download the posted image
  (`?name=orig`) → `cmp` against the exported file. Byte-identical = the
  marketing line is earned. Record the date + result in the session log.
- **Validate the preset table against current platform docs at ship time**
  (IG/Threads/X/FB/Pinterest/Flickr/Glass specs drift; the table is
  test-pinned so any change is a deliberate constant edit).
- **Flip `DriveConfig.consentScreenVerified`** when Google verification
  completes.
- **Portfolio tier enforcement** waits for Spec 09's pricing decision
  (`SharingTier.enforced`).
- Owner look-pass on the three page layouts and the crop card (visual
  judgment; the specs pin behavior, not taste).

---

## 11. Deliberate deviations (recorded, per house convention)

- **D1 — an API key ships in share.js** (revises the "no API key" line of the
  shipped Drive invariants). Required by the only CORS-viable public-file
  endpoint; quota-only, dual-restricted, grants nothing non-public; the
  no-secret invariant is retained and restated (§7.1). The old absolute
  wording is replaced by the precise one on merge.
- **D2 — one new AppState `@Published`** (`socialExportRequest`), the
  sanctioned shell-modal-flag class (Spec 04's `openWithForkRequest`
  precedent). Net AppState growth: +1 flag, registered in `modalPresented`.
- **D3 — CSP gains `connect-src https://www.googleapis.com`** (was
  connect-less `default-src 'none'`). Exactly one origin, for exactly one
  fetch, with app-side and page-side bounds.
- **D4 — sentinel expiry instead of `Date?`** on `DriveShareRecord` (§2.5):
  optionalizing would brick the previous build's decoder and silently drop the
  user's share list. Old builds render a year-2100 date; harmless.
- **D5 — the pre-spec's open "replace contents / link versioning" choice is
  resolved as the Drive-pointer manifest** (§2.1). Recorded limitation: a
  portfolio link opened OFFLINE (or if the fetch ever breaks) renders the
  inline snapshot — last-published state, and after an update that snapshot's
  image ids are dead (tiles show as unloadable). The live-fetch path never has
  this problem; re-copying the link after an update refreshes the snapshot.
- **D6 — GPS is a separate opt-in even when the EXIF toggle is on** (§3.5).
  The foundation table is silent on GPS; gear metadata and location carry
  different risk, so they get different switches. Default OFF.
- **D7 — a global never-upscale rule** (§3.3). The foundation's "exactly
  1080w" IG delivery note applies when the source is at least that large;
  inflating an 800-px image to 1080 manufactures softness IG then recompresses
  — strictly worse. The card states when it applies.
- **D8 — the >1000-image publish guard** (§1.1) is new app-side behavior: the
  shipped app could mint a link its own page rejects. Fixing it is required
  for the layouts/portfolio acceptance ("all three layouts render from
  fragment-only data") to be honest at the cap.

---

## 12. Acceptance mapping (from `pre-spec-07-sharing-social-export.md` §Acceptance)

| Pre-spec acceptance line | Where satisfied |
|---|---|
| All three layouts render from fragment-only data | §1.2–§1.3 (`y` in the fragment; CSS-only rendering; no fetch for classic shares) |
| Existing links keep working (legacy manifest decode preserved) | §1.1 optional-only keys + §1.2 additive validation; pinned by Swift + node legacy tests (§8) |
| Bomb cap intact | `MAX_INFLATED` untouched (§5); existing node test still green (§8) |
| share.test.mjs extended and green | §8 node section |
| Portfolio link survives a content update without changing URL, zero server state | §2.1 pointer design; §2.7 update flow (URL literally unchanged — `manifestFileID` stable); state lives only in the user's Drive |
| Export of an edited RAW goes out WITH edits applied (choke-point verified) | §3.3 step 1 (`OutputRender.forOutput` first); compile-time enforcement per Spec 01; verifiable end-to-end once Spec 04 lands (§0 dependency note) |
| X preset output verifiably survives upload without recompression (byte-compare manual protocol) | §3.4 invariants + `XPresetRuleTests`; §10 manual protocol |
| Matte export matches target dims exactly | §3.2 matte definition; `SocialRenderTests` exact-dims pin (§8) |
| Carousel enforces uniform ratio | §3.1 `uniformMulti` + §3.6 locked pager frame |
| Temporary crop persists nothing | §3.6 temporary-by-default rule + §7.7 durable constraint; save-as-version is the explicit opt-in through Spec 04's existing seam |
| Google on-ramp: clear explanation, guided sign-in, unverified messaging | §4.1–§4.3 |
