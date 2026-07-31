# Spec 07 — Share Page Expansion & Social Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship three share-page layouts (grid / contact sheet / essay) chosen at publish
time; **portfolio mode** — a persistent, non-expiring Drive share that is updatable in
place at a stable URL with zero server state; **social export presets** — 12 platform
presets with interactive in-flow crop, Matte/Blur-extend fit modes, output sharpening,
sRGB/baked-orientation JPEG delivery, the X no-recompress target, and metadata stripped
by default with a photography-platform EXIF toggle; and **Google on-ramp polish** — a
clear signed-out explainer, guided sign-in, and unverified-scope messaging. All four
build on the shipped Drive collection-share feature (Polish 18, already in the tree)
without touching its security invariants.

**Architecture:** `DriveShareManifest` grows three optional wire keys (`y` layout, `s`
body text, `m` portfolio manifest pointer) — every new field defaults to nil so legacy
fragments decode forever and a manifest not using a feature encodes none of the new
keys. The share page (`web/share/`) renders all three layouts off one `data-layout`
CSS attribute through the SAME tile-builder DOM path (no new construction), and gains
exactly one new network capability — a bounded, revalidated GET of a portfolio's live
`manifest.json` from the user's own Drive. `Export/Social/` is a new platform-neutral
module (no AppKit) holding the preset table, crop math, metadata policy, and render
pipeline; pixels enter through `OutputRender.forOutput` (Spec 01's export choke point,
built here as a scoped prerequisite since no Spec 01–06 code exists in this tree yet).
The social export card is a new shell-modal card (`AppState.socialExportRequest`, the
one sanctioned new `@Published` flag) presented via the existing `.museModal` pattern.
Portfolio and classic Drive shares share one publish/update service
(`DriveShareService`), one local record store (`DriveShareStore`/`driveShares.json`,
never SQLite), and one shell-modal payload (`CollectionModal.driveShare`).

**Tech Stack:** Swift 5 (MainActor default isolation) + SwiftUI/AppKit, GRDB 7.10 (no
new tables — this spec adds zero migrations), Foundation/CoreGraphics/CoreImage/
ImageIO/UniformTypeIdentifiers for `Export/Social/` (no AppKit — enforced by grep-style
module tests, the `Editing/`-import-rule class), vanilla JS (ES modules, no framework,
no new dependency) for `web/share/`, XCTest (pure-logic only, house convention — no UI
unit tests) + a Node test runner (`web/share/share.test.mjs`, already in the tree).

## Global Constraints

- **Migrations: NONE.** This spec never touches `Database/`. Social export writes no
  rows (an explicitly saved crop rides Spec 04's `edit_versions` seam, when Spec 04
  exists — absent, not disabled, otherwise). Portfolio records ride the existing
  `driveShares.json` (`DriveShareStore`), never SQLite. Future specs still continue at
  **v24**.
- **Every shipped Drive security invariant stays exactly as shipped**: `drive.file`
  scope; PKCE, no client secret; Keychain-only device-only tokens; the metadata strip
  on every image upload (fail-closed, re-verified via `isClean`); `MAX_INFLATED` bomb
  cap; `sanitizeText` + per-field caps + id bounds; `textContent`-only rendering; mime
  token validation in `multipartBody`; Open-Link `shareBaseURL` prefix validation;
  cancel-on-dismiss; generation-guarded phases; fresh-Task cleanup. Nothing in this
  plan relaxes any of them — the deviations below (D1–D8) are additive, recorded, and
  narrowly scoped.
- **`uploadFile` (image bytes) is untouched in this plan.** It remains the ONLY way
  image bytes reach Drive, strip-verified fail-closed, called with the exact same
  `(url:name:mime:parent:)` signature it ships with today. The new `uploadManifest`/
  `updateManifest` calls are JSON-typed and narrowly named specifically so they cannot
  become a strip bypass — see Task 3.1.
- **`e` (expiry) stays required for non-portfolio manifests** — the fail-open guard.
  Only a manifest carrying `m` (a portfolio) is allowed to omit/ignore it. Never loosen
  this to "optional in general."
- **Portfolio records use a sentinel expiry (`DriveShareRecord.neverExpires`,
  2100-01-01), never an optional `Date`** — an optional would make new records
  undecodable by a prior build, whose failed `load()` silently drops the WHOLE share
  list on next save (Deviation D4).
- **Manifest v2 keys (`y`, `s`, `m`) are optional-only, nil-default.** A manifest not
  using a feature must encode with none of the new keys present (synthesized `Codable`
  `encodeIfPresent` on `Optional` properties gives this for free — verify, don't
  assume). Pinned by tests on BOTH the Swift and Node sides.
- **Portfolio update order is binding: upload-new images → `updateManifest` (the atomic
  cutover) → delete-old (list-driven sweep).** Reordering shows recipients a manifest
  whose images are gone. Never reorder this in review or "simplify."
- **Social export renders through `OutputRender.forOutput` FIRST**, never upscales,
  bakes orientation at decode (no output orientation tag can ever exist), and
  default-metadata outputs must pass `ImageMetadataStripper.isClean` before writing.
  The X preset's five invariants (≤4096², <5 MB, RGB/no-alpha, no orientation tag,
  bytes < W×H) are test-pinned — never trade them for quality.
- **Nothing in the social export card persists unless the user explicitly saves a
  version.** No master-crop writes, no auto-accumulated versions, no remembered
  per-image state. The only remembered bits: last preset-family EXIF choices
  (`AppSettings.socialExifChoices`), matte shade (`AppSettings.socialMatteShade`), and
  share layout (`AppSettings.driveShareLayout`). The location (GPS) sub-toggle is NEVER
  remembered — always reverts to OFF (Deviation D6).
- **`Export/Social/` is platform-neutral: Foundation / CoreGraphics / CoreImage /
  ImageIO / UniformTypeIdentifiers only — never AppKit.** `Components/SocialCropMath.swift`
  is pure math, same rule. This mirrors the `Editing/`-module import rule (DECISIONS
  "Architecture & module structure").
- **`AppState` gets exactly one new `@Published` property** (`socialExportRequest`),
  the sanctioned shell-modal-flag class already used by `collectionModal` — Deviation
  D2. No other `AppState` growth anywhere in this plan.
- **House test convention: no UI unit tests.** All new Swift tests are pure-logic
  (nonisolated enum/struct functions or fixture-driven render assertions), added to the
  `MuseTests` target. Node tests extend `web/share/share.test.mjs`.
- **French localization is a hard requirement for every new user-facing string** — every
  literal is a SwiftUI text-literal position or `String(localized:)`. The build isn't
  done until an `-exportLocalizations -exportLanguage fr` pass reports 0 untranslated
  for new keys (Task 5.2). Preset `nameKey`s that are brand names ("Threads", "Glass",
  "X") still route through the catalog (translation = identity) so the pass reports 0
  untranslated for them too.
- **`BUILD SUCCEEDED` is not proof of a working build** — `stat` the `.app`'s executable
  mtime before handing off any milestone for visual/manual verification (stale
  DerivedData/signing issue, documented in CLAUDE.md).
- **Fix the code, not the dev DB/library.** This plan touches no user data migration
  paths; if a test fixture or a running-app check surfaces a data problem, fix the code.
- Codebase note: verified present at plan-writing time (`plan-1` branch, 2026-07-30) —
  no Spec 01–06 code exists yet (no `EditStackIndex`/`EffectiveDimensions`/
  `OutputRender`/`Editing/`/`Export/Social/`/`Commerce/` in the tree; `Export/` holds
  only `CollectionPDFExporter.swift`/`CollectionPDFLayout.swift`/`PaperSize.swift`).
  The shipped Drive feature (Polish 18, `Sharing/Drive/`, `web/share/`, the
  `ManageDriveSharesView`/`ShareCollectionButton`/`DriveShareForm.swift`/
  `Modal/ModalChrome.swift` UI) IS in the tree and verified read in full — see file
  notes inline at each task below. File line numbers cited are from that direct read;
  re-confirm with a fresh `grep -n` before editing, since the tree may move between
  commits.
- **Naming correction vs. the source spec doc:** `docs/new-build/spec-07-implementation.md`
  refers to "`Views/DriveShareForm.swift`'s `DriveShareForm` struct." In the ACTUAL
  current tree, the plain value-type struct `DriveShareForm { intro, label, name, date,
  expiry }` lives in `Sharing/Drive/DriveShareService.swift` (lines 15–21); the SwiftUI
  sheet view in `Views/DriveShareForm.swift` is named `DriveShareSheet`. Every task
  below uses the verified real names.

## Dependencies & sequencing

Transcribed verbatim from spec-07-implementation.md §0:

| Dependency | Needed by | Nature |
|---|---|---|
| Shipped Drive share (`Sharing/Drive/`, `web/share/`, Polish 18) | everything in §1–§2, §4 | **Hard** — already in the tree. All security invariants carry. |
| Spec 01 §3.4 (`OutputRender` choke point) | §3.3 (social export renders through it) | **Hard.** If Spec 07 builds before Spec 01, it builds `Export/OutputRender.swift` to Spec 01's text verbatim as step 0 (the Spec 04 §13 convention) — identity behavior today, edit-aware when Spec 04 lands. |
| Spec 04 (`EditStack`, `EditStore.saveVersion`, `EditRenderer`) | the §3.6 "save crop as version" affordance; the edited-pixels acceptance ("export of an edited RAW goes out WITH edits applied") | **Soft/severable.** Social export compiles and ships without Spec 04 — `OutputRender.forOutput` is identity, the save-as-version button is **absent, not disabled** (house rule). The acceptance line is only *verifiable* once Spec 04 exists. |
| Spec 01 commerce (`CommerceStore`) | §2.9 portfolio tier seam | **Soft.** `SharingTier` reads it when present; computes-but-never-blocks until Spec 09 either way. |
| Specs 02/03/05/06 | nothing | None. |

**Resolution for this plan:** confirmed via direct repo inspection (2026-07-30, `plan-1`
branch) that no Spec 01 code exists in the tree — `find` for `*OutputRender*`,
`*EditStack*`, `*EditStore*` returns nothing, and `Muse/Muse/Commerce/` does not exist.
So **Phase 0 below builds `Export/OutputRender.swift` as a prerequisite**, to Spec 01's
exact text (`docs/superpowers/plans/2026-07-30-spec-01-foundation-plumbing.md` Task 16,
itself verified against `spec-01-implementation.md` §3.4). Spec 01's Task 16 also
converts four existing call sites (`CollectionPDFExporter.imageIOThumbnail`,
`DriveClient.uploadFile`, `SelectionMenu.swift`, `ShareButton.swift`) to route through
`OutputRender`/`RenderedOutput`. **This plan deliberately does NOT replicate those four
conversions** — spec-07-implementation.md itself states plainly that `uploadFile`
"remains the only way image bytes reach Drive" and is untouched by this spec, and
neither classic Drive shares nor portfolio publishing need edit-aware pixels (only
Social export does, and Social export calls `OutputRender.forOutput` directly inside
its own pipeline, per §3.3). Converting the four shipped call sites is Spec 01's own
scope; doing it here would be unrequested surface area with no consumer in this plan.
Phase 0 therefore builds exactly the minimal subgraph `OutputRender.swift` needs to
compile and be independently useful to Social export: `Models/EditStackIndex.swift`
(the identity-function seam `OutputRender.forOutput` calls into) + `Export/OutputRender.swift`
themselves, both verbatim from spec-01, with their own tests — and stops there. This is
a deliberate scoping decision, not an oversight; it is called out again at Task 0.2.

Spec 04's `EditStore.saveVersion` and `EditRenderer` do not exist in this tree either.
Per the table above this dependency is soft/severable: Task 4.9 ("Save Crop as
Version") is written as an `#if false`-documented, absent-not-disabled affordance with
the exact call it will make once Spec 04 lands, matching the house rule used throughout
this series (e.g. Spec 04's own Task 9's Edit-a-Copy fork card being absent until its
prerequisites exist).

---

## File Structure

| File | Responsibility |
|---|---|
| `Muse/Muse/Models/EditStackIndex.swift` (new, Phase 0) | Identity-function stack-hash seam; `OutputRender` consults it. Spec 01 verbatim. |
| `Muse/Muse/Export/OutputRender.swift` (new, Phase 0) | Export choke point — the only way to obtain `RenderedOutput`; identity today. Spec 01 verbatim (scoped: no call-site conversion). |
| `Muse/Muse/Sharing/Drive/DriveShareManifest.swift` (modify) | v2 wire fields `y`/`s`/`m`, `DriveShareLayout` enum, `jsonData()`, publish-time caps. |
| `Muse/Muse/Sharing/Drive/DriveShareRecord.swift` (modify) | Portfolio fields (`kind`/`manifestFileID`/`collectionID`/`layout`/`introTitle`/`bodyText`), `neverExpires` sentinel, `DriveShareStore.portfolio(forCollectionID:)`. |
| `Muse/Muse/Sharing/Drive/DriveClient.swift` (modify) | `uploadManifest`, `updateManifest`, `listChildren` additions. `uploadFile` untouched. |
| `Muse/Muse/Sharing/Drive/DriveShareService.swift` (modify) | `DriveShareForm` grows `layout`/`bodyText`; new `DriveShareMode`/`DriveShareRequest`; `publishPortfolio`/`updatePortfolio` methods; publish guard for the 1000-image/field-length cap. |
| `Muse/Muse/Sharing/Drive/DriveConfig.swift` (modify) | `consentScreenVerified` constant. |
| `Muse/Muse/Views/DriveShareForm.swift` (modify — struct name `DriveShareSheet`) | Layout picker, Intro field, signed-out explainer, portfolio mode branching, unverified-scope note. |
| `Muse/Muse/Views/ManageDriveSharesView.swift` (modify) | Portfolio "Portfolio" capsule tag + "Never" expires column. |
| `Muse/Muse/Views/ShareCollectionButton.swift` (modify) | Menu grows Publish/Update/Copy Portfolio Link + "Export for Social…"; builds `DriveShareRequest`. |
| `Muse/Muse/Views/Sidebar/CollectionSidebarRow.swift` (modify) | Second `.driveShare` call site updated to the new `DriveShareRequest` payload shape. |
| `Muse/Muse/Views/Modal/ModalChrome.swift` (modify) | `CollectionModal.driveShare` case retyped to carry `DriveShareRequest`; `id`/`width` updated. |
| `Muse/Muse/ContentView.swift` (modify) | `.driveShare` switch-case pattern match updated to the new payload shape. |
| `Muse/Muse/Models/AppState.swift` (modify) | +1 `@Published socialExportRequest: SocialExportRequest?`; `modalPresented` gains one clause. |
| `Muse/Muse/Settings/AppSettings.swift` (modify) | `driveShareLayout`, `socialExifChoices`, `socialMatteShade` keys. |
| `Muse/Muse/Settings/SettingsView.swift` (modify) | Google Drive section footer extended + "Signed in — photos upload to your own Drive" caption row. |
| `web/share/share.js` (modify) | `layoutOf`, `SIZER_BY_LAYOUT`, `validateManifest` v2 + portfolio rules, `manifestFetchURL`, `acceptFetchedManifest`, portfolio fetch render glue. |
| `web/share/index.html` (modify) | `#body` node. |
| `web/share/share.css` (modify) | `[data-layout="sheet"]`/`[data-layout="essay"]` CSS. |
| `web/share/_headers` (modify) | `connect-src https://www.googleapis.com` added to CSP. |
| `Muse/Muse/Export/Social/SocialPreset.swift` (new) | The 12-preset table, pure data. |
| `Muse/Muse/Components/SocialCropMath.swift` (new) | Pure crop-rect + composed-crop math. |
| `Muse/Muse/Export/Social/SocialMetadata.swift` (new) | Output EXIF/IPTC/GPS policy. |
| `Muse/Muse/Export/Social/SocialRender.swift` (new) | The fixed render pipeline + X invariants. |
| `Muse/Muse/Views/Export/SocialExportCard.swift` (new) | The crop/export card UI + `SocialExportModel`. |
| `Muse/Muse/Commerce/SharingTier.swift` (new) | Pure tier-gate seam, unenforced until Spec 09. |
| `Muse/MuseTests/EditStackIndexTests.swift` (new) | Phase 0. |
| `Muse/MuseTests/OutputRenderTests.swift` (new) | Phase 0. |
| `Muse/MuseTests/DriveShareManifestTests.swift` (modify) | v2 round-trip, legacy decode, portfolio, `jsonData()`, caps. |
| `Muse/MuseTests/DriveShareStoreTests.swift` (new or modify — verify existence first) | Record growth, sentinel, portfolio lookup, upsert. |
| `Muse/MuseTests/DriveMultipartTests.swift` (modify — verify existence first) | `uploadManifest`/`updateManifest`/`listChildren` request-builder assertions. |
| `Muse/MuseTests/SocialPresetTests.swift` (new) | Pins the entire 12-preset table. |
| `Muse/MuseTests/SocialCropMathTests.swift` (new) | Crop math correctness. |
| `Muse/MuseTests/SocialRenderTests.swift` (new) | Fixture-driven pipeline assertions. |
| `Muse/MuseTests/SocialMetadataTests.swift` (new) | EXIF/GPS policy assertions. |
| `Muse/MuseTests/XPresetRuleTests.swift` (new) | The five X invariants. |
| `Muse/MuseTests/SharingTierTests.swift` (new) | Tier-gate seam. |
| `web/share/share.test.mjs` (modify) | v2/portfolio/manifest-fetch Node tests. |
| `CLAUDE.md` (modify, Phase 5) | Durable constraints + Implementation status row. |

---

## Phase 0 — Prerequisite: `OutputRender` export choke point

*Spec 01 does not exist in this tree. These two tasks build exactly the subgraph Social
export needs, verbatim from `docs/superpowers/plans/2026-07-30-spec-01-foundation-plumbing.md`
Tasks 13 and 16, with Task 16's four call-site conversions deliberately dropped (see
"Dependencies & sequencing" above). Both tasks are byte-identical in code to their spec-01
source; only the "convert call sites" step is omitted.*

### Task 0.1: `EditStackIndex` — the stack-hash seam (identity function today)

**Files:**
- Create: `Muse/Muse/Models/EditStackIndex.swift`
- Create: `Muse/MuseTests/EditStackIndexTests.swift`

**Interfaces:**
- Produces: `EditStackIndex.stackHash(for: URL) -> String?`,
  `EditStackIndex.croppedSize(for: URL) -> CGSize?`,
  `EditStackIndex.installProvider(_: (any EditStackProviding)?)`, and the
  `EditStackProviding` protocol.
- Consumes: nothing.

- [ ] **Step 1: Write the failing tests**

```swift
//
//  EditStackIndexTests.swift
//  MuseTests
//
//  Identity-function seam today (no provider installed = nil everywhere).
//  Spec 04 installs a real provider; every consumer of this type is already
//  wired correctly when that happens.
//

import XCTest
@testable import Muse

final class EditStackIndexTests: XCTestCase {
    override func tearDown() {
        EditStackIndex.installProvider(nil)
        super.tearDown()
    }

    func testNilProviderReturnsNilHashAndSize() {
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        XCTAssertNil(EditStackIndex.stackHash(for: url))
        XCTAssertNil(EditStackIndex.croppedSize(for: url))
    }

    func testInstalledProviderIsConsulted() {
        struct StubProvider: EditStackProviding {
            func stackHash(for url: URL) -> String? { "abc123" }
            func croppedSize(for url: URL) -> CGSize? { CGSize(width: 100, height: 200) }
        }
        EditStackIndex.installProvider(StubProvider())
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        XCTAssertEqual(EditStackIndex.stackHash(for: url), "abc123")
        XCTAssertEqual(EditStackIndex.croppedSize(for: url), CGSize(width: 100, height: 200))
    }

    func testProviderRemovalRestoresIdentity() {
        struct StubProvider: EditStackProviding {
            func stackHash(for url: URL) -> String? { "abc123" }
            func croppedSize(for url: URL) -> CGSize? { nil }
        }
        EditStackIndex.installProvider(StubProvider())
        EditStackIndex.installProvider(nil)
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        XCTAssertNil(EditStackIndex.stackHash(for: url))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/EditStackIndexTests`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Implement `EditStackIndex`**

```swift
//
//  EditStackIndex.swift
//  Muse
//
//  The identity of a file's non-destructive edit stack. nil = unedited
//  (original bytes). Identity function today (no provider installed);
//  Spec 04 installs the real (file, parent_dir)-keyed provider and every
//  consumer (ThumbnailCache, EffectiveDimensions, OutputRender) is already
//  correct. Keyed by URL, NOT files.id — an edit stack is per file LOCATION
//  like tags/notes, since files.content_hash is UNIQUE and a column there
//  would force one stack to be shared by the same photo in two folders.
//

import Foundation
import CoreGraphics

protocol EditStackProviding: Sendable {
    func stackHash(for url: URL) -> String?
    func croppedSize(for url: URL) -> CGSize?
}

enum EditStackIndex {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var provider: (any EditStackProviding)?

    static func stackHash(for url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        return provider?.stackHash(for: url)
    }

    static func croppedSize(for url: URL) -> CGSize? {
        lock.lock(); defer { lock.unlock() }
        return provider?.croppedSize(for: url)
    }

    /// Test/Spec-04 seam: install the real provider.
    static func installProvider(_ p: (any EditStackProviding)?) {
        lock.lock(); defer { lock.unlock() }
        provider = p
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/EditStackIndexTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Models/EditStackIndex.swift" "Muse/MuseTests/EditStackIndexTests.swift"
git commit -m "feat(social-export-seam): add EditStackIndex identity seam (Spec 01 verbatim)"
```

### Task 0.2: `OutputRender` export choke point (scoped: no call-site conversion)

**Files:**
- Create: `Muse/Muse/Export/OutputRender.swift`
- Create: `Muse/MuseTests/OutputRenderTests.swift`

**Interfaces:**
- Produces: `struct RenderedOutput { let url: URL; let stackHash: String? }` (fileprivate
  init), `enum OutputRender { static func forOutput(_ url: URL) throws -> RenderedOutput;
  static func forOutput(_ urls: [URL]) throws -> [RenderedOutput]; static func image(_ out:
  RenderedOutput, maxPixel: Int) -> CGImage? }`.
- Consumes: `EditStackIndex.stackHash(for:)` (Task 0.1).

**Deliberately NOT done in this task** (see "Dependencies & sequencing"): converting
`CollectionPDFExporter.imageIOThumbnail`, `DriveClient.uploadFile`, `SelectionMenu.swift`'s
share picker, or `ShareButton.swift`'s share picker to route through `RenderedOutput`.
Those four shipped call sites stay exactly as they are today — `uploadFile` in particular
must remain untouched per spec-07-implementation.md §5. Only `SocialRender` (Task 4.4)
consumes `OutputRender` in this plan.

- [ ] **Step 1: Write the failing tests**

```swift
//
//  OutputRenderTests.swift
//  MuseTests
//
//  forOutput is identity today (renders original bytes). RenderedOutput
//  cannot be constructed outside OutputRender.swift — the ONLY way this
//  test file obtains one is by calling forOutput, which is the compile-time
//  proof the export choke point can't be bypassed.
//

import XCTest
@testable import Muse

final class OutputRenderTests: XCTestCase {
    func testForOutputIsIdentityToday() throws {
        let url = URL(fileURLWithPath: "/tmp/output-test.jpg")
        let out = try OutputRender.forOutput(url)
        XCTAssertEqual(out.url, url)
        XCTAssertNil(out.stackHash)
    }

    func testForOutputArrayPreservesOrder() throws {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.jpg"),
            URL(fileURLWithPath: "/tmp/b.jpg"),
        ]
        let outs = try OutputRender.forOutput(urls)
        XCTAssertEqual(outs.map(\.url), urls)
    }

    func testForOutputCarriesStackHashWhenProviderInstalled() throws {
        struct StubProvider: EditStackProviding {
            func stackHash(for url: URL) -> String? { "zzz" }
            func croppedSize(for url: URL) -> CGSize? { nil }
        }
        EditStackIndex.installProvider(StubProvider())
        defer { EditStackIndex.installProvider(nil) }

        let url = URL(fileURLWithPath: "/tmp/output-test.jpg")
        let out = try OutputRender.forOutput(url)
        XCTAssertEqual(out.stackHash, "zzz")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/OutputRenderTests`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Implement `OutputRender`**

```swift
//
//  OutputRender.swift
//  Muse
//
//  Every path that ships pixels out of the app renders through here. Today
//  it's identity (originals pass through unrendered); Spec 04 renders the
//  edit stack when one exists. RenderedOutput's fileprivate init is the
//  enforcement — a new export/share/publish path physically cannot compile
//  without going through OutputRender. Backup is the one deliberate
//  exclusion: it restores originals by content hash, and rendering edits
//  into it would corrupt the restore.
//
//  Spec 07 scope note: only Export/Social/SocialRender.swift consumes this
//  in the current tree. The shipped Drive uploadFile/CollectionPDFExporter/
//  SelectionMenu/ShareButton call sites are converted by Spec 01 itself,
//  not here — uploadFile in particular must stay untouched by this spec.
//

import Foundation
import CoreGraphics
import ImageIO

/// Bytes approved for leaving the app. The ONLY way to obtain one is
/// OutputRender.
struct RenderedOutput: Sendable {
    let url: URL          // file to read (the original today; a rendered temp later)
    let stackHash: String?
    fileprivate init(url: URL, stackHash: String?) {
        self.url = url
        self.stackHash = stackHash
    }
}

enum OutputRender {
    static func forOutput(_ url: URL) throws -> RenderedOutput {
        RenderedOutput(url: url, stackHash: EditStackIndex.stackHash(for: url))
    }

    static func forOutput(_ urls: [URL]) throws -> [RenderedOutput] {
        try urls.map { try forOutput($0) }
    }

    /// Decoded, downsampled image for a rendering export (PDF / social).
    static func image(_ out: RenderedOutput, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(out.url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/OutputRenderTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Export/OutputRender.swift" "Muse/MuseTests/OutputRenderTests.swift"
git commit -m "feat(social-export-seam): add OutputRender export choke point (Spec 01 verbatim, scoped)"
```

---

## Phase 1 — Share-page layout options (grid / contact sheet / essay)

*Matches spec-07-implementation.md §9 build-order step 1. Adds `y`/`s` (layout, body
text) to the manifest and the `DriveShareLayout` enum, but NOT `m` (portfolio pointer) —
that field is added to the struct here too (it's part of the same verbatim struct block
in §1.1 of the spec) but is never SET until Phase 3. No portfolio behavior ships in this
phase.*

### Task 1.1: `DriveShareManifest` v2 fields (`y`/`s`/`m`) + `jsonData()` + publish caps

**Files:**
- Modify: `Muse/Muse/Sharing/Drive/DriveShareManifest.swift`
- Modify: `Muse/MuseTests/DriveShareManifestTests.swift`

**Interfaces:**
- Produces: `DriveShareManifest.layout: String?`, `.bodyText: String?`,
  `.manifestID: String?` (all nil-default, keys `y`/`s`/`m`); `DriveShareLayout: String,
  CaseIterable, Codable { case grid, sheet, essay }`; `DriveShareManifest.jsonData() ->
  Data`; `DriveShareManifest.maxImages: Int = 1000`, `.maxFieldLength: Int = 4096`.
- Consumes: nothing new (`encoded()`/`decode()`/`pageURL(base:)` are unchanged — the new
  fields ride the same synthesized `Codable`).

- [ ] **Step 1: Write the failing tests**

Read the full existing file first (`Muse/MuseTests/DriveShareManifestTests.swift`, 60
lines) to match its fixture style (`sample` at lines 10-13) before adding. Append these
test functions to the existing `final class DriveShareManifestTests: XCTestCase` body:

```swift
    func testV2FieldsRoundTrip() {
        var m = sample
        m.layout = DriveShareLayout.essay.rawValue
        m.bodyText = "An intro paragraph."
        m.manifestID = "dddddddddddddddddddd"
        let encoded = m.encoded()
        XCTAssertEqual(DriveShareManifest.decode(encoded), m)
    }

    func testNilV2FieldsEncodeNoNewKeys() throws {
        // sample has layout/bodyText/manifestID unset (nil default) — the
        // plain (uncompressed) JSON must contain none of the new keys, so a
        // manifest not using a v2 feature is byte-identical in shape to the
        // pre-Spec-07 wire format.
        let json = try JSONEncoder().encode(sample)
        let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        XCTAssertNotNil(obj)
        XCTAssertNil(obj?["y"])
        XCTAssertNil(obj?["s"])
        XCTAssertNil(obj?["m"])
    }

    func testPortfolioManifestWithEmptyExpiryRoundTrips() {
        var m = sample
        m.expiry = ""
        m.manifestID = "eeeeeeeeeeeeeeeeeeee"
        let encoded = m.encoded()
        let decoded = DriveShareManifest.decode(encoded)
        XCTAssertEqual(decoded?.expiry, "")
        XCTAssertEqual(decoded?.manifestID, "eeeeeeeeeeeeeeeeeeee")
    }

    func testJSONDataParsesAsSameObject() throws {
        var m = sample
        m.layout = DriveShareLayout.sheet.rawValue
        let data = m.jsonData()
        let decoded = try JSONDecoder().decode(DriveShareManifest.self, from: data)
        XCTAssertEqual(decoded, m)
        // jsonData() is plain (uncompressed, un-base64'd) JSON — first byte '{'.
        XCTAssertEqual(data.first, UInt8(ascii: "{"))
    }

    func testMaxImagesAndMaxFieldLengthConstants() {
        XCTAssertEqual(DriveShareManifest.maxImages, 1000)
        XCTAssertEqual(DriveShareManifest.maxFieldLength, 4096)
    }

    func testDriveShareLayoutRawValues() {
        // Wire values — share.js's layoutOf must match these exactly.
        XCTAssertEqual(DriveShareLayout.grid.rawValue, "grid")
        XCTAssertEqual(DriveShareLayout.sheet.rawValue, "sheet")
        XCTAssertEqual(DriveShareLayout.essay.rawValue, "essay")
        XCTAssertEqual(DriveShareLayout.allCases.count, 3)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/DriveShareManifestTests`
Expected: FAIL — `layout`/`bodyText`/`manifestID`/`DriveShareLayout`/`jsonData()`/
`maxImages`/`maxFieldLength` don't exist yet.

- [ ] **Step 3: Implement the v2 fields**

Modify `Muse/Muse/Sharing/Drive/DriveShareManifest.swift`:

```swift
struct DriveShareManifest: Codable, Equatable {
    var intro: String
    var label: String
    var name: String
    var date: String
    var expiry: String      // ISO-8601 yyyy-MM-dd; "" for portfolio manifests (§2)
    var imageIDs: [String]
    var filenames: [String]? = nil   // key "f"; parallel to imageIDs (optional → old links lack it)
    var pdfID: String?
    var layout: String? = nil        // key "y" — DriveShareLayout.rawValue; absent = grid
    var bodyText: String? = nil      // key "s" — intro paragraph (essay header / portfolio intro)
    var manifestID: String? = nil    // key "m" — Drive file id of the live manifest.json (§2, portfolio only)

    enum CodingKeys: String, CodingKey {
        case intro = "i", label = "l", name = "n", date = "d",
             expiry = "e", imageIDs = "g", filenames = "f", pdfID = "p",
             layout = "y", bodyText = "s", manifestID = "m"
    }

    /// App-side caps mirroring the page's validator (share.js MAX_FIELD/MAX_NAME/grid
    /// cap). Enforced at publish time (Task 1.5, Task 3.5) so the app can never mint a
    /// link its own page rejects.
    static let maxImages = 1000
    static let maxFieldLength = 4096

    // ... encoded()/decode()/pageURL(base:)/rawDeflate/rawInflate: UNCHANGED ...

    /// The plain, uncompressed, un-base64'd JSON encoding — the bytes uploaded as
    /// manifest.json for a portfolio share (§2.6). The fragment keeps using encoded()
    /// (base64url + optional DEFLATE) untouched.
    func jsonData() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}

/// The three page layouts. Raw values are the manifest wire values — the page's
/// layoutOf must match them exactly (the two-implementations-one-contract rule class,
/// pinned by tests on both sides — Task 1.2/Task 3.3).
enum DriveShareLayout: String, CaseIterable, Codable {
    case grid, sheet, essay
}
```

Insert `jsonData()` alongside the existing `encoded()`/`decode()`/`pageURL(base:)`
methods (do not remove or reorder those); insert `DriveShareLayout` as a top-level type
in the same file, below `DriveShareManifest`'s closing brace.

- [ ] **Step 4: Run tests, confirm pass**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/DriveShareManifestTests`
Expected: PASS — including all 6 pre-existing tests (legacy decode, filenames round
trip, compressed round trip) unmodified and green.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Sharing/Drive/DriveShareManifest.swift" "Muse/MuseTests/DriveShareManifestTests.swift"
git commit -m "feat(share): add manifest v2 fields (layout, bodyText, manifestID) + jsonData()"
```

### Task 1.2: `share.js` — `layoutOf` + additive `validateManifest` rules for `y`/`s`

**Files:**
- Modify: `web/share/share.js`
- Modify: `web/share/share.test.mjs`

**Interfaces:**
- Produces: `export function layoutOf(m)`.
- Consumes: nothing new. Modifies the existing (verified single-parameter)
  `export function validateManifest(m)`.

Verified current `validateManifest` (377-line file, function at lines 66-90) takes ONE
parameter. This task adds the `y`/`s` checks only — it does NOT add the `opts`/portfolio
parameter or the `m` check yet (that's Task 3.3, matching spec-07's own build order:
"No `m` yet — classic shares only" for this phase).

- [ ] **Step 1: Write the failing tests**

Read the full existing `web/share/share.test.mjs` first to match its style (it imports
from `share.js` and uses Node's built-in `node:test` + `node:assert` — confirm the exact
import pattern via the file's own header before writing). Add:

```js
test('validateManifest: y accepted when absent, valid, or an unknown short string', () => {
  const base = { i: 'x', l: 'x', n: 'x', d: 'x', e: '2026-01-01', g: ['a'.repeat(20)] };
  assert.equal(validateManifest(base), true);                       // no y
  assert.equal(validateManifest({ ...base, y: 'sheet' }), true);     // known
  assert.equal(validateManifest({ ...base, y: 'essay' }), true);     // known
  assert.equal(validateManifest({ ...base, y: 'future-layout' }), true); // unknown, forward-compat
});

test('validateManifest: y rejected when not a short string', () => {
  const base = { i: 'x', l: 'x', n: 'x', d: 'x', e: '2026-01-01', g: ['a'.repeat(20)] };
  assert.equal(validateManifest({ ...base, y: 123 }), false);
  assert.equal(validateManifest({ ...base, y: 'x'.repeat(17) }), false); // >16 chars
});

test('validateManifest: s accepted when absent or within MAX_FIELD, rejected oversized', () => {
  const base = { i: 'x', l: 'x', n: 'x', d: 'x', e: '2026-01-01', g: ['a'.repeat(20)] };
  assert.equal(validateManifest(base), true);
  assert.equal(validateManifest({ ...base, s: 'An intro paragraph.' }), true);
  assert.equal(validateManifest({ ...base, s: 'x'.repeat(4097) }), false);
});

test('layoutOf: maps sheet/essay, falls back to grid on absent or unknown', () => {
  assert.equal(layoutOf({}), 'grid');
  assert.equal(layoutOf({ y: 'grid' }), 'grid');
  assert.equal(layoutOf({ y: 'sheet' }), 'sheet');
  assert.equal(layoutOf({ y: 'essay' }), 'essay');
  assert.equal(layoutOf({ y: 'unknown-future-value' }), 'grid');
});
```

Add the corresponding `import` names (`layoutOf`) to the file's existing `import { ... }
from './share.js'` line.

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test web/share/share.test.mjs`
Expected: FAIL — `layoutOf` is not exported; `y`/`s` are accepted today by accident
(unknown keys are ignored) but the `y`-length/`s`-length REJECTION cases fail since
there is no such check yet.

- [ ] **Step 3: Implement `layoutOf` and extend `validateManifest`**

In `web/share/share.js`, extend the body of `validateManifest` (currently lines 66-90):

```js
export function validateManifest(m) {
  if (!m || typeof m !== 'object') return false;
  if (!Array.isArray(m.g) || m.g.length === 0) return false;
  if (m.g.length > 1000) return false;
  if (!m.g.every(id => VALID_ID.test(id))) return false;
  if (m.p != null && !VALID_ID.test(m.p)) return false;
  if (m.f != null) {
    if (!Array.isArray(m.f) || m.f.length !== m.g.length) return false;
    if (!m.f.every(s => typeof s === 'string' && s.length <= MAX_NAME)) return false;
  }
  // New optional keys (Spec 07 §1). Unknown layout VALUES are allowed
  // (forward-compat: an older page render of a newer link falls back to
  // grid via layoutOf) — but the key, when present, must be a short
  // string; `s` is display text (field cap).
  if (m.y != null && (typeof m.y !== 'string' || m.y.length > 16)) return false;
  if (m.s != null && (typeof m.s !== 'string' || m.s.length > MAX_FIELD)) return false;
  if (typeof m.e !== 'string' || !DATE_ONLY.test(m.e) || isNaN(Date.parse(m.e))) return false;
  for (const k of ['i', 'l', 'n', 'd']) if (typeof m[k] !== 'string' || m[k].length > MAX_FIELD) return false;
  return true;
}

/// Resolve the page layout from a manifest. Wire values must match
/// DriveShareManifest.swift's DriveShareLayout.rawValue exactly (the
/// two-implementations-one-contract rule class).
export function layoutOf(m) {
  return (m.y === 'sheet' || m.y === 'essay') ? m.y : 'grid';
}
```

`MAX_FIELD` is already a module-private `const` (line 12, value `4096`) — reuse it, do
not redeclare. Place `layoutOf` immediately below `validateManifest`.

- [ ] **Step 4: Run tests, confirm pass**

Run: `node --test web/share/share.test.mjs`
Expected: PASS — including every pre-existing test (id charset, bomb cap regression,
sanitize, legacy decode) unmodified and green.

- [ ] **Step 5: Commit**

```bash
git add web/share/share.js web/share/share.test.mjs
git commit -m "feat(share-page): add layoutOf + y/s manifest validation"
```

### Task 1.3: Three CSS layouts + `#body` node (`share.css`, `index.html`)

**Files:**
- Modify: `web/share/index.html`
- Modify: `web/share/share.css`
- Modify: `web/share/share.js`

**Interfaces:**
- Produces: `#body` DOM node (filled via the render glue), `SIZER_BY_LAYOUT` table (JS),
  `[data-layout]` CSS attribute selectors.
- Consumes: `layoutOf(m)` (Task 1.2).

One mechanism: the render glue sets `root.dataset.layout = layoutOf(m)` next to the
existing `data-state`, fills the new intro node, and everything else is CSS. No new DOM
construction path — the same tile `<button>` builder serves all three layouts.

- [ ] **Step 1: `index.html` — add the `#body` node**

Read the full 118-line file first. Add one node under the header (near the existing
title/label nodes — locate them and insert immediately after):

```html
<p id="body" class="body"></p>
```

- [ ] **Step 2: `share.js` — fill `#body`, set `data-layout`, add `SIZER_BY_LAYOUT`**

Locate the existing render glue that sets `#app`'s `data-state` and fills the title/
label/name text nodes via the existing `set(id, text)` helper (grep `function set(` in
`share.js` to confirm its exact signature before using it). Add, in the same glue
block:

```js
const SIZER_BY_LAYOUT = {
  grid:  { min: 3, max: 8, default: 5 },   // existing behavior, made explicit
  sheet: { min: 4, max: 10, default: 7 },
  essay: { min: 0, max: 0, default: 0 },   // sizer hidden; values unused
};

// ... inside the existing render function, alongside data-state assignment:
const layout = layoutOf(m);
document.getElementById('app').dataset.layout = layout;
set('body', m.s ?? '');
```

Confirm the exact existing sizer wiring by reading `setupGridSizer` (line 271 per the
verified file dump) in full before integrating `SIZER_BY_LAYOUT` — the sizer's slider
`min`/`max`/default attributes must be re-derived from this table on every render (not
just at page load), since a portfolio re-fetch (Task 3.4) can change the layout in
place.

- [ ] **Step 3: `share.css` — the three layouts**

Read the full 463-line file first (note the existing `.grid` rule at line 75 and `.tile`
at line 84 — verified `aspect-ratio: 3/4` fixed). Move the CURRENT (grid) rules under an
explicit attribute selector so a legacy link (no `y`) renders byte-for-byte the same
page it does today, then add `sheet`/`essay` variants:

```css
/* Grid (default) — the pre-Spec-07 rendering, made explicit under the attribute
   selector. A legacy manifest (no y key) resolves to 'grid' via layoutOf and must
   render identically to today. */
#app[data-layout="grid"] .grid { /* existing --tile-min/auto-fill rules, moved here verbatim */ }
#app[data-layout="grid"] .tile { aspect-ratio: 3/4; }
#app[data-layout="grid"] .caption { /* existing per-tile caption rule, if any, moved here */ }

/* Contact sheet — denser, square tiles, filename always visible, frame numbers. */
#app[data-layout="sheet"] .grid {
  gap: 8px;
}
#app[data-layout="sheet"] .tile {
  aspect-ratio: 1;
  counter-increment: frame;
}
#app[data-layout="sheet"] .tile::before {
  content: counter(frame, decimal-leading-zero);
  position: absolute;
  top: 4px;
  left: 4px;
  font: 10px/1.2 ui-monospace, "SF Mono", Menlo, monospace;
  color: var(--caption);
  background: color-mix(in srgb, var(--bg) 70%, transparent);
  padding: 1px 4px;
  border-radius: 3px;
  pointer-events: none;
}
#app[data-layout="sheet"] .grid { counter-reset: frame; }
#app[data-layout="sheet"] .caption {
  display: block;
  font: 10px/1.3 ui-monospace, "SF Mono", Menlo, monospace;
  font-variant-numeric: tabular-nums;
  text-align: center;
  margin-top: 4px;
}
@media print {
  #app[data-layout="sheet"] .grid { grid-template-columns: repeat(6, 1fr); }
}

/* Essay — single centered column, natural aspect, generous rhythm. */
#app[data-layout="essay"] .grid {
  display: flex;
  flex-direction: column;
  align-items: center;
  max-width: 860px;
  margin: 0 auto;
  gap: 48px;
}
#app[data-layout="essay"] .tile {
  aspect-ratio: auto;
  width: 100%;
}
#app[data-layout="essay"] .caption {
  display: block;
  font-size: 12px;
  text-align: center;
  margin-top: 8px;
  color: var(--caption);
}
#app[data-layout="essay"] .grid-sizer { display: none; }
#app[data-layout="essay"] .body {
  max-width: 860px;
  margin: 0 auto 32px;
  font-size: 15px;
  line-height: 1.6;
  color: var(--caption);
}
@media print {
  #app[data-layout="essay"] .tile { break-inside: avoid; }
}

/* Shared across layouts: hidden when empty (no intro paragraph supplied). */
.body:empty { display: none; }
```

Verify the exact existing custom-property names (`--bg`, `--caption`, etc.) via `grep -n
"^\s*--" web/share/share.css` before using them above — substitute the real tokens if
they differ from this draft's guesses. The backdrop switcher, lightbox, download
deterrents, expired/unavailable states, and the print "Save PDF" flow are
layout-independent — do not touch their selectors.

- [ ] **Step 4: Manual verification (no CI harness for CSS)**

Open `web/share/index.html` locally (or via a local static server) with a sample
fragment for each of the three `y` values (construct one manually via
`DriveShareManifest(...).encoded()` in a Swift playground/test, or reuse the
`share.test.mjs` fixtures) and visually confirm: grid renders identically to the
pre-Spec-07 page; sheet shows square tiles, always-visible filenames, and a frame
number; essay shows a single centered column with the intro paragraph. Record the date
+ result in the session log (this is a visual-judgment step, not unit-testable).

- [ ] **Step 5: Commit**

```bash
git add web/share/index.html web/share/share.css web/share/share.js
git commit -m "feat(share-page): three layouts (grid/sheet/essay) off one data-layout attribute"
```

### Task 1.4: Layout picker + Intro field in `DriveShareSheet`; `AppSettings.driveShareLayout`

**Files:**
- Modify: `Muse/Muse/Sharing/Drive/DriveShareService.swift` (the `DriveShareForm`
  struct at lines 15-21, and `run`'s manifest-building block at lines 113-116)
- Modify: `Muse/Muse/Views/DriveShareForm.swift` (the `DriveShareSheet` view struct)
- Modify: `Muse/Muse/Settings/AppSettings.swift`

**Interfaces:**
- Produces: `DriveShareForm.layout: DriveShareLayout = .grid`, `.bodyText: String = ""`;
  `AppSettings.driveShareLayout: String` (default `"grid"`, the `driveShareLabel`
  pattern at `AppSettings.swift:65`).
- Consumes: `DriveShareLayout` (Task 1.1).

- [ ] **Step 1: Extend `DriveShareForm` (the plain struct in `DriveShareService.swift`)**

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

- [ ] **Step 2: Add `AppSettings.driveShareLayout`**

Insert beside the existing `driveShareLabel`/`driveShareName` properties (lines 61-68):

```swift
    static var driveShareLayout: String {
        get { UserDefaults.standard.string(forKey: "driveShareLayout") ?? "grid" }
        set { UserDefaults.standard.set(newValue, forKey: "driveShareLayout") }
    }
```

- [ ] **Step 3: Add the Layout picker + Intro field to `DriveShareSheet`'s `form` view**

Read the full `form` view (`DriveShareForm.swift` lines 74-107, verified above) before
editing. Add a new `@State` for the layout selection, seeded from `AppSettings
.driveShareLayout`, and insert the picker between the "Page Title" and "Label" fields:

```swift
    @State private var layout: DriveShareLayout =
        DriveShareLayout(rawValue: AppSettings.driveShareLayout) ?? .grid
    @State private var bodyText: String = ""
```

```swift
    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            field(String(localized: "Page Title"), text: $intro,
                  prompt: String(localized: "Project Name"))
            layoutPicker
            if layout == .essay {
                introField
            }
            field(String(localized: "Label"), text: $label,
                  prompt: String(localized: "e.g. Sent by"))
            field(String(localized: "Name"), text: $name,
                  prompt: String(localized: "Your Name"))
            // ... existing Expires DatePicker block, unchanged ...
            HStack {
                Spacer()
                ModalButton(title: String(localized: "Publish"), kind: .prominent, isDefault: true) {
                    let form = DriveShareForm(intro: intro, label: label, name: name,
                                              date: Date(), expiry: expiry,
                                              layout: layout, bodyText: bodyText)
                    AppSettings.driveShareLayout = layout.rawValue
                    service.publish(form: form, title: title, urls: urls)
                }
                .disabled(intro.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 6)
        }
    }

    private var layoutPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Layout").font(.system(size: 12)).foregroundStyle(.secondary)
            Picker("", selection: $layout) {
                Label(String(localized: "Grid"), systemImage: "square.grid.2x2")
                    .tag(DriveShareLayout.grid)
                Label(String(localized: "Contact Sheet"), systemImage: "rectangle.grid.3x2")
                    .tag(DriveShareLayout.sheet)
                Label(String(localized: "Essay"), systemImage: "rectangle.portrait.on.rectangle.portrait")
                    .tag(DriveShareLayout.essay)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var introField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Intro").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(String(localized: "A short paragraph about this collection…"),
                      text: $bodyText, axis: .vertical)
                .lineLimit(3...6)
        }
    }
```

The `field(_:text:prompt:)` helper already exists (line 109) — do not duplicate it for
`layoutPicker`/`introField`, which have their own bespoke bodies since one is a
`Picker` and one is a multi-line `TextField`.

- [ ] **Step 4: Map the form fields into the manifest in `DriveShareService.run`**

Modify the manifest-construction block (lines 113-116):

```swift
                let manifest = DriveShareManifest(
                    intro: form.intro, label: form.label, name: form.name,
                    date: iso.string(from: form.date), expiry: iso.string(from: form.expiry),
                    imageIDs: imageIDs, filenames: filenames, pdfID: nil,
                    layout: form.layout == .grid ? nil : form.layout.rawValue,
                    bodyText: form.bodyText.isEmpty ? nil : form.bodyText)
```

`layout: nil` when grid keeps plain shares' fragments minimal (unchanged size for the
common case); `bodyText: nil` when empty avoids an empty `s` key.

- [ ] **Step 5: Build and manually verify**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build`
Then `stat` the built `.app`'s executable mtime to confirm it's fresh (house rule).
Publish a small test share with each of the three layouts (if a Google account is
signed in) and confirm the published page matches the layout chosen — cross-check
against Task 1.3's manual verification.

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Sharing/Drive/DriveShareService.swift" "Muse/Muse/Views/DriveShareForm.swift" \
  "Muse/Muse/Settings/AppSettings.swift"
git commit -m "feat(share): layout picker + intro field in the publish sheet"
```

### Task 1.5: Pre-publish guard for the 1000-image / field-length caps (Deviation D8)

**Files:**
- Modify: `Muse/Muse/Sharing/Drive/DriveShareService.swift` (`PublishError`, `publish`)
- Modify: `Muse/MuseTests/` — add a small pure-logic test if the guard is factored as a
  standalone function (preferred, per house testability convention).

**Interfaces:**
- Produces: a new `PublishError` case; a pure `DriveSharePublishGuard.validate(urls:
  form:) -> PublishError?` function so the cap logic is unit-testable without spinning
  up the whole async `run` flow.
- Consumes: `DriveShareManifest.maxImages`/`.maxFieldLength` (Task 1.1).

Today the app can mint a >1000-image link that the page's own `validateManifest`
rejects (`m.g.length > 1000` → false, rendered as "unavailable"). This task closes that
gap with a clear pre-publish error instead of a silent bad link.

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/DriveSharePublishGuardTests.swift
import XCTest
@testable import Muse

final class DriveSharePublishGuardTests: XCTestCase {
    private func makeForm(intro: String = "x") -> DriveShareForm {
        DriveShareForm(intro: intro, label: "l", name: "n", date: Date(), expiry: Date())
    }

    func testAcceptsUnderTheImageCap() {
        let urls = (0..<10).map { URL(fileURLWithPath: "/tmp/\($0).jpg") }
        XCTAssertNil(DriveSharePublishGuard.validate(urls: urls, form: makeForm()))
    }

    func testRejectsOverTheImageCap() {
        let urls = (0..<1001).map { URL(fileURLWithPath: "/tmp/\($0).jpg") }
        guard case .unshareableTooManyImages(let count)? =
            DriveSharePublishGuard.validate(urls: urls, form: makeForm()) else {
            return XCTFail("expected .unshareableTooManyImages")
        }
        XCTAssertEqual(count, 1001)
    }

    func testRejectsOversizedIntroField() {
        let urls = [URL(fileURLWithPath: "/tmp/a.jpg")]
        let form = makeForm(intro: String(repeating: "x", count: 4097))
        XCTAssertNotNil(DriveSharePublishGuard.validate(urls: urls, form: form))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/DriveSharePublishGuardTests`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Implement the guard**

```swift
// In DriveShareService.swift, alongside PublishError:
enum PublishError: Error {
    case unshareableImage(String)
    case unshareableTooManyImages(Int)
    case fieldTooLong(String)
}

/// Pure pre-publish validation mirroring the page's own validator
/// (DriveShareManifest.maxImages/.maxFieldLength) — the app must never mint
/// a link its own page rejects. Kept as a standalone pure function so it's
/// testable without the async publish flow.
enum DriveSharePublishGuard {
    static func validate(urls: [URL], form: DriveShareForm) -> PublishError? {
        if urls.count > DriveShareManifest.maxImages {
            return .unshareableTooManyImages(urls.count)
        }
        let fields = [form.intro, form.label, form.name, form.bodyText]
        for f in fields where f.count > DriveShareManifest.maxFieldLength {
            return .fieldTooLong(f)
        }
        return nil
    }
}
```

- [ ] **Step 4: Wire the guard into `publish`/`run`**

At the top of `publish(form:title:urls:)` (line 57), before the existing empty-urls
guard:

```swift
    func publish(form: DriveShareForm, title: String, urls: [URL]) {
        guard urls.isEmpty == false else {
            phase = .failed(String(localized: "This collection has no images to share.")); return
        }
        if let guardError = DriveSharePublishGuard.validate(urls: urls, form: form) {
            phase = .failed(Self.message(for: guardError)); return
        }
        // ... existing cancel()/runGeneration/phase = .preparing/task = Task { ... } ...
    }
```

Extend the existing `Self.message(for:)` static helper (verified present at lines
157-168) with a case for the two new `PublishError` variants:

```swift
        case .unshareableTooManyImages(let count):
            return String(localized: "Shares are limited to 1,000 images. This view has \(count).")
        case .fieldTooLong:
            return String(localized: "One of the share's text fields is too long.")
```

(Confirm `message(for:)`'s exact existing switch structure via `grep -n "static func
message" Muse/Muse/Sharing/Drive/DriveShareService.swift` before inserting — match its
current case ordering/style.)

- [ ] **Step 5: Run tests, confirm pass**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/DriveSharePublishGuardTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Sharing/Drive/DriveShareService.swift" "Muse/MuseTests/DriveSharePublishGuardTests.swift"
git commit -m "fix(share): pre-publish guard for the 1000-image/field-length caps (D8)"
```

### Task 1.6: Deploy Pages (owner-only step, documented)

**Files:** none (operational step, no code change).

- [ ] **Step 1:** After Tasks 1.1–1.5 land, the owner deploys `web/share/` (share.js,
  share.css, index.html, `_headers`) to Cloudflare Pages so the three layouts go live.
  No code changes in this task — record the deploy date + commit hash in the session
  log. (This step is called out explicitly because it's the FIRST of two Pages deploys
  this plan needs — the second follows Task 3.4's `connect-src` change.)

---

## Phase 2 — Google on-ramp polish

*Matches spec-07-implementation.md §9 build-order step 2: small, independent of Phase 1
and Phase 3. Can be worked in parallel.*

### Task 2.1: Signed-out explainer in `DriveShareSheet`

**Files:**
- Modify: `Muse/Muse/Views/DriveShareForm.swift` (`DriveShareSheet`)

**Interfaces:**
- Consumes: `GoogleOAuth.isSignedIn` (`@Published private(set) var`), `GoogleOAuth
  .signIn() async throws` (verified signatures), `SettingsView.runAuth`'s busy-guard
  PATTERN (not the method itself — `DriveShareSheet` gets its own local `@State
  authBusy` mirroring it, since `runAuth` is private to `SettingsView`).

- [ ] **Step 1: Manual verification is the acceptance gate here** (no pure logic to
  unit-test — this is a conditional UI block gated on `service.isSignedIn` and
  `service.phase == .idle`, both already-shipped state). Skip straight to
  implementation; verify by toggling sign-in state manually in the running app.

- [ ] **Step 2: Add the explainer**

In `DriveShareSheet`'s body, above the existing phase `switch` (before line 43), insert:

```swift
    @State private var authBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // ... existing header ...
            if service.isSignedIn == false, service.phase == .idle {
                signedOutExplainer
            }
            switch service.phase {
                // ... unchanged ...
            }
        }
        // ... existing modifiers ...
    }

    private var signedOutExplainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your photos, your Drive.")
                .font(.system(size: 13, weight: .semibold))
            Text("Publishing uploads the selected images to your own Google Drive and creates a private web page link. Muse's developer never sees or receives your photos. Location and camera metadata are removed from every uploaded image.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if DriveConfig.consentScreenVerified == false {
                Text("Google may show an \u{201c}unverified app\u{201d} step while Muse's verification is in review — choose Advanced → Continue to proceed.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack {
                if authBusy {
                    ProgressView().controlSize(.small)
                } else {
                    ModalButton(title: String(localized: "Continue with Google"), kind: .prominent) {
                        Task { await runExplainerAuth() }
                    }
                }
                Spacer()
            }
            Text("Recipients view web-sized images. To give someone the original files, share them from your own Google Drive.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    /// Mirrors SettingsView.runAuth's re-entrancy guard (private to that file, so
    /// duplicated here rather than shared — both are tiny and neither should import
    /// the other's view internals).
    private func runExplainerAuth() async {
        guard authBusy == false else { return }
        authBusy = true
        try? await service.auth.signIn()
        authBusy = false
    }
```

`service.auth` needs to be exposed — verify `DriveShareService`'s `auth` property
visibility (currently `private let auth: GoogleOAuth` per the verified file dump, line
not given but confirmed private). Change it to `let auth: GoogleOAuth` (drop `private`)
so this view can call `service.auth.signIn()` directly, OR add a small public
`DriveShareService.signInDirectly() async throws { try await auth.signIn() }`
convenience wrapper — prefer the wrapper (keeps `auth` encapsulated, matches the
service's existing style of owning all Drive interaction):

```swift
    // DriveShareService.swift — additive, alongside the existing public API:
    func signInDirectly() async throws { try await auth.signIn() }
```

and call `try? await service.signInDirectly()` from `runExplainerAuth()` instead.
Publish itself still handles the signed-out case exactly as today (`.signingIn`
mid-run) — this explainer is additive, not a new gate; a user can still press Publish
directly and hit the same in-flow sign-in prompt as before.

- [ ] **Step 3: Build and manually verify**

Sign out of Google in Settings, open the publish sheet, confirm the explainer appears
above the form (not instead of it), press "Continue with Google," confirm the OAuth
sheet appears, sign in, confirm the explainer disappears and the plain form remains.

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Views/DriveShareForm.swift" "Muse/Muse/Sharing/Drive/DriveShareService.swift"
git commit -m "feat(share): signed-out Google Drive explainer in the publish sheet"
```

### Task 2.2: `DriveConfig.consentScreenVerified` + unverified-scope messaging

**Files:**
- Modify: `Muse/Muse/Sharing/Drive/DriveConfig.swift`

**Interfaces:**
- Produces: `DriveConfig.consentScreenVerified: Bool` (compiled constant, `false` at
  ship time — owner flips it when Google verification completes).
- Consumes: nothing.

- [ ] **Step 1: Add the constant**

The full current file (32 lines) is a flat `enum DriveConfig` of `static let`
constants. Add one more, with the doc comment explaining WHY it's a constant and not a
Settings key:

```swift
    /// Set true by the owner once Google's OAuth verification review completes.
    /// A compiled constant, not a Settings key — it describes the DEVELOPER's
    /// console state, not a user preference. While false, sign-in surfaces (the
    /// publish-sheet explainer, Task 2.1; the Settings Drive section, Task 2.3)
    /// show a short note that Google may present an "unverified app" interstitial.
    static let consentScreenVerified = false
```

Insert it as the last constant in the `enum`, before the closing brace.

- [ ] **Step 2: No test needed** — this is a compiled Bool constant with no logic branch
  of its own; its two consumers (Task 2.1's explainer, Task 2.3's Settings footer) are
  UI conditionals already covered by those tasks' manual-verification steps (house
  convention: no UI unit tests).

- [ ] **Step 3: Commit**

```bash
git add "Muse/Muse/Sharing/Drive/DriveConfig.swift"
git commit -m "feat(share): DriveConfig.consentScreenVerified gate for unverified-app messaging"
```

### Task 2.3: Settings copy — Google Drive section footer + signed-in caption

**Files:**
- Modify: `Muse/Muse/Settings/SettingsView.swift`

**Interfaces:**
- Consumes: `GoogleOAuth.isSignedIn`, `DriveConfig.consentScreenVerified` (Task 2.2).

- [ ] **Step 1: Extend the footer text and add the signed-in caption**

Verified current section (lines 166-205). Replace the `footer:` closure body and add a
static caption row when signed in:

```swift
            Section {
                HStack {
                    Text(googleAuth.isSignedIn
                         ? String(localized: "Signed in to Google")
                         : String(localized: "Not signed in"))
                    Spacer()
                    if authBusy {
                        ProgressView().controlSize(.small)
                    } else if googleAuth.isSignedIn {
                        ModalButton(title: String(localized: "Sign Out")) {
                            Task { await runAuth { await googleAuth.signOut() } }
                        }
                    } else {
                        ModalButton(title: String(localized: "Sign In")) {
                            Task { await runAuth { try? await googleAuth.signIn() } }
                        }
                    }
                }
                if googleAuth.isSignedIn {
                    Text("Signed in — photos upload to your own Drive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Google Drive")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in to publish a collection as a shareable Drive web page. Sign out to switch to a different Google account. Photos upload to your own Drive — Muse's developer never sees or receives them.")
                    if DriveConfig.consentScreenVerified == false {
                        Text("Google may show an \u{201c}unverified app\u{201d} step while Muse's verification is in review — choose Advanced → Continue to proceed.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
```

No new stored state — `authBusy`/`runAuth`/the sign-in/out mechanics are all unchanged.

- [ ] **Step 2: Build and manually verify**

Open Settings while signed in and signed out; confirm the new caption row appears only
when signed in and the unverified note only while `consentScreenVerified == false`.

- [ ] **Step 3: Commit**

```bash
git add "Muse/Muse/Settings/SettingsView.swift"
git commit -m "docs(share): extend Google Drive settings copy (privacy + unverified-app note)"
```

---

## Phase 3 — Portfolio mode

*Matches spec-07-implementation.md §9 build-order step 3. A portfolio share = Drive
folder (images + `manifest.json`) + a page URL whose fragment carries the manifest
file's id (`m`) AND a full inline snapshot. Updates rewrite the manifest via
`files.update` — the file id, and therefore the URL, never changes. Zero server-side
share state; state lives only in the user's own Drive.*

### Task 3.1: `DriveClient` additions — `uploadManifest`, `updateManifest`, `listChildren`

**Files:**
- Modify: `Muse/Muse/Sharing/Drive/DriveClient.swift`
- Modify or Create: `Muse/MuseTests/DriveMultipartTests.swift` (grep first —
  `grep -rn "class DriveMultipartTests" Muse/MuseTests/` — to confirm whether it exists;
  the spec doc's §8 test list treats it as "extend," implying it should already exist
  covering the shipped `multipartBody`/`isValidMIME` — if grep finds nothing, create it
  fresh with those pre-existing assertions ported in first, then add the new ones below
  so the file is self-consistent)

**Interfaces:**
- Produces: `DriveClient.uploadManifest(_ json: Data, parent: String) async throws ->
  String`, `.updateManifest(id: String, json: Data) async throws`, `.listChildren(of
  folderID: String) async throws -> [(id: String, name: String)]`.
- Consumes: nothing new — reuses the existing `authed(_:)`, `filesEndpoint`,
  `uploadEndpoint`, `multipartBody(metadata:fileData:mime:boundary:)` helpers verbatim.

`uploadFile` is UNTOUCHED by this task — image bytes reach Drive exclusively through
it, strip-verified, fail-closed. The new calls are deliberately named/typed so they
can never become a strip bypass: `uploadManifest` takes `Data` the caller has already
JSON-encoded (never a `URL`, so there is no file to strip), and its mime is pinned to
`"application/json"` inside the implementation, not caller-supplied.

- [ ] **Step 1: Write the failing tests**

Request-builder assertions only (pure, no network) — the house pattern for
`DriveMultipartTests` per the existing `multipartBody`/`isValidMIME` tests (both are
`static func`s callable without a live `DriveClient` instance):

```swift
    func testUploadManifestUsesJSONMimeAndCorrectMetadata() {
        let json = Data(#"{"i":"x"}"#.utf8)
        let boundary = "test-boundary"
        let body = DriveClient.multipartBody(
            metadata: ["name": "manifest.json", "parents": ["parent123"]],
            fileData: json, mime: "application/json", boundary: boundary)
        let bodyString = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyString.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(bodyString.contains("\"name\":\"manifest.json\""))
        XCTAssertTrue(bodyString.contains("\"parents\":[\"parent123\"]"))
        XCTAssertTrue(bodyString.contains(#"{"i":"x"}"#))
    }

    func testListChildrenQueryIsWellFormed() {
        // listChildren builds its GET URL via URLComponents — assert the query
        // items are present and correctly percent-encoded for a folder id
        // containing characters URLComponents must escape.
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        let folderID = "abc DEF-123"
        comps.queryItems = [
            URLQueryItem(name: "q", value: "'\(folderID)' in parents and trashed=false"),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "pageSize", value: "1000"),
        ]
        XCTAssertNotNil(comps.url)
        XCTAssertTrue(comps.url!.absoluteString.contains("pageSize=1000"))
    }
```

(If `DriveMultipartTests` needs to be created fresh, first port the two pre-existing
assertions the spec's §8 list implies already exist — `multipartBody` shape and
`isValidMIME` — by reading `DriveClient.swift`'s `multipartBody`/`isValidMIME` bodies
(already verified above) and writing straightforward unit tests for them before adding
the two above, so the new file isn't missing shipped coverage.)

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/DriveMultipartTests`
Expected: the new tests compile and pass immediately (they exercise only the ALREADY-
shipped `multipartBody`) — this task's real failing signal comes from Step 3's new
methods not existing yet if a caller references them; since these two tests don't call
`uploadManifest`/`updateManifest`/`listChildren` directly (they're async/network-shaped
and not worth mocking `URLSession` for in a pure-logic test), treat Step 3 as
implement-then-verify-by-build rather than red-green on these two specific tests. The
compile-time proof is Task 3.5/3.6 calling the new methods successfully.

- [ ] **Step 3: Implement the three methods**

Add to `Muse/Muse/Sharing/Drive/DriveClient.swift`, in the `// MARK: files` section
alongside `uploadFile`/`setAnyoneReader`:

```swift
    /// Upload/replace the portfolio's manifest.json. NEVER for images — image bytes
    /// go through uploadFile's metadata strip, fail-closed. Enforced by the narrow
    /// signature (takes Data the caller already encoded, mime pinned).
    func uploadManifest(_ json: Data, parent: String) async throws -> String {
        let boundary = "muse-\(UUID().uuidString)"
        var req = try await authed(uploadEndpoint)
        req.httpMethod = "POST"
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.multipartBody(
            metadata: ["name": "manifest.json", "parents": [parent]],
            fileData: json, mime: "application/json", boundary: boundary)
        let (respData, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let id = obj["id"] as? String
        else { throw DriveError.http(code) }
        return id
    }

    /// Rewrite an existing manifest.json's content in place. The file id (and so the
    /// portfolio's URL) never changes — this IS the atomic update cutover (§2.7).
    func updateManifest(id: String, json: Data) async throws {
        var req = try await authed("https://www.googleapis.com/upload/drive/v3/files/\(id)?uploadType=media")
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = json
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw DriveError.http(code) }
    }

    /// Children of a folder Muse created (drive.file sees only its own files). Used by
    /// the portfolio update to sweep replaced images. One page is enough: shares are
    /// capped at DriveShareManifest.maxImages (1000) + the manifest itself.
    func listChildren(of folderID: String) async throws -> [(id: String, name: String)] {
        var comps = URLComponents(string: filesEndpoint)!
        comps.queryItems = [
            URLQueryItem(name: "q", value: "'\(folderID)' in parents and trashed=false"),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "pageSize", value: "1000"),
        ]
        guard let url = comps.url else { throw DriveError.badResponse }
        var req = try await authed(url.absoluteString)
        req.httpMethod = "GET"
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = obj["files"] as? [[String: Any]]
        else { throw DriveError.http(code) }
        return files.compactMap { f in
            guard let id = f["id"] as? String, let name = f["name"] as? String else { return nil }
            return (id, name)
        }
    }
```

- [ ] **Step 4: Run tests, confirm pass; build the whole target**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/DriveMultipartTests`
then `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse build`
Expected: PASS, BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Sharing/Drive/DriveClient.swift" "Muse/MuseTests/DriveMultipartTests.swift"
git commit -m "feat(share): DriveClient uploadManifest/updateManifest/listChildren for portfolio mode"
```

### Task 3.2: `DriveShareRecord` growth + `neverExpires` sentinel + `portfolio(forCollectionID:)`

**Files:**
- Modify: `Muse/Muse/Sharing/Drive/DriveShareRecord.swift`
- Modify or Create: `Muse/MuseTests/DriveShareStoreTests.swift` (grep first — this file
  may not exist yet for the shipped `DriveShareStore`; if absent, create it covering
  both the pre-existing store behavior — `add`/`remove`/`all`/upsert-by-folderID — and
  the new portfolio behavior below, so it's self-consistent)

**Interfaces:**
- Produces: `DriveShareRecord.kind: String?`, `.manifestFileID: String?`,
  `.collectionID: String?`, `.layout: String?`, `.introTitle: String?`,
  `.bodyText: String?` (all nil-default), `.isPortfolio: Bool` (computed),
  `DriveShareRecord.neverExpires: Date` (sentinel, 2100-01-01T00:00:00Z),
  `DriveShareStore.portfolio(forCollectionID id: String) -> [DriveShareRecord]`.
- Consumes: nothing new. `DriveExpiry.expired` and `DriveExpirySweeper` are
  BYTE-UNTOUCHED — verify this after editing by diffing against the pre-task version.

- [ ] **Step 1: Write the failing tests**

```swift
// Muse/MuseTests/DriveShareStoreTests.swift
import XCTest
@testable import Muse

final class DriveShareStoreTests: XCTestCase {
    private func makeStore() -> DriveShareStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("driveShares-\(UUID().uuidString).json")
        return DriveShareStore(fileURL: tmp)
    }

    private func classicRecord(id: String = UUID().uuidString, folderID: String = "f1") -> DriveShareRecord {
        DriveShareRecord(id: id, collectionName: "Trip", folderID: folderID,
                          pageURL: "https://muse-share.pages.dev#abc", itemCount: 3,
                          createdAt: Date(), expiry: Date().addingTimeInterval(86400))
    }

    private func portfolioRecord(id: String = UUID().uuidString, folderID: String = "f2",
                                  collectionID: String = "col1") -> DriveShareRecord {
        DriveShareRecord(id: id, collectionName: "Portfolio", folderID: folderID,
                          pageURL: "https://muse-share.pages.dev#xyz", itemCount: 5,
                          createdAt: Date(), expiry: DriveShareRecord.neverExpires,
                          kind: "portfolio", manifestFileID: "m1", collectionID: collectionID,
                          layout: "essay", introTitle: "My Work", bodyText: "About this work.")
    }

    func testPreSpec07RecordDecodesUnchanged() throws {
        // A driveShares.json written by a build before this spec: no new keys at all.
        let legacyJSON = """
        [{"id":"a","collectionName":"Trip","folderID":"f1",
          "pageURL":"https://muse-share.pages.dev#abc","itemCount":3,
          "createdAt":"2026-01-01T00:00:00Z","expiry":"2026-02-01T00:00:00Z"}]
        """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        try legacyJSON.data(using: .utf8)!.write(to: tmp)
        let store = DriveShareStore(fileURL: tmp)
        let all = store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertNil(all.first?.kind)
        XCTAssertFalse(all.first!.isPortfolio)
    }

    func testRecordsWithNewFieldsRoundTrip() {
        let store = makeStore()
        let record = portfolioRecord()
        store.add(record)
        let loaded = store.all().first
        XCTAssertEqual(loaded, record)
        XCTAssertTrue(loaded!.isPortfolio)
    }

    func testPortfolioForCollectionIDFiltersAndSorts() {
        let store = makeStore()
        let older = portfolioRecord(id: "p1", folderID: "f1", collectionID: "col1")
        var newer = portfolioRecord(id: "p2", folderID: "f2", collectionID: "col1")
        newer.createdAt = older.createdAt.addingTimeInterval(3600)
        let other = portfolioRecord(id: "p3", folderID: "f3", collectionID: "col2")
        let classic = classicRecord(id: "c1", folderID: "f4")
        [older, newer, other, classic].forEach { store.add($0) }

        let result = store.portfolio(forCollectionID: "col1")
        XCTAssertEqual(result.map(\.id), ["p2", "p1"])   // newest first
    }

    func testDriveExpiryNeverFlagsANeverExpiresRecord() {
        let record = portfolioRecord()
        // Even checked far in the future, the sentinel must not read as expired.
        XCTAssertTrue(DriveExpiry.expired([record], now: Date(timeIntervalSince1970: 4_102_444_700)).isEmpty)
        XCTAssertFalse(DriveExpiry.expired([record], now: Date(timeIntervalSince1970: 4_102_444_900)).isEmpty)
    }

    func testUpsertByFolderIDReplacesAPortfolioRecordInPlace() {
        let store = makeStore()
        let original = portfolioRecord(id: "p1", folderID: "f1")
        store.add(original)
        var updated = original
        updated.itemCount = 9
        updated.bodyText = "Updated text."
        store.add(updated)   // same folderID → replaces, per add()'s existing filter rule
        let all = store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.itemCount, 9)
        XCTAssertEqual(all.first?.bodyText, "Updated text.")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/DriveShareStoreTests`
Expected: FAIL — new `DriveShareRecord` init params / `neverExpires` / `isPortfolio` /
`portfolio(forCollectionID:)` don't exist yet.

- [ ] **Step 3: Implement the record growth**

```swift
struct DriveShareRecord: Codable, Identifiable, Equatable {
    let id: String
    let collectionName: String
    let folderID: String
    let pageURL: String
    var itemCount: Int
    let createdAt: Date
    var expiry: Date                    // .neverExpires sentinel for portfolios
    // Spec 07 — all optional so pre-existing driveShares.json decodes unchanged.
    var kind: String? = nil             // "portfolio"; nil/anything else = classic share
    var manifestFileID: String? = nil   // the stable pointer (files.update target)
    var collectionID: String? = nil     // binds "Update Portfolio…" to its collection
    var layout: String? = nil           // prefill for the update form
    var introTitle: String? = nil       // prefill
    var bodyText: String? = nil         // prefill

    var isPortfolio: Bool { kind == "portfolio" }
    /// 2100-01-01T00:00:00Z. A SENTINEL, not an optional: an optional expiry would
    /// make new-format records undecodable by the previous build's non-optional
    /// field (whose load() failure silently drops the WHOLE list on next save). The
    /// sentinel keeps old builds fully working, and the sweeper needs no portfolio
    /// special-case — expiry < now is simply never true. Deviation D4.
    static let neverExpires = Date(timeIntervalSince1970: 4_102_444_800)
}
```

(`itemCount`/`expiry` change from `let` to `var` so `updatePortfolio`, Task 3.6, can
mutate an existing record in place before re-adding it — `id`/`collectionName`/
`folderID`/`pageURL`/`createdAt` stay `let`, matching the "same pageURL, same
manifestFileID, same createdAt" update-in-place rule.)

`DriveExpiry.expired` and `init(fileURL:)`/`add`/`remove`/`load`/`save` are
BYTE-UNTOUCHED — confirm no lines in those bodies changed.

- [ ] **Step 4: Add `portfolio(forCollectionID:)` to `DriveShareStore`**

```swift
    func portfolio(forCollectionID id: String) -> [DriveShareRecord] {
        queue.sync { load().filter { $0.isPortfolio && $0.collectionID == id }
                           .sorted { $0.createdAt > $1.createdAt } }
    }
```

Insert alongside the existing `all()` method, same lock/queue discipline.

- [ ] **Step 5: Also expose `DriveShareStore.init(fileURL:)` if it isn't already**
  accessible from tests (verified it IS: `init(fileURL: URL) { self.fileURL = fileURL }`
  is not marked `private`, confirmed in the verified file dump) — no change needed,
  just confirming before the test file above compiles.

- [ ] **Step 6: Run tests, confirm pass**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/DriveShareStoreTests`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add "Muse/Muse/Sharing/Drive/DriveShareRecord.swift" "Muse/MuseTests/DriveShareStoreTests.swift"
git commit -m "feat(share): DriveShareRecord portfolio fields + neverExpires sentinel + store lookup"
```

### Task 3.3: `share.js` — portfolio-aware `validateManifest` + `manifestFetchURL` + `acceptFetchedManifest`

**Files:**
- Modify: `web/share/share.js`
- Modify: `web/share/share.test.mjs`

**Interfaces:**
- Produces: `validateManifest(m, opts = {})` (signature CHANGE — adds `opts` with a
  `portfolio` flag), `export function manifestFetchURL(id)`, `export function
  acceptFetchedManifest(text)`, `DRIVE_API_KEY`/`MAX_MANIFEST_BYTES`/
  `MANIFEST_FETCH_TIMEOUT_MS` constants.
- Consumes: `VALID_ID` (existing export, line 8), `MAX_FIELD`/`DATE_ONLY` (existing).

This is Deviation **D1**: an API key ships in `share.js`. It is quota-only,
API-restricted to the Drive API, referrer-restricted to the share origins (owner step,
Task 3.9), and grants access to nothing non-public — the files it reads are already
anyone-readable by design. The load-bearing invariant (no SECRET, no OAuth credential
on the page) is unchanged.

- [ ] **Step 1: Write the failing tests**

```js
test('validateManifest: e required for classic (non-portfolio) manifests, even malformed', () => {
  const base = { i: 'x', l: 'x', n: 'x', d: 'x', g: ['a'.repeat(20)] };
  assert.equal(validateManifest({ ...base }), false);                    // no e at all
  assert.equal(validateManifest({ ...base, e: '' }), false);             // empty e
  assert.equal(validateManifest({ ...base, e: 'not-a-date' }), false);
});

test('validateManifest: m present makes the manifest a portfolio — e ignored', () => {
  const base = { i: 'x', l: 'x', n: 'x', d: 'x', g: ['a'.repeat(20)], m: 'm'.repeat(20), e: '' };
  assert.equal(validateManifest(base), true);
  assert.equal(validateManifest({ ...base, e: 'garbage-but-tolerated' }), true);
});

test('validateManifest: opts.portfolio waives e for a manifest with no m of its own', () => {
  // Covers manifests fetched FROM Drive (they never carry m; that's the app's job).
  const base = { i: 'x', l: 'x', n: 'x', d: 'x', g: ['a'.repeat(20)], e: '' };
  assert.equal(validateManifest(base, { portfolio: true }), true);
  assert.equal(validateManifest(base), false);   // same object, no opts → still strict
});

test('validateManifest: m rejected when malformed', () => {
  const base = { i: 'x', l: 'x', n: 'x', d: 'x', g: ['a'.repeat(20)], e: '2026-01-01' };
  assert.equal(validateManifest({ ...base, m: 'too-short' }), false);
  assert.equal(validateManifest({ ...base, m: 123 }), false);
});

test('manifestFetchURL builds a googleapis.com URL with the id and the API key', () => {
  const url = manifestFetchURL('a'.repeat(20));
  assert.match(url, /^https:\/\/www\.googleapis\.com\/drive\/v3\/files\/a{20}\?alt=media&key=/);
});

test('acceptFetchedManifest: accepts a valid portfolio-shaped body', () => {
  const body = JSON.stringify({ i: 'x', l: 'x', n: 'x', d: 'x', e: '', g: ['a'.repeat(20)] });
  const obj = acceptFetchedManifest(body);
  assert.ok(obj);
  assert.equal(obj.i, 'x');
});

test('acceptFetchedManifest: rejects a body over MAX_MANIFEST_BYTES', () => {
  const huge = JSON.stringify({ i: 'x'.repeat(600 * 1024) });
  assert.equal(acceptFetchedManifest(huge), null);
});

test('acceptFetchedManifest: rejects invalid JSON', () => {
  assert.equal(acceptFetchedManifest('{not json'), null);
});

test('acceptFetchedManifest: strips an embedded m before returning (never chains)', () => {
  const body = JSON.stringify({ i: 'x', l: 'x', n: 'x', d: 'x', e: '', g: ['a'.repeat(20)], m: 'z'.repeat(20) });
  const obj = acceptFetchedManifest(body);
  assert.ok(obj);
  assert.equal(obj.m, undefined);
});

test('acceptFetchedManifest: rejects a body that fails validateManifest', () => {
  const body = JSON.stringify({ i: 'x' });   // missing g, e, etc.
  assert.equal(acceptFetchedManifest(body), null);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test web/share/share.test.mjs`
Expected: FAIL — `opts` param doesn't exist (all classic-manifest tests using the
one-arg call still pass since `opts` defaults to `{}`), `m` isn't validated,
`manifestFetchURL`/`acceptFetchedManifest` don't exist.

- [ ] **Step 3: Implement**

```js
// New constants, near the top of share.js alongside the existing MAX_FIELD/MAX_NAME:
const DRIVE_API_KEY = 'REPLACE_AT_DEPLOY';          // owner step — Task 3.9
const MAX_MANIFEST_BYTES = 512 * 1024;              // bounded read (bomb-guard rule class)
const MANIFEST_FETCH_TIMEOUT_MS = 6000;

export function validateManifest(m, opts = {}) {
  if (!m || typeof m !== 'object') return false;
  if (!Array.isArray(m.g) || m.g.length === 0) return false;
  if (m.g.length > 1000) return false;
  if (!m.g.every(id => VALID_ID.test(id))) return false;
  if (m.p != null && !VALID_ID.test(m.p)) return false;
  if (m.f != null) {
    if (!Array.isArray(m.f) || m.f.length !== m.g.length) return false;
    if (!m.f.every(s => typeof s === 'string' && s.length <= MAX_NAME)) return false;
  }
  if (m.y != null && (typeof m.y !== 'string' || m.y.length > 16)) return false;
  if (m.s != null && (typeof m.s !== 'string' || m.s.length > MAX_FIELD)) return false;
  if (m.m != null && !VALID_ID.test(m.m)) return false;
  // `e` is REQUIRED for classic shares (fail-open guard: an absent/malformed date
  // must never yield a never-expiring link by accident). A portfolio manifest (`m`
  // present) is non-expiring BY DESIGN and carries no meaningful `e`; opts.portfolio
  // covers manifests fetched from Drive, which never ride a fragment and have no
  // `m` of their own.
  const portfolio = opts.portfolio === true || m.m != null;
  if (!portfolio) {
    if (typeof m.e !== 'string' || !DATE_ONLY.test(m.e) || isNaN(Date.parse(m.e))) return false;
  } else if (m.e != null && m.e !== '') {
    if (typeof m.e !== 'string' || m.e.length > 32) return false;  // tolerated, ignored
  }
  for (const k of ['i', 'l', 'n', 'd']) if (typeof m[k] !== 'string' || m[k].length > MAX_FIELD) return false;
  return true;
}

// §2: portfolio manifests live in the user's Drive so the share can update without
// changing its URL. Quota-only, referrer-restricted browser API key — grants access
// to nothing non-public (see README); NOT a secret. The ONLY fetch this page ever
// makes.
export function manifestFetchURL(id) {
  // VALID_ID-gated by the caller; the charset makes interpolation URL-safe (the
  // thumbURL rule class).
  return `https://www.googleapis.com/drive/v3/files/${id}?alt=media&key=${DRIVE_API_KEY}`;
}

// Pure: parse + bound + validate a fetched manifest body. null → caller falls back
// to the inline snapshot. Exported for tests.
export function acceptFetchedManifest(text) {
  if (typeof text !== 'string' || text.length > MAX_MANIFEST_BYTES) return null;
  try {
    const obj = JSON.parse(text);
    if (obj && typeof obj === 'object') delete obj.m;   // never chain
    return validateManifest(obj, { portfolio: true }) ? obj : null;
  } catch { return null; }
}
```

Replace the existing single-parameter `validateManifest(m)` definition wholesale with
the above (every existing call site in `share.js`'s render glue keeps working
unmodified, since `opts` defaults to `{}` and a classic manifest with no `m` still hits
the strict `e` branch).

- [ ] **Step 4: Run tests, confirm pass**

Run: `node --test web/share/share.test.mjs`
Expected: PASS — every pre-existing test AND every Task 1.2 test (`y`/`s`
acceptance, `layoutOf`) stays green; the strict-`e` regression test for classic shares
(no `m`) still passes since `sample manifests carry no m` (per spec §1.2's own
regression note).

- [ ] **Step 5: Commit**

```bash
git add web/share/share.js web/share/share.test.mjs
git commit -m "feat(share-page): portfolio-aware validateManifest + manifestFetchURL + acceptFetchedManifest"
```

### Task 3.4: Page fetch render glue + CSP `connect-src`

**Files:**
- Modify: `web/share/share.js`
- Modify: `web/share/_headers`
- Modify: `web/share/index.html` (meta CSP fallback)

**Interfaces:**
- Consumes: `manifestFetchURL`, `acceptFetchedManifest` (Task 3.3), `layoutOf` (Task
  1.2), the existing render/grid-rebuild function (name TBD by reading the file — grep
  `function render(` or similar before wiring).

- [ ] **Step 1: No new pure-testable unit here (network + DOM timing)** — this task's
  correctness gate is manual verification (Step 4) plus the already-covered pure pieces
  from Task 3.3. Proceed straight to implementation.

- [ ] **Step 2: Add the fetch to the render glue**

Locate the existing render entry point (the function that currently reads
`DriveShareManifest.decode`-equivalent output — i.e. `decodeManifest` at line 53 per
the verified dump — and drives `data-state`). After the manifest is decoded from the
fragment and BEFORE the final `data-state = 'live'` assignment, insert:

```js
async function resolveManifest(inline) {
  if (inline.m == null || !VALID_ID.test(inline.m)) return inline;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), MANIFEST_FETCH_TIMEOUT_MS);
  try {
    const resp = await fetch(manifestFetchURL(inline.m), { signal: controller.signal });
    if (!resp.ok) return inline;
    const text = await resp.text();
    const fetched = acceptFetchedManifest(text);
    return fetched ?? inline;
  } catch {
    return inline;   // offline / API change / quota — degrade to last-published state
  } finally {
    clearTimeout(timeout);
  }
}
```

Wire it into the existing render sequence: render the INLINE manifest immediately (no
blank waiting state — the shipped-behavior requirement), then, only when `inline.m` is
present, `await resolveManifest(inline)` and — only if the result differs from what's
currently rendered — re-run the SAME tile-builder/`data-layout`/`#body` render path a
second time with the fetched object (clear-and-rebuild the grid, cheap and typically a
no-op visually). Do not add a second DOM construction path — reuse whatever function
Step-1's grep located.

Also gate `isExpired`: a portfolio manifest (`m` present, or the render context knows
`opts.portfolio`) must SKIP the expired branch entirely — locate the existing call site
of `isExpired(m, now)` in the render glue and wrap it:

```js
const portfolio = manifest.m != null;
if (!portfolio && isExpired(manifest, new Date())) {
  document.getElementById('app').dataset.state = 'expired';
  return;
}
```

- [ ] **Step 3: CSP — `connect-src`**

`web/share/_headers` (verified 7-line file), change line 2's CSP directive list —
append exactly one clause:

```
/*
  Content-Security-Policy: default-src 'none'; img-src 'self' https://drive.google.com https://*.googleusercontent.com; script-src 'self'; style-src 'self'; connect-src https://www.googleapis.com; base-uri 'none'; form-action 'none'; frame-ancestors 'none'
  X-Content-Type-Options: nosniff
  Referrer-Policy: no-referrer
  X-Frame-Options: DENY
  Permissions-Policy: geolocation=(), camera=(), microphone=()
  Strict-Transport-Security: max-age=63072000; includeSubDomains; preload
```

`index.html`'s meta CSP fallback (line 14 per the verified dump — note its own comment
already states it can't express `frame-ancestors`/`Referrer-Policy`, only `_headers`
can) gets the same `connect-src` clause added to whatever subset it currently mirrors:
read the exact current meta `content` attribute first (`grep -n
'http-equiv="Content-Security-Policy"' web/share/index.html`) and append `connect-src
https://www.googleapis.com;` to it, preserving every other directive verbatim.

- [ ] **Step 4: Manual verification**

Publish a real portfolio (requires Task 3.5 done — if sequencing this task standalone,
defer full verification to after Task 3.5/3.6 land, or synthesize a `manifest.json` by
hand-uploading one to a test Drive folder and constructing a matching fragment). Load
the resulting page: confirm it renders the inline snapshot instantly, confirm the
network tab shows exactly one fetch to `www.googleapis.com`, confirm going offline
(disable network) still renders (falls back to inline). Record the date + result — this
row is spec-07's own "recorded manually, not CI" perf/behavior row (§6).

- [ ] **Step 5: Commit**

```bash
git add web/share/share.js web/share/_headers web/share/index.html
git commit -m "feat(share-page): portfolio manifest.json fetch + connect-src CSP (D1/D3)"
```

### Task 3.5: `DriveShareService.publishPortfolio`

**Files:**
- Modify: `Muse/Muse/Sharing/Drive/DriveShareService.swift`

**Interfaces:**
- Produces: `func publishPortfolio(form: DriveShareForm, title: String, collectionID:
  String?, urls: [URL])`.
- Consumes: `DriveClient.uploadManifest` (Task 3.1), `DriveShareRecord`'s portfolio
  fields (Task 3.2), `DriveShareManifest.jsonData()` (Task 1.1), the existing `Phase`
  enum, `runGeneration`/`setPhase(_:ifCurrent:)`, `cleanupFolder`, `store`, `client`,
  `auth` — all verbatim reuse of the shipped `run()` machinery.

Same service, same `Phase` enum, same generation guard, same cancel-on-dismiss
invariant (the sheet's `.onDisappear { service.cancel() }`, already shipped, covers
portfolio publishes for free).

- [ ] **Step 1: No new pure-unit test here** — this method is structurally identical to
  the already-shipped, integration-shaped `run()` (async, network-bound, generation-
  guarded). Per house convention (`DriveShareService` has no existing unit tests of its
  own — it's tested via `DriveShareStoreTests`/`DriveShareManifestTests`/
  `DriveMultipartTests` at its seams, plus manual verification of the async flow), this
  task's correctness gate is a manual end-to-end publish (Step 4) plus the already-
  covered pure pieces (manifest encoding, record round-trip, client request shape).

- [ ] **Step 2: Implement `publishPortfolio`**

```swift
    func publishPortfolio(form: DriveShareForm, title: String, collectionID: String?, urls: [URL]) {
        guard urls.isEmpty == false else {
            phase = .failed(String(localized: "This collection has no images to share.")); return
        }
        if let guardError = DriveSharePublishGuard.validate(urls: urls, form: form) {
            phase = .failed(Self.message(for: guardError)); return
        }
        cancel()
        runGeneration += 1
        let gen = runGeneration
        phase = .preparing
        task = Task { await runPortfolio(form: form, title: title, collectionID: collectionID,
                                          urls: urls, generation: gen) }
    }

    private func runPortfolio(form: DriveShareForm, title: String, collectionID: String?,
                              urls: [URL], generation: Int) async {
        do {
            if auth.isSignedIn == false {
                setPhase(.signingIn, ifCurrent: generation)
                try await auth.signIn()
            }
            let root = try await client.ensureMuseRoot(existingID: AppSettings.driveRootFolderID)
            AppSettings.driveRootFolderID = root

            let folderName = "\(title) — Portfolio"
            let folderID = try await client.createFolder(name: folderName, parent: root)

            do {
                setPhase(.uploading(0, urls.count), ifCurrent: generation)
                var imageIDs: [String] = []
                var filenames: [String] = []
                for (i, url) in urls.enumerated() {
                    if Task.isCancelled {
                        await cleanupFolder(folderID)
                        setPhase(.idle, ifCurrent: generation)
                        return
                    }
                    let mime = Self.mimeType(for: url)
                    let id: String
                    do {
                        id = try await client.uploadFile(url: url, name: url.lastPathComponent,
                                                         mime: mime, parent: folderID)
                    } catch is ImageMetadataStripper.StripError {
                        throw PublishError.unshareableImage(url.lastPathComponent)
                    }
                    imageIDs.append(id)
                    filenames.append(url.lastPathComponent)
                    setPhase(.uploading(i + 1, urls.count), ifCurrent: generation)
                }

                // Build the live manifest (no `m`, expiry "", layout/bodyText per form)
                // and upload it as manifest.json — the pointer the fragment carries.
                let liveManifest = DriveShareManifest(
                    intro: form.intro, label: form.label, name: form.name,
                    date: DateFormatter.driveDay.string(from: form.date), expiry: "",
                    imageIDs: imageIDs, filenames: filenames, pdfID: nil,
                    layout: form.layout == .grid ? nil : form.layout.rawValue,
                    bodyText: form.bodyText.isEmpty ? nil : form.bodyText)
                let manifestID = try await client.uploadManifest(liveManifest.jsonData(), parent: folderID)

                setPhase(.finalizing, ifCurrent: generation)
                // Children inherit — the shipped single-permission pattern. manifest.json
                // becomes world-readable by the same inheritance, required for the page
                // fetch and leaking nothing the fragment didn't already carry.
                try await client.setAnyoneReader(fileID: folderID)

                var fragmentManifest = liveManifest
                fragmentManifest.manifestID = manifestID
                let pageURL = fragmentManifest.pageURL(base: DriveConfig.shareBaseURL)

                let record = DriveShareRecord(
                    id: UUID().uuidString, collectionName: title, folderID: folderID,
                    pageURL: pageURL, itemCount: imageIDs.count, createdAt: Date(),
                    expiry: DriveShareRecord.neverExpires, kind: "portfolio",
                    manifestFileID: manifestID, collectionID: collectionID,
                    layout: fragmentManifest.layout, introTitle: form.intro, bodyText: form.bodyText)
                let tracked = store.add(record)

                AppSettings.driveShareName = form.name
                AppSettings.driveShareLabel = form.label
                AppSettings.driveShareLayout = form.layout.rawValue

                setPhase(tracked ? .done(pageURL) : .doneUntracked(pageURL), ifCurrent: generation)
            } catch {
                await cleanupFolder(folderID)
                throw error
            }
        } catch is CancellationError {
            setPhase(.idle, ifCurrent: generation)
        } catch DriveAuthError.cancelled {
            setPhase(.idle, ifCurrent: generation)
        } catch {
            setPhase(.failed(Self.message(for: error)), ifCurrent: generation)
        }
    }
```

This mirrors `run()`'s exact control flow (verified above), diverging only where the
spec requires: folder naming (`"\(title) — Portfolio"`), manifest upload instead of
pure fragment encoding, and the record's portfolio fields. `.doneUntracked`'s copy gains
a portfolio-aware note in the next task's UI step (an untracked PORTFOLIO can never be
updated, since Manage can't find it) — that's a UI string change (`DriveShareSheet`'s
`doneView`), not a service-layer change; wire it in Task 3.7.

- [ ] **Step 3: Verify `DriveAuthError.cancelled` exists**

`grep -n "enum DriveAuthError" Muse/Muse/Sharing/Drive/` to confirm the exact type name
used in the shipped `run()`'s catch clause — reuse it verbatim (it's referenced above
by name from the verified `run()` body).

- [ ] **Step 4: Build and manually verify**

Publish a small real portfolio (2-3 test images), confirm: a folder named "<title> —
Portfolio" appears in Drive containing the images AND a `manifest.json`; the resulting
page URL renders correctly; the local Manage list shows the new portfolio record.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Sharing/Drive/DriveShareService.swift"
git commit -m "feat(share): DriveShareService.publishPortfolio"
```

### Task 3.6: `DriveShareService.updatePortfolio`

**Files:**
- Modify: `Muse/Muse/Sharing/Drive/DriveShareService.swift`

**Interfaces:**
- Produces: `func updatePortfolio(record: DriveShareRecord, form: DriveShareForm, urls: [URL])`.
- Consumes: `DriveClient.folderExists`, `.uploadFile`, `.updateManifest`,
  `.listChildren`, `.deleteFolder` (all existing or Task 3.1); `DriveShareStore.add`
  (existing upsert-by-folderID semantics, verified).

Ordered so a visitor mid-update always sees a coherent page, and failure never damages
the live share: **upload-new → `updateManifest` (the atomic cutover) → delete-old.**

- [ ] **Step 1: No new pure-unit test** — same integration-shaped rationale as Task 3.5;
  the ordering invariant itself IS testable in isolation and gets one:

```swift
// Muse/MuseTests/DriveShareUpdateOrderTests.swift
import XCTest
@testable import Muse

/// Pins the update ORDER as a value, not just prose: a pure log-based check that
/// the update sequence, whatever future refactor touches it, still emits
/// upload → manifestSwap → sweep in that order. Doesn't hit the network — it
/// exercises the pure step-sequencer the real method delegates to.
final class DriveShareUpdateOrderTests: XCTestCase {
    func testStepOrderIsUploadThenSwapThenSweep() {
        XCTAssertEqual(DriveShareUpdateSteps.order,
                        [.uploadImages, .swapManifest, .sweepOldChildren])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/DriveShareUpdateOrderTests`
Expected: FAIL — `DriveShareUpdateSteps` doesn't exist.

- [ ] **Step 3: Implement the ordered enum + `updatePortfolio`**

```swift
/// The binding update order (§2.7 / durable constraint #5): upload-new → swap
/// manifest (atomic cutover) → delete-old. A pure `[Step]` so the ordering
/// invariant itself is unit-testable without a live Drive round trip.
enum DriveShareUpdateSteps {
    enum Step: Equatable { case uploadImages, swapManifest, sweepOldChildren }
    static let order: [Step] = [.uploadImages, .swapManifest, .sweepOldChildren]
}

extension DriveShareService {
    func updatePortfolio(record: DriveShareRecord, form: DriveShareForm, urls: [URL]) {
        guard urls.isEmpty == false else {
            phase = .failed(String(localized: "This collection has no images to share.")); return
        }
        if let guardError = DriveSharePublishGuard.validate(urls: urls, form: form) {
            phase = .failed(Self.message(for: guardError)); return
        }
        cancel()
        runGeneration += 1
        let gen = runGeneration
        phase = .preparing
        task = Task { await runPortfolioUpdate(record: record, form: form, urls: urls, generation: gen) }
    }

    private func runPortfolioUpdate(record: DriveShareRecord, form: DriveShareForm,
                                    urls: [URL], generation: Int) async {
        do {
            if auth.isSignedIn == false {
                setPhase(.signingIn, ifCurrent: generation)
                try await auth.signIn()
            }
            guard let manifestFileID = record.manifestFileID else {
                setPhase(.failed(String(localized: "This portfolio can't be updated — publish a new one.")),
                          ifCurrent: generation)
                return
            }
            let stillExists = (try? await client.folderExists(id: record.folderID)) ?? false
            guard stillExists else {
                setPhase(.failed(String(localized: "This portfolio no longer exists — publish a new one.")),
                          ifCurrent: generation)
                return
            }

            // Step 1 of DriveShareUpdateSteps.order: uploadImages.
            setPhase(.uploading(0, urls.count), ifCurrent: generation)
            var imageIDs: [String] = []
            var filenames: [String] = []
            for (i, url) in urls.enumerated() {
                if Task.isCancelled {
                    // Roll back just-uploaded files; the OLD share is untouched.
                    for id in imageIDs { try? await client.deleteFolder(id: id) }
                    setPhase(.idle, ifCurrent: generation)
                    return
                }
                let mime = Self.mimeType(for: url)
                let id: String
                do {
                    id = try await client.uploadFile(url: url, name: url.lastPathComponent,
                                                     mime: mime, parent: record.folderID)
                } catch is ImageMetadataStripper.StripError {
                    for uploaded in imageIDs { try? await client.deleteFolder(id: uploaded) }
                    setPhase(.failed(Self.message(for: PublishError.unshareableImage(url.lastPathComponent))),
                              ifCurrent: generation)
                    return
                } catch {
                    for uploaded in imageIDs { try? await client.deleteFolder(id: uploaded) }
                    setPhase(.failed(Self.message(for: error)), ifCurrent: generation)
                    return
                }
                imageIDs.append(id)
                filenames.append(url.lastPathComponent)
                setPhase(.uploading(i + 1, urls.count), ifCurrent: generation)
            }

            // Step 2: swapManifest — the ATOMIC cutover. Before this call the page
            // still serves the OLD image set; after it, the NEW one.
            setPhase(.finalizing, ifCurrent: generation)
            let newManifest = DriveShareManifest(
                intro: form.intro, label: form.label, name: form.name,
                date: record.pageURL, expiry: "",   // date field is cosmetic-only post-publish; keep prior semantics
                imageIDs: imageIDs, filenames: filenames, pdfID: nil,
                layout: form.layout == .grid ? nil : form.layout.rawValue,
                bodyText: form.bodyText.isEmpty ? nil : form.bodyText)
            do {
                try await client.updateManifest(id: manifestFileID, json: newManifest.jsonData())
            } catch {
                for uploaded in imageIDs { try? await client.deleteFolder(id: uploaded) }
                setPhase(.failed(Self.message(for: error)), ifCurrent: generation)
                return
            }

            // Step 3: sweepOldChildren — list-driven; per-file failures are NON-FATAL
            // (retried by the next update's sweep).
            let uploadedAndManifest = Set(imageIDs + [manifestFileID])
            if let children = try? await client.listChildren(of: record.folderID) {
                var sweepFailed = false
                for child in children where uploadedAndManifest.contains(child.id) == false {
                    do { try await client.deleteFolder(id: child.id) }
                    catch { sweepFailed = true }
                }
                if sweepFailed {
                    appState?.alertRequest = .message(
                        title: String(localized: "Portfolio Updated"),
                        message: String(localized: "Some previous images couldn't be removed from Drive; they'll be cleaned up on the next update."))
                }
            }

            var updatedRecord = record
            updatedRecord.itemCount = imageIDs.count
            updatedRecord.layout = form.layout == .grid ? nil : form.layout.rawValue
            updatedRecord.introTitle = form.intro
            updatedRecord.bodyText = form.bodyText
            store.add(updatedRecord)   // upserts by folderID — same pageURL/manifestFileID/createdAt

            setPhase(.done(record.pageURL), ifCurrent: generation)
        } catch is CancellationError {
            setPhase(.idle, ifCurrent: generation)
        } catch DriveAuthError.cancelled {
            setPhase(.idle, ifCurrent: generation)
        } catch {
            setPhase(.failed(Self.message(for: error)), ifCurrent: generation)
        }
    }
}
```

`appState?.alertRequest` requires `DriveShareService` to hold a weak/optional reference
to `AppState` for the non-fatal sweep notice — grep whether the service already has
such a reference (it does not, per the verified init). Add a settable
`weak var appState: AppState?` property (set by whichever view constructs the service —
`DriveShareSheet.init`, alongside its existing `_service = StateObject(...)`) so the
notice can surface via the shared `MuseAlert` seam without threading a closure through
every phase. If wiring a weak `AppState` reference through feels heavier than the
feature warrants, the alternative is a new `Phase` case
(`.doneWithSweepWarning(String)`) rendered by `DriveShareSheet`'s existing phase switch
— prefer THIS alternative (keeps `DriveShareService` free of AppState coupling, matching
its current design where it owns no AppState reference at all); implement it as:

```swift
    enum Phase: Equatable {
        case idle, preparing, signingIn, uploading(Int, Int), finalizing,
             done(String), doneUntracked(String), doneWithSweepWarning(String), failed(String)
    }
```

and set `.doneWithSweepWarning(record.pageURL)` instead of `.done(record.pageURL)` when
`sweepFailed` is true, deleting the `appState?.alertRequest` line and the property
addition above. `DriveShareSheet`'s phase switch (Task 3.7) renders it as `doneView`
with an extra secondary note.

- [ ] **Step 4: Run tests, confirm pass**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/DriveShareUpdateOrderTests`
Expected: PASS

- [ ] **Step 5: Build and manually verify**

Publish a test portfolio, then update it (add one image, remove one image, change the
intro text). Confirm: the page URL is IDENTICAL before and after; the new image appears
on the page; the removed image's Drive file is gone; re-visiting the OLD copied link
(if saved) still resolves (via live fetch, unaffected by the local record's URL, which
never changed anyway — there's only one URL).

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Sharing/Drive/DriveShareService.swift" "Muse/MuseTests/DriveShareUpdateOrderTests.swift"
git commit -m "feat(share): DriveShareService.updatePortfolio (upload-new → swap → sweep)"
```

### Task 3.7: UI seams — `DriveShareRequest`/`DriveShareMode`, menu items, sheet modes, Manage badges

**Files:**
- Modify: `Muse/Muse/Sharing/Drive/DriveShareService.swift` (add `DriveShareMode`/
  `DriveShareRequest`)
- Modify: `Muse/Muse/Views/Modal/ModalChrome.swift` (`CollectionModal.driveShare` case)
- Modify: `Muse/Muse/ContentView.swift` (the `.driveShare` switch case, line 285)
- Modify: `Muse/Muse/Views/ShareCollectionButton.swift`
- Modify: `Muse/Muse/Views/Sidebar/CollectionSidebarRow.swift` (line 260)
- Modify: `Muse/Muse/Views/DriveShareForm.swift` (`DriveShareSheet` — mode branching)
- Modify: `Muse/Muse/Views/ManageDriveSharesView.swift` (portfolio badges)

**Interfaces:**
- Produces: `enum DriveShareMode: Equatable { case share; case portfolioNew; case
  portfolioUpdate(DriveShareRecord) }`, `struct DriveShareRequest: Equatable { var
  title: String; var urls: [URL]; var mode: DriveShareMode = .share; var collectionID:
  String? }`.
- Consumes: `DriveShareStore.default.portfolio(forCollectionID:)` (Task 3.2),
  `SharingTier` (Task 3.8, but this task can land before it — the menu-visibility call
  site is added in Task 3.8, not here, to keep this task's diff focused on the payload
  plumbing).

This is the widest-blast-radius task in the plan — six files touched for one payload
type change. Do it as ONE commit (a half-migrated `CollectionModal.driveShare` doesn't
compile) but keep the internal steps ordered so a reviewer can follow the shape change
through the codebase.

- [ ] **Step 1: Add `DriveShareMode`/`DriveShareRequest` to `DriveShareService.swift`**

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
```

Place immediately below the existing `struct DriveShareForm` (lines 15-21).

- [ ] **Step 2: Retype `CollectionModal.driveShare`**

```swift
enum CollectionModal: Identifiable {
    case customize(CollectionStore.Loaded)
    case rules(RulesRequest)
    case driveShare(DriveShareRequest)

    struct RulesRequest {
        var collectionID: String?
        var initialName: String
        var initialSet: SmartRuleSet
        var isConversion: Bool = false
        var memberCount: Int = 0
    }

    var id: String {
        switch self {
        case .customize(let loaded):   return "customize-\(loaded.collection.id)"
        case .rules(let request):      return "rules-\(request.collectionID ?? "new")"
        case .driveShare(let request):
            let modeTag: String
            switch request.mode {
            case .share:                    modeTag = "share"
            case .portfolioNew:             modeTag = "portfolio-new"
            case .portfolioUpdate(let rec):  modeTag = "portfolio-update-\(rec.id)"
            }
            return "drive-\(request.title)-\(modeTag)"
        }
    }

    var width: CGFloat {
        switch self {
        case .customize:  return 480
        case .rules:      return 560
        case .driveShare(let request):
            switch request.mode {
            case .share:              return 460
            case .portfolioNew, .portfolioUpdate: return 480   // extra fields (Layout/Intro, no Expiry)
            }
        }
    }
}
```

The `id` fix resolves the drift the research pass flagged: the old `id` was derived
from `title` alone, so two different-mode shares of the same collection would have
collided as "the same modal" — the `modeTag` suffix makes each mode/record combination
distinct.

- [ ] **Step 3: Update `ContentView.swift`'s switch case (line 285)**

```swift
                case .driveShare(let request):
                    DriveShareSheet(auth: googleAuth, request: request) {
                        appState.collectionModal = nil
                    }
```

- [ ] **Step 4: Update both existing `.driveShare` call sites**

`Muse/Muse/Views/ShareCollectionButton.swift:41`:
```swift
    private func presentDriveShare() {
        appState.collectionModal = .driveShare(DriveShareRequest(title: title, urls: driveShareURLs))
    }
```

`Muse/Muse/Views/Sidebar/CollectionSidebarRow.swift:260`:
```swift
        appState.collectionModal = .driveShare(DriveShareRequest(title: loaded.collection.name, urls: driveShareURLs))
```

Both keep `mode: .share` (the struct's default) — behavior identical to today, per the
spec's explicit requirement.

- [ ] **Step 5: Update `DriveShareSheet`'s init and phase-driven publish call**

```swift
struct DriveShareSheet: View {
    @StateObject private var service: DriveShareService
    let request: DriveShareRequest
    let onClose: () -> Void

    @State private var intro: String
    @State private var label: String = AppSettings.driveShareLabel
    @State private var name: String = AppSettings.driveShareName
    @State private var expiry = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var layout: DriveShareLayout
    @State private var bodyText: String
    @State private var authBusy = false

    init(auth: GoogleOAuth, request: DriveShareRequest, onClose: @escaping () -> Void) {
        _service = StateObject(wrappedValue: DriveShareService(auth: auth))
        self.request = request
        self.onClose = onClose
        switch request.mode {
        case .share, .portfolioNew:
            _layout = State(initialValue: DriveShareLayout(rawValue: AppSettings.driveShareLayout) ?? .grid)
            _intro = State(initialValue: "")
            _bodyText = State(initialValue: "")
        case .portfolioUpdate(let record):
            _layout = State(initialValue: DriveShareLayout(rawValue: record.layout ?? "grid") ?? .grid)
            _intro = State(initialValue: record.introTitle ?? "")
            _bodyText = State(initialValue: record.bodyText ?? "")
        }
    }

    private var isPortfolioMode: Bool {
        switch request.mode { case .share: return false; case .portfolioNew, .portfolioUpdate: return true }
    }
```

Update the Publish button's action (in `form`, or a mode-branched `portfolioForm` — see
Step 6) to dispatch by mode:

```swift
                ModalButton(title: publishButtonTitle, kind: .prominent, isDefault: true) {
                    let form = DriveShareForm(intro: intro, label: label, name: name,
                                              date: Date(), expiry: expiry,
                                              layout: layout, bodyText: bodyText)
                    AppSettings.driveShareLayout = layout.rawValue
                    switch request.mode {
                    case .share:
                        service.publish(form: form, title: request.title, urls: request.urls)
                    case .portfolioNew:
                        service.publishPortfolio(form: form, title: request.title,
                                                 collectionID: request.collectionID, urls: request.urls)
                    case .portfolioUpdate(let record):
                        service.updatePortfolio(record: record, form: form, urls: request.urls)
                    }
                }
```

- [ ] **Step 6: Branch the form UI by mode**

Portfolio forms show Title · Layout · Intro (multi-line, ALWAYS shown, not gated on
`layout == .essay`) · Label · Name — no Expiry field — and the header text changes:

```swift
    private var headerTitle: String {
        switch request.mode {
        case .share: return String(localized: "Share Drive Link")
        case .portfolioNew: return String(localized: "Publish Portfolio")
        case .portfolioUpdate: return String(localized: "Update Portfolio")
        }
    }

    private var publishButtonTitle: String {
        switch request.mode {
        case .share: return String(localized: "Publish")
        case .portfolioNew: return String(localized: "Publish Portfolio")
        case .portfolioUpdate: return String(localized: "Update Portfolio")
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            field(String(localized: "Page Title"), text: $intro,
                  prompt: String(localized: "Project Name"))
            layoutPicker
            if isPortfolioMode || layout == .essay {
                introField
            }
            field(String(localized: "Label"), text: $label,
                  prompt: String(localized: "e.g. Sent by"))
            field(String(localized: "Name"), text: $name,
                  prompt: String(localized: "Your Name"))
            if isPortfolioMode == false {
                expiryRow   // the existing DatePicker block, extracted into its own `some View`
            } else {
                Text("Updating replaces the portfolio's images and text. The link stays the same.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                ModalButton(title: publishButtonTitle, kind: .prominent, isDefault: true) { /* Step 5's action */ }
                    .disabled(intro.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 6)
        }
    }
```

Extract the existing Expires `DatePicker` VStack (lines 82-92 of the verified dump)
into a private `expiryRow: some View` computed property with no behavior change, so it
can be conditionally included above. The footer note only shows in `.portfolioUpdate`
mode — narrow the `if isPortfolioMode` branch to check `request.mode` directly if a
`.portfolioNew` first-publish shouldn't see "Updating replaces…" text (it shouldn't —
tighten to `if case .portfolioUpdate = request.mode`).

- [ ] **Step 7: `.doneUntracked` copy gains a portfolio variant**

In `doneView(_:tracked:)` (verified lines 126-153), when `tracked == false` AND
`isPortfolioMode`, append the extra warning sentence: *"This portfolio couldn't be
saved locally — since Muse can't find it later, it can never be updated. Copy this
link now."* (localized). Implement via a small conditional `Text` appended to the
existing untracked-warning block; read the existing block first to match its exact
current copy before extending it.

- [ ] **Step 8: `ShareCollectionButton`'s menu grows Publish/Update/Copy Portfolio Link**

```swift
        Menu {
            Button("Save to…") { Task { await save() } }
            Button("Share Drive Link") { presentDriveShare(mode: .share) }
                .disabled(driveShareURLs.isEmpty)
            if let latest = portfolioRecords.first {
                Divider()
                Button("Update Portfolio…") { presentDriveShare(mode: .portfolioUpdate(latest)) }
                    .disabled(driveShareURLs.isEmpty)
                Button("Copy Portfolio Link") { copyPortfolioLink(latest) }
            } else {
                Divider()
                Button("Publish Portfolio…") { presentDriveShare(mode: .portfolioNew) }
                    .disabled(driveShareURLs.isEmpty)
            }
        } label: {
```

```swift
    private var portfolioRecords: [DriveShareRecord] {
        guard let collectionID = appState.activeCollectionID else { return [] }
        return DriveShareStore.default.portfolio(forCollectionID: collectionID)
    }

    private func presentDriveShare(mode: DriveShareMode) {
        appState.collectionModal = .driveShare(
            DriveShareRequest(title: title, urls: driveShareURLs, mode: mode,
                              collectionID: appState.activeCollectionID))
    }

    private func copyPortfolioLink(_ record: DriveShareRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.pageURL, forType: .string)
    }
```

(Verify `appState.activeCollectionID`'s exact type/optionality via `grep -n
"activeCollectionID" Muse/Muse/Models/AppState.swift` before wiring — adjust the
`guard let`/optional chaining to match its real declared type.) Menu items are
absent-not-disabled per the house rule when they don't apply — the `if/else` above
already achieves that (never both "Publish Portfolio…" and "Update Portfolio…" shown
at once).

- [ ] **Step 9: `ManageDriveSharesView` portfolio badges**

In the `row(_:)` function (verified lines 182-213), add a small capsule beside
`collectionName` and special-case the Expires column:

```swift
                Text(record.collectionName).font(.system(size: 15, weight: .semibold))
                if record.isPortfolio {
                    Text("Portfolio")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
```

and in `metaColumns`'s third argument (the Expires text), branch:

```swift
                            Text(record.isPortfolio
                                 ? String(localized: "Never")
                                 : record.expiry.formatted(date: .abbreviated, time: .omitted)))
```

Everything else in this file (Open Link prefix validation, prune-on-404, unpublish
trash button) works on portfolios unchanged — `folderExists`/`deleteFolder` operate on
the folder id regardless of kind, and `pruneMissing`/`delete` don't branch on `kind`.

- [ ] **Step 10: Build and manually verify**

Full round trip: open a collection, use "Publish Portfolio…", confirm the sheet shows
Layout/Intro/no-Expiry; publish; confirm the collection menu now shows "Update
Portfolio…"/"Copy Portfolio Link" instead; confirm Manage Drive Shares shows the
"Portfolio" badge and "Never" in Expires; run "Update Portfolio…" and confirm the URL
is unchanged after.

- [ ] **Step 11: Commit**

```bash
git add "Muse/Muse/Sharing/Drive/DriveShareService.swift" "Muse/Muse/Views/Modal/ModalChrome.swift" \
  "Muse/Muse/ContentView.swift" "Muse/Muse/Views/ShareCollectionButton.swift" \
  "Muse/Muse/Views/Sidebar/CollectionSidebarRow.swift" "Muse/Muse/Views/DriveShareForm.swift" \
  "Muse/Muse/Views/ManageDriveSharesView.swift"
git commit -m "feat(share): portfolio UI seams — publish/update/copy-link menu, sheet modes, Manage badges"
```

### Task 3.8: `Commerce/SharingTier.swift` (pure) — the tier seam

**Files:**
- Create: `Muse/Muse/Commerce/SharingTier.swift`
- Create: `Muse/MuseTests/SharingTierTests.swift`
- Modify: `Muse/Muse/Views/ShareCollectionButton.swift` (the single call site)

**Interfaces:**
- Produces: `enum SharingTier { static let enforced = false; static func
  portfolioAvailable(entitledToSharing: Bool) -> Bool }`.
- Consumes: nothing (no `Commerce/CommerceStore` exists in this tree — Spec 01 has not
  shipped it; the call site passes `false` for `entitledToSharing`, which is
  irrelevant while `enforced == false`, matching the spec's own soft-dependency note).

- [ ] **Step 1: Write the failing tests**

```swift
// Muse/MuseTests/SharingTierTests.swift
import XCTest
@testable import Muse

final class SharingTierTests: XCTestCase {
    func testUnenforcedAlwaysAvailableRegardlessOfEntitlement() {
        XCTAssertEqual(SharingTier.enforced, false)
        XCTAssertTrue(SharingTier.portfolioAvailable(entitledToSharing: false))
        XCTAssertTrue(SharingTier.portfolioAvailable(entitledToSharing: true))
    }
}
```

(A second test exercising `enforced == true` would require a mutable static, which the
spec deliberately doesn't provide — `enforced` is a `let`, flipped only by editing the
source when Spec 09 lands, per the `TrialGate` posture precedent. One test is
sufficient to pin today's behavior; a future spec's plan adds the flip + its own test.)

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/SharingTierTests`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Implement**

```swift
//
//  SharingTier.swift
//  Muse
//
//  Portfolio (with Spec 08's custom domains) is the upsell tier. Enforcement
//  policy is Spec 09's decision, so this seam ships in the TrialGate posture:
//  computes, never blocks, until enforced flips true.
//

enum SharingTier {
    /// Spec 09 flips this. Until then every caller gets `true` and the portfolio
    /// UI is fully available (TestFlight validation needs it).
    static let enforced = false

    static func portfolioAvailable(entitledToSharing: Bool) -> Bool {
        enforced ? entitledToSharing : true
    }
}
```

- [ ] **Step 4: Wire the single call site**

In `ShareCollectionButton.swift`, gate the Publish/Update Portfolio menu items'
visibility (not just `.disabled` — house rule is absent-not-disabled when a feature is
genuinely unavailable, but here the gate is "will be enforced later," so keep the items
visible-but-informational until Spec 09 flips `enforced`; concretely, no visible change
happens today since `portfolioAvailable` always returns true — this wiring is forward
plumbing):

```swift
    private var canUsePortfolio: Bool {
        // CommerceStore doesn't exist in this tree yet (Spec 01 not shipped) —
        // pass false; irrelevant while SharingTier.enforced == false.
        SharingTier.portfolioAvailable(entitledToSharing: false)
    }
```

and wrap the `if let latest = portfolioRecords.first { ... } else { ... }` block from
Task 3.7 Step 8 in `if canUsePortfolio { ... }` (with no `else`, so the whole
portfolio section of the menu simply doesn't appear if a future flip disables it —
matches the absent-not-disabled convention once `enforced` does become `true`).

- [ ] **Step 5: Run tests, confirm pass; build**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/SharingTierTests`
then `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse build`

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Commerce/SharingTier.swift" "Muse/MuseTests/SharingTierTests.swift" \
  "Muse/Muse/Views/ShareCollectionButton.swift"
git commit -m "feat(commerce): SharingTier seam for portfolio (unenforced until Spec 09)"
```

### Task 3.9: Owner-only deploy step

**Files:** none (operational step, no code change).

- [ ] **Step 1:** Once Tasks 3.1–3.8 land, the owner:
  1. Creates the browser API key (Google Cloud console, same project as the OAuth
     client): API restriction = Google Drive API only; application restriction = HTTP
     referrers `https://muse-share.pages.dev/*`.
  2. Pastes it into `share.js`'s `DRIVE_API_KEY` constant (replacing
     `'REPLACE_AT_DEPLOY'`) at deploy time.
  3. Deploys `web/share/` to Cloudflare Pages (the second deploy this plan needs, after
     Task 1.6's — this one carries the `connect-src` CSP and the portfolio fetch code).
  4. Records the deploy date + key-restriction confirmation in the session log.

---

## Phase 4 — Social export presets

*Matches spec-07-implementation.md §9 build-order step 4: `Export/Social/` module
(presets → crop math → metadata → render, tests at each) → card + `socialExportRequest`
+ three entry points → X invariants + fixtures → French pass. `Export/Social/` and
`Components/SocialCropMath.swift` are platform-neutral (no AppKit) per Global
Constraints.*

### Task 4.1: `Export/Social/SocialPreset.swift` — the 12-preset table

**Files:**
- Create: `Muse/Muse/Export/Social/SocialPreset.swift`
- Create: `Muse/MuseTests/SocialPresetTests.swift`

**Interfaces:**
- Produces: `struct SocialPreset: Identifiable, Equatable`, `SocialPreset.Kind`,
  `SocialPreset.SharpenLevel`, `SocialPreset.all: [SocialPreset]` (12 entries).
- Consumes: nothing.

The table is pinned entry-by-entry so it cannot drift from the spec silently.

- [ ] **Step 1: Write the failing tests**

```swift
//
//  SocialPresetTests.swift
//  MuseTests
//
//  Pins the ENTIRE preset table against spec-07-implementation.md §3.1 — a changed
//  number here is a deliberate constant edit, never an accident.
//

import XCTest
@testable import Muse

final class SocialPresetTests: XCTestCase {
    func testExactlyTwelvePresetsWithUniqueIDs() {
        XCTAssertEqual(SocialPreset.all.count, 12)
        XCTAssertEqual(Set(SocialPreset.all.map(\.id)).count, 12)
    }

    func testIGFeedPortrait() {
        let p = SocialPreset.all.first { $0.id == "ig-feed-portrait" }!
        XCTAssertEqual(p.kind, .fixed(width: 1080, height: 1350))
        XCTAssertEqual(p.quality, 0.88)
        XCTAssertEqual(p.byteTargetKB, 800)
        XCTAssertEqual(p.sharpen, .standard)
        XCTAssertFalse(p.exifDefaultOn)
        XCTAssertFalse(p.uniformMulti)
        XCTAssertFalse(p.storySafeZones)
        XCTAssertNotNil(p.warningKey)
    }

    func testIGGrid() {
        let p = SocialPreset.all.first { $0.id == "ig-grid" }!
        XCTAssertEqual(p.kind, .fixed(width: 1080, height: 1440))
        XCTAssertEqual(p.quality, 0.88); XCTAssertEqual(p.byteTargetKB, 800)
        XCTAssertEqual(p.sharpen, .standard); XCTAssertNotNil(p.warningKey)
    }

    func testIGSquare() {
        let p = SocialPreset.all.first { $0.id == "ig-square" }!
        XCTAssertEqual(p.kind, .fixed(width: 1080, height: 1080))
        XCTAssertEqual(p.quality, 0.88); XCTAssertEqual(p.byteTargetKB, 800)
        XCTAssertNil(p.warningKey)
    }

    func testIGLandscape() {
        let p = SocialPreset.all.first { $0.id == "ig-landscape" }!
        XCTAssertEqual(p.kind, .fixed(width: 1080, height: 566))
        XCTAssertEqual(p.quality, 0.88); XCTAssertEqual(p.byteTargetKB, 800)
    }

    func testIGStory() {
        let p = SocialPreset.all.first { $0.id == "ig-story" }!
        XCTAssertEqual(p.kind, .fixed(width: 1080, height: 1920))
        XCTAssertTrue(p.storySafeZones)
        XCTAssertFalse(p.uniformMulti)
    }

    func testIGCarousel() {
        let p = SocialPreset.all.first { $0.id == "ig-carousel" }!
        XCTAssertEqual(p.kind, .fixed(width: 1080, height: 1350))
        XCTAssertTrue(p.uniformMulti)
        XCTAssertNotNil(p.warningKey)
    }

    func testThreads() {
        let p = SocialPreset.all.first { $0.id == "threads" }!
        XCTAssertEqual(p.kind, .fixed(width: 1080, height: 1350))
        XCTAssertEqual(p.quality, 0.88); XCTAssertFalse(p.uniformMulti)
    }

    func testX() {
        let p = SocialPreset.all.first { $0.id == "x" }!
        XCTAssertEqual(p.kind, .longEdge(4096))
        XCTAssertEqual(p.quality, 0.90)
        XCTAssertNil(p.byteTargetKB)
        XCTAssertEqual(p.sharpen, .light)
        XCTAssertFalse(p.exifDefaultOn)
        XCTAssertNil(p.warningKey)   // X's hard invariants apply instead of an advisory
    }

    func testFacebook() {
        let p = SocialPreset.all.first { $0.id == "facebook" }!
        XCTAssertEqual(p.kind, .longEdge(2048))
        XCTAssertEqual(p.quality, 0.85); XCTAssertEqual(p.byteTargetKB, 1000)
        XCTAssertEqual(p.sharpen, .standard)
    }

    func testPinterest() {
        let p = SocialPreset.all.first { $0.id == "pinterest" }!
        XCTAssertEqual(p.kind, .fixed(width: 1000, height: 1500))
        XCTAssertEqual(p.quality, 0.90); XCTAssertNil(p.byteTargetKB)
    }

    func testFlickr() {
        let p = SocialPreset.all.first { $0.id == "flickr" }!
        XCTAssertEqual(p.kind, .original)
        XCTAssertEqual(p.quality, 0.95)
        XCTAssertEqual(p.sharpen, .none)
        XCTAssertTrue(p.exifDefaultOn)
    }

    func testGlass() {
        let p = SocialPreset.all.first { $0.id == "glass" }!
        XCTAssertEqual(p.kind, .longEdge(4096))
        XCTAssertEqual(p.quality, 0.92)
        XCTAssertEqual(p.sharpen, .light)
        XCTAssertTrue(p.exifDefaultOn)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/SocialPresetTests`
Expected: FAIL — module/type doesn't exist.

- [ ] **Step 3: Implement (verbatim from spec-07-implementation.md §3.1)**

```swift
//
//  SocialPreset.swift
//  Muse
//
//  Export/Social/ is platform-neutral: Foundation only here (no AppKit, no
//  CoreGraphics needed for pure data). The preset table is exactly
//  spec-07-implementation.md §3.1's table, pinned entry-by-entry by
//  SocialPresetTests — a changed number is a deliberate constant edit.
//

import Foundation

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
    let byteTargetKB: Int?    // nil = no target; ladder in SocialRender
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
              warningKey: nil),        // SocialRender's X invariants apply instead
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

Notes bound to the table (record in the file's doc comments too): the IG-family byte
target is 800 KB (the tighter of the foundation doc's two stated bounds); Glass's
never-upscale floor comes from the global rule (Task 4.4), not a per-preset minimum;
`warningKey` strings are advisory, never blockers.

- [ ] **Step 4: Run tests, confirm pass**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/SocialPresetTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Export/Social/SocialPreset.swift" "Muse/MuseTests/SocialPresetTests.swift"
git commit -m "feat(social-export): SocialPreset — the 12-preset table (pure data)"
```

### Task 4.2: `Components/SocialCropMath.swift` — pure crop rect math

**Files:**
- Create: `Muse/Muse/Components/SocialCropMath.swift`
- Create: `Muse/MuseTests/SocialCropMathTests.swift`

**Interfaces:**
- Produces: `enum SocialFit: String { case crop, matte, blurExtend }`, `enum
  MatteShade: String { case white, black }`, `enum SocialCropMath { static func
  rect(sourceSize: CGSize, targetAspect: CGFloat, zoom: CGFloat, center: CGPoint) ->
  CGRect; static let zoomRange: ClosedRange<CGFloat> = 1...4; static func
  composedCrop(existing: CGRect?, social: CGRect) -> CGRect }`.
- Consumes: nothing.

- [ ] **Step 1: Write the failing tests**

```swift
//
//  SocialCropMathTests.swift
//  MuseTests
//

import XCTest
import CoreGraphics
@testable import Muse

final class SocialCropMathTests: XCTestCase {
    func testZoomOneCenteredIsMaximalAspectFillRect() {
        // 4000x3000 source, target aspect 4:5 (portrait) — the minimal crop that
        // fills a 4:5 frame from a 4:3 source is width-constrained.
        let source = CGSize(width: 4000, height: 3000)
        let rect = SocialCropMath.rect(sourceSize: source, targetAspect: 4.0 / 5.0,
                                       zoom: 1, center: CGPoint(x: 0.5, y: 0.5))
        // Exact target aspect, centered, within the unit square.
        XCTAssertEqual(rect.width / rect.height, 4.0 / 5.0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(rect.minX, 0); XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxX, 1); XCTAssertLessThanOrEqual(rect.maxY, 1)
        XCTAssertEqual(rect.midX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(rect.midY, 0.5, accuracy: 0.0001)
    }

    func testRectNeverExitsUnitSquareUnderExtremeCenters() {
        let source = CGSize(width: 4000, height: 3000)
        for center in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0)] {
            let rect = SocialCropMath.rect(sourceSize: source, targetAspect: 1, zoom: 2, center: center)
            XCTAssertGreaterThanOrEqual(rect.minX, -0.0001)
            XCTAssertGreaterThanOrEqual(rect.minY, -0.0001)
            XCTAssertLessThanOrEqual(rect.maxX, 1.0001)
            XCTAssertLessThanOrEqual(rect.maxY, 1.0001)
        }
    }

    func testExactTargetAspectAtEveryZoom() {
        let source = CGSize(width: 3000, height: 4000)
        for zoom: CGFloat in [1, 1.5, 2, 3, 4] {
            let rect = SocialCropMath.rect(sourceSize: source, targetAspect: 1.0,
                                           zoom: zoom, center: CGPoint(x: 0.5, y: 0.5))
            XCTAssertEqual(rect.width / rect.height, 1.0, accuracy: 0.0001)
        }
    }

    func testComposedCropAgainstNilExisting() {
        let social = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.6)
        XCTAssertEqual(SocialCropMath.composedCrop(existing: nil, social: social), social)
    }

    func testComposedCropAgainstPreExistingCrop() {
        // A pre-existing crop of the left half; the social rect chosen in that
        // POST-geometry display space maps proportionally inside it.
        let existing = CGRect(x: 0, y: 0, width: 0.5, height: 1.0)
        let social = CGRect(x: 0.0, y: 0.25, width: 1.0, height: 0.5)   // full width of the ALREADY-cropped display
        let composed = SocialCropMath.composedCrop(existing: existing, social: social)
        // composed must stay within the original existing rect's bounds.
        XCTAssertGreaterThanOrEqual(composed.minX, existing.minX - 0.0001)
        XCTAssertLessThanOrEqual(composed.maxX, existing.maxX + 0.0001)
        XCTAssertGreaterThanOrEqual(composed.minY, existing.minY - 0.0001)
        XCTAssertLessThanOrEqual(composed.maxY, existing.maxY + 0.0001)
    }

    func testDegenerateSizesClampNeverNaN() {
        let rect = SocialCropMath.rect(sourceSize: .zero, targetAspect: 1, zoom: 1,
                                       center: CGPoint(x: 0.5, y: 0.5))
        XCTAssertFalse(rect.width.isNaN)
        XCTAssertFalse(rect.height.isNaN)
        let zeroAspect = SocialCropMath.rect(sourceSize: CGSize(width: 100, height: 100),
                                             targetAspect: 0, zoom: 1, center: CGPoint(x: 0.5, y: 0.5))
        XCTAssertFalse(zeroAspect.width.isNaN)
        XCTAssertFalse(zeroAspect.height.isNaN)
    }

    func testZoomRangeIsOneToFour() {
        XCTAssertEqual(SocialCropMath.zoomRange, 1...4)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/SocialCropMathTests`
Expected: FAIL — types don't exist.

- [ ] **Step 3: Implement**

```swift
//
//  SocialCropMath.swift
//  Muse
//
//  Pure crop-rect math for the social export crop stage. Foundation/CoreGraphics
//  only — no AppKit (Components/ pure-UI-math convention).
//

import CoreGraphics

enum SocialFit: String { case crop, matte, blurExtend }
enum MatteShade: String { case white, black }

enum SocialCropMath {
    static let zoomRange: ClosedRange<CGFloat> = 1...4

    /// The normalized source-crop rect (unit coords, display-oriented) for a target
    /// aspect at a zoom/center chosen in the crop UI. zoom 1 = the minimal crop that
    /// fills the target frame (aspect-fill); zoom z > 1 magnifies. Center is clamped
    /// so the rect never leaves the unit square.
    static func rect(sourceSize: CGSize, targetAspect: CGFloat,
                     zoom: CGFloat, center: CGPoint) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0, targetAspect > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let sourceAspect = sourceSize.width / sourceSize.height
        let clampedZoom = max(zoomRange.lowerBound, min(zoomRange.upperBound, zoom))

        // Minimal aspect-fill rect at zoom 1: fill the target aspect from the
        // source, cropping the longer dimension.
        var w: CGFloat
        var h: CGFloat
        if sourceAspect > targetAspect {
            // Source is relatively wider than target — crop width.
            h = 1.0
            w = targetAspect / sourceAspect
        } else {
            w = 1.0
            h = sourceAspect / targetAspect
        }
        // zoom > 1 shrinks the visible rect (magnifies the image).
        w /= clampedZoom
        h /= clampedZoom

        let cx = max(0, min(1, center.x))
        let cy = max(0, min(1, center.y))
        var x = cx - w / 2
        var y = cy - h / 2
        // Clamp so the rect never exits the unit square.
        x = max(0, min(1 - w, x))
        y = max(0, min(1 - h, y))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// §3.6 "save crop as version": compose the social rect into the photo's
    /// existing GeometryParams (the social rect is chosen in POST-geometry display
    /// space, so it maps inside the existing crop).
    static func composedCrop(existing: CGRect?, social: CGRect) -> CGRect {
        guard let existing = existing else { return social }
        return CGRect(
            x: existing.minX + social.minX * existing.width,
            y: existing.minY + social.minY * existing.height,
            width: social.width * existing.width,
            height: social.height * existing.height)
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/SocialCropMathTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Components/SocialCropMath.swift" "Muse/MuseTests/SocialCropMathTests.swift"
git commit -m "feat(social-export): SocialCropMath — pure crop-rect + composed-crop math"
```

### Task 4.3: `Export/Social/SocialMetadata.swift` — output metadata policy

**Files:**
- Create: `Muse/Muse/Export/Social/SocialMetadata.swift`
- Create: `Muse/MuseTests/SocialMetadataTests.swift`

**Interfaces:**
- Produces: `enum SocialMetadata { static func outputProperties(source: CFDictionary,
  includeLocation: Bool) -> CFDictionary }`.
- Consumes: `ImageMetadataStripper.isClean(_ data: Data) -> Bool` (verified shipped
  signature) — consumed by `SocialRenderTests`/`SocialRender`, not by this file
  directly (this file only builds an output properties dict; verification of the
  ENCODED bytes happens in `SocialRender`, Task 4.4).

- [ ] **Step 1: Write the failing tests**

```swift
//
//  SocialMetadataTests.swift
//  MuseTests
//

import XCTest
import ImageIO
@testable import Muse

final class SocialMetadataTests: XCTestCase {
    private func fixtureSourceProperties() -> CFDictionary {
        [
            kCGImagePropertyOrientation as String: 6,
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifLensMake as String: "Fujifilm",
                kCGImagePropertyExifApertureValue as String: 2.8,
            ],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Fujifilm",
                kCGImagePropertyTIFFModel as String: "X100V",
                kCGImagePropertyTIFFOrientation as String: 6,
            ],
            kCGImagePropertyIPTCDictionary as String: [
                kCGImagePropertyIPTCCredit as String: "Jane Doe",
                kCGImagePropertyIPTCCopyrightNotice as String: "© Jane Doe",
            ],
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 37.0,
                kCGImagePropertyGPSLongitude as String: 122.0,
            ],
            kCGImagePropertyMakerAppleDictionary as String: ["some": "makerNoteBlob"],
        ] as CFDictionary
    }

    func testExifOnKeepsCameraAndIPTCDropsGPSByDefault() {
        let out = SocialMetadata.outputProperties(source: fixtureSourceProperties(), includeLocation: false)
        let dict = out as! [String: Any]
        let tiff = dict[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake as String] as? String, "Fujifilm")
        let exif = dict[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertNotNil(exif)
        let iptc = dict[kCGImagePropertyIPTCDictionary as String] as? [String: Any]
        XCTAssertEqual(iptc?[kCGImagePropertyIPTCCredit as String] as? String, "Jane Doe")
        XCTAssertNil(dict[kCGImagePropertyGPSDictionary as String])
    }

    func testExifOnAlwaysDropsOrientationKeys() {
        let out = SocialMetadata.outputProperties(source: fixtureSourceProperties(), includeLocation: false)
        let dict = out as! [String: Any]
        XCTAssertNil(dict[kCGImagePropertyOrientation as String])
        let tiff = dict[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFOrientation as String])
    }

    func testExifOnAlwaysDropsMakerNotes() {
        let out = SocialMetadata.outputProperties(source: fixtureSourceProperties(), includeLocation: false)
        let dict = out as! [String: Any]
        XCTAssertNil(dict[kCGImagePropertyMakerAppleDictionary as String])
    }

    func testIncludeLocationKeepsGPS() {
        let out = SocialMetadata.outputProperties(source: fixtureSourceProperties(), includeLocation: true)
        let dict = out as! [String: Any]
        let gps = dict[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        XCTAssertEqual(gps?[kCGImagePropertyGPSLatitude as String] as? Double, 37.0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/SocialMetadataTests`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Implement**

```swift
//
//  SocialMetadata.swift
//  Muse
//
//  Output metadata policy for social export. Default (EXIF toggle off) writes NO
//  source properties at all — that path lives in SocialRender, which builds a
//  fresh properties dict carrying only the compression quality and verifies the
//  result via ImageMetadataStripper.isClean. This file covers ONLY the EXIF-on
//  (photography platforms) case: copy camera/lens/exposure (EXIF+TIFF) and
//  creator/copyright (IPTC), always drop orientation + thumbnails + maker notes,
//  and drop GPS unless a separate includeLocation opt-in is set (Deviation D6).
//

import ImageIO

enum SocialMetadata {
    static func outputProperties(source: CFDictionary, includeLocation: Bool) -> CFDictionary {
        var out: [String: Any] = [:]
        let src = source as? [String: Any] ?? [:]

        if var exif = src[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifSubjectLocation as String)
            out[kCGImagePropertyExifDictionary as String] = exif
        }
        if var tiff = src[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            // Orientation is ALWAYS dropped — pixels are baked at decode (SocialRender
            // step 3); an orientation tag surviving here would double-rotate.
            tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation as String)
            out[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if let iptc = src[kCGImagePropertyIPTCDictionary as String] as? [String: Any] {
            out[kCGImagePropertyIPTCDictionary as String] = iptc
        }
        if includeLocation, let gps = src[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
            out[kCGImagePropertyGPSDictionary as String] = gps
        }
        // Top-level orientation key, thumbnail/preview dictionaries, and maker
        // notes are never copied — they simply aren't read from `src` above.

        return out as CFDictionary
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/SocialMetadataTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Export/Social/SocialMetadata.swift" "Muse/MuseTests/SocialMetadataTests.swift"
git commit -m "feat(social-export): SocialMetadata — EXIF/IPTC/GPS output policy"
```

### Task 4.4: `Export/Social/SocialRender.swift` — the render pipeline

**Files:**
- Create: `Muse/Muse/Export/Social/SocialRender.swift`
- Create: `Muse/MuseTests/SocialRenderTests.swift`

**Interfaces:**
- Produces: `enum SocialRender { struct Job; struct Result; static func export(_ job:
  Job, to directory: URL) throws -> Result }` + the named pipeline constants.
- Consumes: `OutputRender.forOutput` (Phase 0), `ThumbnailCache.withinDecodeBudget`
  (verify exact signature via `grep -n "func withinDecodeBudget"
  Muse/Muse/Filesystem/ThumbnailCache.swift` before wiring — it's referenced by name
  from the durable-constraints doc but not independently verified in this plan's
  research pass; confirm and adjust the call if its signature differs), `SocialPreset`
  (Task 4.1), `SocialCropMath` (Task 4.2), `SocialMetadata` (Task 4.3),
  `ImageMetadataStripper.isClean(_ data: Data) -> Bool` (verified signature).

- [ ] **Step 1: Write the failing tests**

Fixture-driven — the test target needs a small set of real image fixtures (a landscape
JPEG ≥ 4000px wide, a portrait JPEG, a small <800px JPEG for the never-upscale case, and
an EXIF-oriented (orientation 6) JPEG). Confirm whether `MuseTests` already has an
`Fixtures/` or `TestAssets/` directory (`find Muse/MuseTests -iname "*fixture*" -o
-iname "*testassets*"`) and reuse its convention; if none exists, add
`Muse/MuseTests/Fixtures/Social/` and check in the four fixtures (small, synthetic
JPEGs generated via a one-off script — do not check in real photos).

```swift
//
//  SocialRenderTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class SocialRenderTests: XCTestCase {
    private var scratchDir: URL!

    override func setUp() {
        super.setUp()
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("social-render-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDir)
        super.tearDown()
    }

    private func fixture(_ name: String) -> URL {
        Bundle(for: Self.self).url(forResource: name, withExtension: "jpg", subdirectory: "Fixtures/Social")!
    }

    func testMatteOutputDimsExactlyEqualPresetDimsBothShades() throws {
        let preset = SocialPreset.all.first { $0.id == "ig-feed-portrait" }!  // 1080x1350
        for shade: MatteShade in [.white, .black] {
            let job = SocialRender.Job(sourceURL: fixture("landscape-6000x4000"), preset: preset,
                                       fit: .matte, matte: shade, cropRect: nil,
                                       includeEXIF: false, includeLocation: false)
            let result = try SocialRender.export(job, to: scratchDir)
            XCTAssertEqual(result.pixelSize, CGSize(width: 1080, height: 1350))
        }
    }

    func testCropOutputDimsExact() throws {
        let preset = SocialPreset.all.first { $0.id == "ig-square" }!  // 1080x1080
        let job = SocialRender.Job(sourceURL: fixture("landscape-6000x4000"), preset: preset,
                                   fit: .crop, matte: .white, cropRect: nil,
                                   includeEXIF: false, includeLocation: false)
        let result = try SocialRender.export(job, to: scratchDir)
        XCTAssertEqual(result.pixelSize, CGSize(width: 1080, height: 1080))
    }

    func testLongEdgeCapHonored() throws {
        let preset = SocialPreset.all.first { $0.id == "x" }!  // longEdge(4096)
        let job = SocialRender.Job(sourceURL: fixture("landscape-6000x4000"), preset: preset,
                                   fit: .crop, matte: .white, cropRect: nil,
                                   includeEXIF: false, includeLocation: false)
        let result = try SocialRender.export(job, to: scratchDir)
        XCTAssertEqual(max(result.pixelSize.width, result.pixelSize.height), 4096)
    }

    func testNeverUpscaleKeepsNativeSizeForASmallSource() throws {
        let preset = SocialPreset.all.first { $0.id == "facebook" }!  // longEdge(2048)
        let job = SocialRender.Job(sourceURL: fixture("small-600x400"), preset: preset,
                                   fit: .crop, matte: .white, cropRect: nil,
                                   includeEXIF: false, includeLocation: false)
        let result = try SocialRender.export(job, to: scratchDir)
        XCTAssertLessThanOrEqual(max(result.pixelSize.width, result.pixelSize.height), 600)
    }

    func testSRGBProfileEmbeddedAndNoAlpha() throws {
        let preset = SocialPreset.all.first { $0.id == "ig-square" }!
        let job = SocialRender.Job(sourceURL: fixture("landscape-6000x4000"), preset: preset,
                                   fit: .crop, matte: .white, cropRect: nil,
                                   includeEXIF: false, includeLocation: false)
        let result = try SocialRender.export(job, to: scratchDir)
        guard let src = CGImageSourceCreateWithURL(result.url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        else { return XCTFail("couldn't read output properties") }
        XCTAssertNil(props[kCGImagePropertyHasAlpha as String] as? Bool.self.self, "JPEG has no alpha by container")
        XCTAssertNotNil(props[kCGImagePropertyColorModel as String])
    }

    func testEXIFOrientedFixtureRendersRotatedPixelsWithNoOrientationTag() throws {
        let preset = SocialPreset.all.first { $0.id == "ig-square" }!
        let job = SocialRender.Job(sourceURL: fixture("oriented-6-portrait"), preset: preset,
                                   fit: .crop, matte: .white, cropRect: nil,
                                   includeEXIF: false, includeLocation: false)
        let result = try SocialRender.export(job, to: scratchDir)
        guard let src = CGImageSourceCreateWithURL(result.url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        else { return XCTFail("couldn't read output properties") }
        XCTAssertNil(props[kCGImagePropertyOrientation as String])
    }

    func testByteTargetLadderTerminatesUnderTargetOnACompressibleFixture() throws {
        let preset = SocialPreset.all.first { $0.id == "ig-feed-portrait" }!  // 800 KB target
        let job = SocialRender.Job(sourceURL: fixture("landscape-6000x4000"), preset: preset,
                                   fit: .matte, matte: .white, cropRect: nil,
                                   includeEXIF: false, includeLocation: false)
        let result = try SocialRender.export(job, to: scratchDir)
        XCTAssertLessThanOrEqual(result.bytes, 800 * 1024)
    }

    func testSharpenLevelMeasurablyChangesBytesBetweenNoneAndStandard() throws {
        // Distinctness, not quality: a preset with .standard sharpen produces a
        // DIFFERENT byte count than an otherwise-identical .none-sharpen render
        // of the same source at the same dims/quality (more edge detail = harder
        // to compress at a fixed quality).
        let flickr = SocialPreset.all.first { $0.id == "flickr" }!   // .none, original size
        let facebook = SocialPreset.all.first { $0.id == "facebook" }! // .standard, longEdge 2048
        // Not a like-for-like preset comparison (different dims) — instead assert
        // internally that sharpenStandard/sharpenLight constants are non-trivial
        // and distinct, which is what actually gates the pixel difference:
        XCTAssertNotEqual(SocialRender.sharpenStandard.radius, SocialRender.sharpenLight.radius)
        XCTAssertNotEqual(SocialRender.sharpenStandard.intensity, SocialRender.sharpenLight.intensity)
        XCTAssertEqual(flickr.sharpen, .none)
        XCTAssertEqual(facebook.sharpen, .standard)
    }

    func testXInvariantsIntegrationSmoke() throws {
        // Full coverage of the five X invariants lives in XPresetRuleTests (Task
        // 4.5) — this is a lightweight smoke check that export() doesn't throw
        // for the X preset on a normal fixture.
        let preset = SocialPreset.all.first { $0.id == "x" }!
        let job = SocialRender.Job(sourceURL: fixture("landscape-6000x4000"), preset: preset,
                                   fit: .crop, matte: .white, cropRect: nil,
                                   includeEXIF: false, includeLocation: false)
        XCTAssertNoThrow(try SocialRender.export(job, to: scratchDir))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/SocialRenderTests`
Expected: FAIL — type doesn't exist / fixtures missing (produce the 4 fixture JPEGs
first via a one-off script using `sips`/ImageIO before this step can even compile-fail
correctly — a missing fixture file crashes the test at `!`-unwrap, which is an
acceptable "confirm it fails for the right eventual reason" signal at Step 2 as long as
Step 1's authoring also includes producing the fixtures).

- [ ] **Step 3: Implement**

```swift
//
//  SocialRender.swift
//  Muse
//
//  The fixed render pipeline for social export. Every step is a named constant.
//  The choke point comes first — pixels enter via OutputRender.forOutput so an
//  edited photo exports with its edits applied (identity until Spec 04; automatic
//  once it lands).
//

import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum SocialRender {
    struct Job {
        var sourceURL: URL          // ORIGINAL library URL (forOutput resolves edits)
        var preset: SocialPreset
        var fit: SocialFit          // fixed presets only; ignored otherwise
        var matte: MatteShade
        var cropRect: CGRect?       // normalized; nil = center (fixed+crop only)
        var includeEXIF: Bool
        var includeLocation: Bool   // only honored when includeEXIF
    }
    struct Result { let url: URL; let pixelSize: CGSize; let bytes: Int }

    enum RenderError: Error {
        case decodeFailed
        case tooLarge
        case encodeFailed
        case verifyFailed
        case xInvariantFailed(String)
    }

    // Constants (single declaration site; owner-tunable):
    static let neverUpscale = true
    static let decodeCeilingFactor = 4        // decode ≤ 4 × output long edge…
    static let decodeFloor = 4096             // …but never below 4096 (crop headroom)
    static let sharpenStandard = (radius: 1.2, intensity: 0.5)   // CIUnsharpMask
    static let sharpenLight    = (radius: 0.8, intensity: 0.25)
    static let qualityStep = 0.05             // byte-target ladder
    static let qualityFloor = 0.70            // generic floor; X uses 0.55
    static let xQualityFloor = 0.55
    static let blurExtendRadiusFraction: CGFloat = 0.04
    static let xMaxDimension = 4096
    static let xMaxBytes = 5 * 1024 * 1024

    static func export(_ job: Job, to directory: URL) throws -> Result {
        // 1. Choke point — edited pixels ride here (identity today).
        let out = try OutputRender.forOutput(job.sourceURL)

        // 2. Budget gate.
        guard let cgSource = CGImageSourceCreateWithURL(out.url as CFURL, nil) else {
            throw RenderError.decodeFailed
        }
        guard ThumbnailCache.withinDecodeBudget(cgSource) else { throw RenderError.tooLarge }
        guard let sourceProps = CGImageSourceCopyPropertiesAtIndex(cgSource, 0, nil) as? [String: Any],
              let srcW = sourceProps[kCGImagePropertyPixelWidth as String] as? Int,
              let srcH = sourceProps[kCGImagePropertyPixelHeight as String] as? Int
        else { throw RenderError.decodeFailed }
        let sourceSize = CGSize(width: srcW, height: srcH)

        // Target dims per preset kind, applying the never-upscale rule.
        let targetSize = Self.targetSize(for: job.preset.kind, sourceSize: sourceSize)

        // 3. Decode display-oriented at a bounded ceiling (orientation BAKED —
        //    no output orientation tag can ever exist afterward).
        let outputLongEdge = max(targetSize.width, targetSize.height)
        let decodeMax: Int
        switch job.preset.kind {
        case .original:
            decodeMax = Int(max(sourceSize.width, sourceSize.height))
        default:
            decodeMax = Int(min(max(sourceSize.width, sourceSize.height),
                                max(CGFloat(decodeFloor), CGFloat(decodeCeilingFactor) * outputLongEdge)))
        }
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeMax,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(cgSource, 0, decodeOptions as CFDictionary) else {
            throw RenderError.decodeFailed
        }

        // 4. Fit compose.
        var ciImage = CIImage(cgImage: decoded)
        let didDownscale: Bool
        switch job.preset.kind {
        case .fixed(let w, let h):
            let targetAspect = CGFloat(w) / CGFloat(h)
            let cropRect = job.cropRect ?? SocialCropMath.rect(
                sourceSize: CGSize(width: decoded.width, height: decoded.height),
                targetAspect: targetAspect, zoom: 1, center: CGPoint(x: 0.5, y: 0.5))
            switch job.fit {
            case .crop:
                let pixelCrop = CGRect(x: cropRect.minX * CGFloat(decoded.width),
                                       y: cropRect.minY * CGFloat(decoded.height),
                                       width: cropRect.width * CGFloat(decoded.width),
                                       height: cropRect.height * CGFloat(decoded.height))
                ciImage = ciImage.cropped(to: pixelCrop)
                    .transformed(by: CGAffineTransform(translationX: -pixelCrop.minX, y: -pixelCrop.minY))
                ciImage = Self.lanczosScale(ciImage, to: CGSize(width: CGFloat(w), height: CGFloat(h)))
            case .matte:
                let fitted = Self.lanczosScaleAspectFit(ciImage, into: CGSize(width: CGFloat(w), height: CGFloat(h)))
                ciImage = Self.composite(fitted, overMatte: job.matte, targetSize: CGSize(width: CGFloat(w), height: CGFloat(h)))
            case .blurExtend:
                let filled = Self.lanczosScale(ciImage, to: CGSize(width: CGFloat(w), height: CGFloat(h)))
                let blurred = filled.clampedToExtent()
                    .applyingGaussianBlur(sigma: Self.blurExtendRadiusFraction * max(CGFloat(w), CGFloat(h)))
                    .cropped(to: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
                let fitted = Self.lanczosScaleAspectFit(ciImage, into: CGSize(width: CGFloat(w), height: CGFloat(h)))
                ciImage = fitted.composited(over: blurred)
            }
            didDownscale = max(sourceSize.width, sourceSize.height) > max(CGFloat(w), CGFloat(h))
        case .longEdge(let cap):
            let targetLong = neverUpscale
                ? min(CGFloat(cap), max(sourceSize.width, sourceSize.height))
                : CGFloat(cap)
            let scale = targetLong / max(CGFloat(decoded.width), CGFloat(decoded.height))
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            didDownscale = scale < 1
        case .original:
            didDownscale = false
        }

        // 5. Output sharpen — ONLY when a downscale actually happened.
        if didDownscale {
            let (radius, intensity): (Double, Double)
            switch job.preset.sharpen {
            case .none: (radius, intensity) = (0, 0)
            case .light: (radius, intensity) = sharpenLight
            case .standard: (radius, intensity) = sharpenStandard
            }
            if intensity > 0 {
                ciImage = ciImage.applyingFilter("CIUnsharpMask",
                    parameters: [kCIInputRadiusKey: radius, kCIInputIntensityKey: intensity])
            }
        }

        // 6. Flatten + sRGB.
        let matteColor: CIColor = job.matte == .black ? .black : .white
        let flattened = ciImage.composited(over: CIImage(color: matteColor).cropped(to: ciImage.extent))
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        guard let finalCG = context.createCGImage(flattened, from: flattened.extent,
                                                   format: .RGBA8, colorSpace: sRGB) else {
            throw RenderError.encodeFailed
        }

        // 7 + 8. Encode with the byte-target ladder, verify, write.
        let stem = job.sourceURL.deletingPathExtension().lastPathComponent
        let baseName = "\(stem)-\(job.preset.id)"
        let destURL = Self.collisionSafeURL(base: baseName, ext: "jpg", in: directory)

        let floor = job.preset.id == "x" ? xQualityFloor : qualityFloor
        var quality = job.preset.quality
        var data: Data?
        repeat {
            data = try Self.encodeJPEG(finalCG, quality: quality, job: job, sourceProps: sourceProps)
            if let target = job.preset.byteTargetKB, let d = data, d.count > target * 1024, quality > floor {
                quality = max(floor, quality - qualityStep)
                continue
            }
            break
        } while true

        guard let finalData = data else { throw RenderError.encodeFailed }

        if job.preset.id == "x" {
            try Self.verifyXInvariants(data: finalData, pixelSize: CGSize(width: finalCG.width, height: finalCG.height))
        }

        if job.includeEXIF == false {
            guard ImageMetadataStripper.isClean(finalData) else { throw RenderError.verifyFailed }
        }

        try finalData.write(to: destURL, options: .atomic)
        return Result(url: destURL, pixelSize: CGSize(width: finalCG.width, height: finalCG.height), bytes: finalData.count)
    }

    // MARK: helpers

    private static func targetSize(for kind: SocialPreset.Kind, sourceSize: CGSize) -> CGSize {
        switch kind {
        case .fixed(let w, let h): return CGSize(width: w, height: h)
        case .longEdge(let cap):
            let long = neverUpscale ? min(CGFloat(cap), max(sourceSize.width, sourceSize.height)) : CGFloat(cap)
            let aspect = sourceSize.width / sourceSize.height
            return aspect >= 1 ? CGSize(width: long, height: long / aspect) : CGSize(width: long * aspect, height: long)
        case .original: return sourceSize
        }
    }

    private static func lanczosScale(_ image: CIImage, to size: CGSize) -> CIImage {
        let scaleX = size.width / image.extent.width
        let scaleY = size.height / image.extent.height
        return image.applyingFilter("CILanczosScaleTransform",
            parameters: [kCIInputScaleKey: scaleY, kCIInputAspectRatioKey: scaleX / scaleY])
    }

    private static func lanczosScaleAspectFit(_ image: CIImage, into size: CGSize) -> CIImage {
        let scale = min(size.width / image.extent.width, size.height / image.extent.height)
        let scaled = image.applyingFilter("CILanczosScaleTransform",
            parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
        let dx = (size.width - scaled.extent.width) / 2
        let dy = (size.height - scaled.extent.height) / 2
        return scaled.transformed(by: CGAffineTransform(translationX: dx - scaled.extent.minX, y: dy - scaled.extent.minY))
    }

    private static func composite(_ image: CIImage, overMatte shade: MatteShade, targetSize: CGSize) -> CIImage {
        let color: CIColor = shade == .black ? .black : .white
        let matte = CIImage(color: color).cropped(to: CGRect(origin: .zero, size: targetSize))
        return image.composited(over: matte)
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double, job: Job, sourceProps: [String: Any]) throws -> Data {
        guard let mutableData = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(mutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw RenderError.encodeFailed }
        var properties: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: quality]
        if job.includeEXIF {
            let merged = SocialMetadata.outputProperties(source: sourceProps as CFDictionary,
                                                          includeLocation: job.includeLocation) as! [String: Any]
            properties.merge(merged) { _, new in new }
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.encodeFailed }
        return mutableData as Data
    }

    private static func verifyXInvariants(data: Data, pixelSize: CGSize) throws {
        guard pixelSize.width <= CGFloat(xMaxDimension), pixelSize.height <= CGFloat(xMaxDimension) else {
            throw RenderError.xInvariantFailed("dims exceed 4096")
        }
        guard data.count < xMaxBytes else { throw RenderError.xInvariantFailed("bytes ≥ 5 MB") }
        guard Double(data.count) < Double(pixelSize.width * pixelSize.height) else {
            throw RenderError.xInvariantFailed("bytes ≥ width × height")
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        else { throw RenderError.xInvariantFailed("undecodable output") }
        guard props[kCGImagePropertyOrientation as String] == nil else {
            throw RenderError.xInvariantFailed("orientation tag present")
        }
        guard (props[kCGImagePropertyHasAlpha as String] as? Bool) != true else {
            throw RenderError.xInvariantFailed("alpha present")
        }
    }

    /// The EditCopyNaming-style collision ladder: <stem>-<preset.id>.jpg, then
    /// -2, -3… case-insensitively.
    private static func collisionSafeURL(base: String, ext: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var n = 2
        let fm = FileManager.default
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
```

Read `ThumbnailCache.withinDecodeBudget`'s exact current signature before wiring Step
2's call (`CGImageSource` vs `CGImage` vs `URL` parameter — adjust the call site to
match; the durable-constraints doc describes it as a "300 MP header check" consuming a
decoded source/URL, but the exact parameter type must be confirmed live). Confirm
`ImageMetadataStripper.isClean(_ data: Data) -> Bool`'s signature (verified above —
matches the call as written).

- [ ] **Step 4: Run tests, confirm pass**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/SocialRenderTests`
Expected: PASS. If a specific dims/byte-target assertion is off by a small margin due
to `CILanczosScaleTransform`'s exact rounding, adjust the pipeline's rounding (round to
nearest integer pixel before the final crop/scale step) rather than loosening the test
— exact target dims is an acceptance-line requirement (matte AND crop), not a
nice-to-have.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Export/Social/SocialRender.swift" "Muse/MuseTests/SocialRenderTests.swift" \
  "Muse/MuseTests/Fixtures/Social/"
git commit -m "feat(social-export): SocialRender — the fixed render pipeline"
```

### Task 4.5: `XPresetRuleTests` — the five X invariants on adversarial fixtures

**Files:**
- Create: `Muse/MuseTests/XPresetRuleTests.swift`

**Interfaces:**
- Consumes: `SocialRender.export` (Task 4.4), the X preset (`SocialPreset.all.first {
  $0.id == "x" }`).

This is a DEDICATED test file (per spec-07-implementation.md §8's explicit listing,
separate from `SocialRenderTests`) because the X invariants are marketing-line-grade
guarantees, not general pipeline behavior — worth isolating so a future pipeline change
that breaks JUST the X invariants shows up as a named, obviously-X-related failure.

- [ ] **Step 1: Write the failing tests**

```swift
//
//  XPresetRuleTests.swift
//  MuseTests
//
//  The five hard invariants X's no-recompress rule requires (spec-07-implementation
//  .md §3.4), pinned on fixtures including a 6000-px source and a synthetic
//  high-entropy image that forces the byte-target ladder to its floor.
//

import XCTest
@testable import Muse

final class XPresetRuleTests: XCTestCase {
    private var scratchDir: URL!
    private var xPreset: SocialPreset { SocialPreset.all.first { $0.id == "x" }! }

    override func setUp() {
        super.setUp()
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("x-preset-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDir)
        super.tearDown()
    }

    private func fixture(_ name: String) -> URL {
        Bundle(for: Self.self).url(forResource: name, withExtension: "jpg", subdirectory: "Fixtures/Social")!
    }

    func testDimsNeverExceed4096x4096OnA6000pxSource() throws {
        let job = SocialRender.Job(sourceURL: fixture("landscape-6000x4000"), preset: xPreset,
                                   fit: .crop, matte: .white, cropRect: nil,
                                   includeEXIF: false, includeLocation: false)
        let result = try SocialRender.export(job, to: scratchDir)
        XCTAssertLessThanOrEqual(result.pixelSize.width, 4096)
        XCTAssertLessThanOrEqual(result.pixelSize.height, 4096)
    }

    func testEncodedSizeUnder5MBEvenOnHighEntropySource() throws {
        // A synthetic high-entropy image (random noise) forces the byte-target
        // ladder toward its floor — confirms the ladder actually reaches
        // xQualityFloor (0.55) rather than the generic 0.70 and still lands
        // under 5 MB.
        let job = SocialRender.Job(sourceURL: fixture("noise-4096x4096"), preset: xPreset,
                                   fit: .crop, matte: .white, cropRect: nil,
                                   includeEXIF: false, includeLocation: false)
        let result = try SocialRender.export(job, to: scratchDir)
        XCTAssertLessThan(result.bytes, 5 * 1024 * 1024)
    }

    func testRGBNoAlpha() throws {
        let job = SocialRender.Job(sourceURL: fixture("landscape-6000x4000"), preset: xPreset,
                                   fit: .crop, matte: .white, cropRect: nil,
                                   includeEXIF: false, includeLocation: false)
        let result = try SocialRender.export(job, to: scratchDir)
        guard let src = CGImageSourceCreateWithURL(result.url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        else { return XCTFail("undecodable output") }
        XCTAssertNotEqual(props[kCGImagePropertyHasAlpha as String] as? Bool, true)
    }

    func testNoEXIFOrientationTag() throws {
        let job = SocialRender.Job(sourceURL: fixture("oriented-6-portrait"), preset: xPreset,
                                   fit: .crop, matte: .white, cropRect: nil,
                                   includeEXIF: false, includeLocation: false)
        let result = try SocialRender.export(job, to: scratchDir)
        guard let src = CGImageSourceCreateWithURL(result.url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        else { return XCTFail("undecodable output") }
        XCTAssertNil(props[kCGImagePropertyOrientation as String])
    }

    func testBytesLessThanWidthTimesHeight() throws {
        let job = SocialRender.Job(sourceURL: fixture("landscape-6000x4000"), preset: xPreset,
                                   fit: .crop, matte: .white, cropRect: nil,
                                   includeEXIF: false, includeLocation: false)
        let result = try SocialRender.export(job, to: scratchDir)
        XCTAssertLessThan(Double(result.bytes), Double(result.pixelSize.width * result.pixelSize.height))
    }
}
```

Produce the `noise-4096x4096.jpg` fixture via a small one-off script generating random
RGB noise (maximally incompressible content) at 4096×4096, encoded at high quality so
the ladder has real work to do; check it into `Fixtures/Social/` alongside the others.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/XPresetRuleTests`
Expected: FAIL until the `noise-4096x4096.jpg` fixture exists and `SocialRender` (Task
4.4) is in place; once both exist, these tests exercise ALREADY-implemented invariant
checks inside `SocialRender.verifyXInvariants` — so per this task's own scope, Step 2's
"real" failure signal is the missing fixture, and Step 3 is "produce the fixture," not
new production code (the invariant-checking code was written in Task 4.4).

- [ ] **Step 3: Produce the fixture; confirm no `SocialRender` code changes are needed**

If any of the five tests fails against Task 4.4's implementation (as opposed to failing
only for a missing fixture), that is a real Task 4.4 defect — fix `SocialRender`, not
this test file, since the five invariants are non-negotiable per Global Constraints.

- [ ] **Step 4: Run tests, confirm pass**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/XPresetRuleTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/MuseTests/XPresetRuleTests.swift" "Muse/MuseTests/Fixtures/Social/noise-4096x4096.jpg"
git commit -m "test(social-export): XPresetRuleTests — pin the five X no-recompress invariants"
```

### Task 4.6: `AppState.socialExportRequest` — the one new shell-modal flag

**Files:**
- Modify: `Muse/Muse/Models/AppState.swift`

**Interfaces:**
- Produces: `struct SocialExportRequest: Identifiable, Equatable { let id = UUID(); var
  urls: [URL] }`, `@Published var socialExportRequest: SocialExportRequest?`.
- Consumes: nothing new.

This is Deviation D2 — the ONE new `@Published` property this plan adds, the sanctioned
`collectionModal`-class shell-modal flag (a card raised from a context menu can't
present itself).

- [ ] **Step 1: No pure-logic test possible for a bare `@Published` property** — its
  correctness is structural (compiles, is observed by SwiftUI) and covered indirectly
  by Task 4.7's card mounting/dismounting only while `socialExportRequest != nil`. Skip
  to implementation.

- [ ] **Step 2: Add the type + property**

Near the existing `collectionModal` declaration (verified line 540) and its preceding
doc comment (lines 530-539):

```swift
/// A per-run social export request — the sanctioned shell-modal-flag class
/// (collectionModal precedent). Raised from three entry points (grid context menu,
/// hero viewer, collection header) that can't present a card themselves.
struct SocialExportRequest: Identifiable, Equatable {
    let id = UUID()
    var urls: [URL]           // raster kinds only, grid order
}
```

```swift
    @Published var socialExportRequest: SocialExportRequest?
```

- [ ] **Step 3: Register in `modalPresented`**

Modify the verified `modalPresented` body (lines 514-528):

```swift
    var modalPresented: Bool {
        infoShown || imageLayoutShown || settingsShown || driveSharesShown
            || duplicatesSheetVisible || reconnectShown
            || metadataImportRequest != nil || collectionModal != nil
            || addTagRequest != nil || newCollectionRequest
            || alertRequest != nil
            || folderOpError != nil || backupError != nil
            || fileRenameError != nil || !moveFailureNames.isEmpty
            || collectionRenameAlertRequest != nil || fileRenameRequest != nil
            || newSubfolderRequest != nil || folderRenameRequest != nil
            || tagRenameRequest != nil
            || socialExportRequest != nil
    }
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse build`
Expected: BUILD SUCCEEDED (the type has no consumers yet until Task 4.7/4.8 — this is
intentionally a compile-clean no-op commit).

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Models/AppState.swift"
git commit -m "feat(social-export): AppState.socialExportRequest (D2 — the one new @Published flag)"
```

### Task 4.7: `Views/Export/SocialExportCard.swift` + `SocialExportModel`

**Files:**
- Create: `Muse/Muse/Views/Export/SocialExportCard.swift`
- Modify: `Muse/Muse/ContentView.swift` (present the card via `.museModal`)

**Interfaces:**
- Produces: `struct SocialExportCard: View`, `@MainActor final class SocialExportModel:
  ObservableObject` (per-run, non-singleton — the `MetadataImportModel` shape).
- Consumes: `AppState.socialExportRequest` (Task 4.6), `SocialPreset.all` (Task 4.1),
  `SocialCropMath` (Task 4.2), `SocialRender` (Task 4.4), `ThumbnailCache
  .withinDecodeBudget` (direct decode for the crop-stage preview — no
  `ThumbnailCache` ENTRY, the compare-pane precedent), `ModalButton`, `ModalMessageCard`
  / `AppState.alertRequest` (`MuseAlert` seam), `AppSettings.socialExifChoices`,
  `.socialMatteShade`.

Per house convention (no UI unit tests), this task's correctness gate is manual
verification. The `SocialExportModel`'s PURE per-image state transitions (crop/zoom
storage, pager index bounds) could be pulled into a tiny pure helper and tested, but the
spec doesn't call for one and the model's job here is thin state-holding over already-
tested pure math (`SocialCropMath`) — no new logic to pin.

- [ ] **Step 1: Add the `AppSettings` keys this card needs**

```swift
    // Muse/Muse/Settings/AppSettings.swift, beside driveShareLayout:
    static var socialExifChoices: [String: Bool] {
        get { (UserDefaults.standard.dictionary(forKey: "socialExifChoices") as? [String: Bool]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "socialExifChoices") }
    }
    static var socialMatteShade: String {
        get { UserDefaults.standard.string(forKey: "socialMatteShade") ?? MatteShade.white.rawValue }
        set { UserDefaults.standard.set(newValue, forKey: "socialMatteShade") }
    }
```

The location (GPS) sub-toggle is deliberately NOT given an `AppSettings` key — it
always reverts to OFF (Deviation D6), held only in the model's transient `@Published`
state.

- [ ] **Step 2: Implement `SocialExportModel`**

```swift
//
//  SocialExportCard.swift
//  Muse
//

import SwiftUI
import UniformTypeIdentifiers

@MainActor final class SocialExportModel: ObservableObject {
    struct PerImageState: Equatable {
        var zoom: CGFloat = 1
        var center: CGPoint = CGPoint(x: 0.5, y: 0.5)
    }

    @Published var urls: [URL]
    @Published var pageIndex: Int = 0
    @Published var preset: SocialPreset = SocialPreset.all.first { $0.id == "ig-feed-portrait" }!
    @Published var fit: SocialFit = .crop
    @Published var matte: MatteShade
    @Published var includeEXIF: Bool
    @Published var includeLocation: Bool = false   // never remembered — D6
    @Published var perImage: [URL: PerImageState] = [:]
    @Published var isExporting = false
    @Published var exportProgress: (Int, Int) = (0, 0)
    @Published var failures: [String] = []   // filenames, surfaced via MuseAlert on completion

    init(urls: [URL]) {
        self.urls = urls
        self.matte = MatteShade(rawValue: AppSettings.socialMatteShade) ?? .white
        self.includeEXIF = SocialExportModel.rememberedEXIF(for: "ig-feed-portrait", default: false)
    }

    var currentURL: URL? { urls.indices.contains(pageIndex) ? urls[pageIndex] : nil }

    func state(for url: URL) -> PerImageState { perImage[url] ?? PerImageState() }
    func setState(_ s: PerImageState, for url: URL) { perImage[url] = s }

    func selectPreset(_ p: SocialPreset) {
        preset = p
        includeEXIF = Self.rememberedEXIF(for: p.id, default: p.exifDefaultOn)
        includeLocation = false   // D6 — never remembered
        if case .fixed = p.kind {} else { fit = .crop }   // fit control hidden for non-fixed
    }

    func rememberEXIFChoice() {
        var choices = AppSettings.socialExifChoices
        choices[preset.id] = includeEXIF
        AppSettings.socialExifChoices = choices
    }

    func rememberMatteShade() { AppSettings.socialMatteShade = matte.rawValue }

    private static func rememberedEXIF(for presetID: String, default def: Bool) -> Bool {
        AppSettings.socialExifChoices[presetID] ?? def
    }

    /// Runs the export sequentially off-main; per-file failures collect into
    /// `failures` rather than aborting the run.
    func export(to directory: URL) async {
        isExporting = true
        failures = []
        exportProgress = (0, urls.count)
        for (i, url) in urls.enumerated() {
            let state = self.state(for: url)
            let job = SocialRender.Job(
                sourceURL: url, preset: preset, fit: fit, matte: matte,
                cropRect: fit == .crop ? SocialCropMath.rect(
                    sourceSize: .zero, targetAspect: 1, zoom: state.zoom, center: state.center) : nil,
                includeEXIF: includeEXIF, includeLocation: includeLocation)
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try SocialRender.export(job, to: directory)
                }.value
            } catch {
                failures.append(url.lastPathComponent)
            }
            exportProgress = (i + 1, urls.count)
        }
        isExporting = false
        rememberEXIFChoice()
        if fit == .matte || fit == .blurExtend { rememberMatteShade() }
    }
}
```

`job.cropRect`'s `sourceSize: .zero` above is a placeholder that must be replaced with
the REAL per-image decoded size before calling `SocialCropMath.rect` — `SocialRender
.export` re-derives its own crop rect internally from `sourceSize`/`targetAspect` when
`cropRect` is passed as a normalized rect already computed against the DISPLAYED
(decoded) image, not the raw file. Correct this by having the card's crop-stage
preview decode (Step 3) cache each image's decoded pixel size in `PerImageState` (add
`var decodedSize: CGSize?` to `PerImageState`, populated on preview decode, and use
`state.decodedSize ?? .zero` when constructing the job's `cropRect`) — implement this
adjustment as part of Step 2's real code, not left dangling.

- [ ] **Step 3: Implement `SocialExportCard`'s two-column layout**

```swift
struct SocialExportCard: View {
    @StateObject private var model: SocialExportModel
    @EnvironmentObject private var appState: AppState
    let onClose: () -> Void

    init(request: AppState.SocialExportRequest, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: SocialExportModel(urls: request.urls))
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 0) {
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            controls
                .frame(width: 260)
        }
        .frame(height: 520)
    }

    private var stage: some View {
        VStack {
            if let url = model.currentURL {
                SocialCropStageView(url: url, preset: model.preset, fit: model.fit,
                                    matte: model.matte, state: Binding(
                                        get: { model.state(for: url) },
                                        set: { model.setState($0, for: url) }))
            }
            if model.urls.count > 1 {
                pager
            }
        }
        .padding(16)
    }

    private var pager: some View {
        HStack {
            Button(action: { model.pageIndex = max(0, model.pageIndex - 1) }) {
                Image(systemName: "chevron.left")
            }.disabled(model.pageIndex == 0)
            Text("\(model.pageIndex + 1) of \(model.urls.count)")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button(action: { model.pageIndex = min(model.urls.count - 1, model.pageIndex + 1) }) {
                Image(systemName: "chevron.right")
            }.disabled(model.pageIndex == model.urls.count - 1)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            presetPicker
            if case .fixed = model.preset.kind {
                fitModePicker
            }
            if let warning = model.preset.warningKey {
                Text(String(localized: String.LocalizationValue(warning)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            exifToggle
            Spacer()
            neverUpscaleNoticeIfNeeded
            footer
        }
        .padding(16)
    }

    private var presetPicker: some View {
        Picker(String(localized: "Preset"), selection: Binding(
            get: { model.preset.id },
            set: { id in if let p = SocialPreset.all.first(where: { $0.id == id }) { model.selectPreset(p) } })) {
            Section(String(localized: "Instagram")) {
                ForEach(SocialPreset.all.filter { $0.id.hasPrefix("ig-") }, id: \.id) { p in
                    Text(String(localized: String.LocalizationValue(p.nameKey))).tag(p.id)
                }
            }
            Section(String(localized: "Threads")) {
                Text(String(localized: "Threads")).tag("threads")
            }
            Section(String(localized: "X")) {
                Text(String(localized: "X")).tag("x")
            }
            Section(String(localized: "Facebook")) {
                Text(String(localized: "Facebook")).tag("facebook")
            }
            Section(String(localized: "Pinterest")) {
                Text(String(localized: "Pinterest")).tag("pinterest")
            }
            Section(String(localized: "Photography")) {
                Text(String(localized: "Flickr / 500px")).tag("flickr")
                Text(String(localized: "Glass")).tag("glass")
            }
        }
        .pickerStyle(.menu)
    }

    private var fitModePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: $model.fit) {
                Text("Crop").tag(SocialFit.crop)
                Text("Matte").tag(SocialFit.matte)
                Text("Blur").tag(SocialFit.blurExtend)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if model.fit == .matte || model.fit == .blurExtend {
                HStack(spacing: 8) {
                    matteDot(.white)
                    matteDot(.black)
                }
            }
        }
    }

    private func matteDot(_ shade: MatteShade) -> some View {
        Circle()
            .fill(shade == .white ? Color.white : Color.black)
            .frame(width: 16, height: 16)
            .overlay(Circle().stroke(Color.secondary, lineWidth: model.matte == shade ? 2 : 0.5))
            .onTapGesture { model.matte = shade }
    }

    private var exifToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(String(localized: "Include camera info (EXIF)"), isOn: $model.includeEXIF)
            if model.includeEXIF {
                Toggle(String(localized: "Include location"), isOn: $model.includeLocation)
                    .padding(.leading, 16)
                    .font(.system(size: 12))
            }
        }
    }

    @ViewBuilder private var neverUpscaleNoticeIfNeeded: some View {
        EmptyView()   // populated once per-image decoded size is threaded through (Step 2 note)
    }

    private var footer: some View {
        HStack {
            ModalButton(title: String(localized: "Cancel"), kind: .normal) { onClose() }
            Spacer()
            if model.isExporting {
                ProgressView(value: Double(model.exportProgress.0), total: Double(max(1, model.exportProgress.1)))
                    .frame(width: 100)
            } else {
                ModalButton(title: String(localized: "Export…"), kind: .prominent) {
                    Task { await runExport() }
                }
            }
        }
    }

    private func runExport() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        await model.export(to: directory)
        if model.failures.isEmpty == false {
            appState.alertRequest = .message(
                title: String(localized: "Some Exports Failed"),
                message: model.failures.joined(separator: ", "))
        } else {
            onClose()
        }
    }
}
```

`SocialCropStageView` (the actual crop/pan/zoom stage) is a substantial sub-view in its
own right — implement it as a sibling `struct SocialCropStageView: View` in the same
file: it direct-decodes the current image at `previewMaxPixel = 2048` (bounded by
`ThumbnailCache.withinDecodeBudget`, NO `ThumbnailCache` entry), draws the fixed target
frame for `.fixed` presets, and handles drag-to-pan + scroll/pinch-to-zoom within
`SocialCropMath.zoomRange` updating the bound `PerImageState`; for story presets it
overlays the 250/1920-fraction safe-zone bands; for `.matte`/`.blurExtend` it renders
the actual composite preview (reuse `SocialRender`'s compose helpers at preview
resolution, or a simplified SwiftUI-native approximation — prefer reusing
`SocialRender`'s CI pipeline directly for WYSIWYG accuracy over a from-scratch SwiftUI
approximation). Given its size, treat `SocialCropStageView`'s implementation as its own
follow-up TDD sub-step within this task rather than fully inlining here — the crop/pan/
zoom GESTURE handling is UI code (house rule: no UI unit tests), so its correctness
gate is the manual verification in Step 5.

- [ ] **Step 4: Present the card from `ContentView.swift`**

```swift
            .museModal(isPresented: Binding(
                get: { appState.socialExportRequest != nil },
                set: { if !$0 { appState.socialExportRequest = nil } }),
                       width: 720,
                       palette: appState.moodPalette) {
                if let request = appState.socialExportRequest {
                    SocialExportCard(request: request) {
                        appState.socialExportRequest = nil
                    }
                }
            }
```

Add this modifier chained alongside the existing `.museModal` for `collectionModal`
(verified at ContentView.swift lines 266-292) — a SEPARATE `.museModal` call, not a
branch inside the existing one (the two flags are independent and must never both be
true at once in practice, but structurally they're unrelated modal families).

- [ ] **Step 5: Build and manually verify**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build`,
`stat` the binary. Manually: open the card (once Task 4.8 wires an entry point),
confirm the two-column layout, preset switching, fit-mode switching (fixed presets
only), crop pan/zoom, EXIF toggle + location sub-toggle, export to a folder, confirm
output files land with the `<stem>-<preset.id>.jpg` naming and open correctly.

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Views/Export/SocialExportCard.swift" "Muse/Muse/ContentView.swift" \
  "Muse/Muse/Settings/AppSettings.swift"
git commit -m "feat(social-export): SocialExportCard — crop/preset/export UI"
```

### Task 4.8: Entry points — grid context menu, hero viewer, collection header

**Files:**
- Modify: `Muse/Muse/Views/SelectionMenu.swift`
- Modify: `Muse/Muse/Views/Viewer/ShareButton.swift`
- Modify: `Muse/Muse/Views/ShareCollectionButton.swift`

**Interfaces:**
- Consumes: `AppState.socialExportRequest` (Task 4.6). Raster-kind filter — reuse the
  exact pattern of `ShareCollectionButton.driveShareURLs` (`.image`/`.raw`/`.psd`) at
  each site; `SelectionMenu`/`ShareButton` don't currently have such a filter (their
  `fileURLs`/`url` are unfiltered), so this task adds one at each site.

- [ ] **Step 1: `SelectionMenu.swift` — grid context menu**

Verified current menu (item 5 in the research pass): `Button("Share") { share() }` at
line 77. Add directly below it:

```swift
            Button("Share") { share() }
            Button("Export for Social…") { exportForSocial() }
                .disabled(socialExportURLs.isEmpty)
```

```swift
    private var socialExportURLs: [URL] {
        // Mirrors ShareCollectionButton.driveShareURLs — raster kinds only.
        // fileURLs/selectedNodes: confirm the exact existing selection-source
        // property name via grep before wiring (SelectionMenu.swift's `fileURLs`
        // is referenced elsewhere in the file per the verified dump's addTag()).
        fileURLs.filter { url in
            // If SelectionMenu already carries FileNode.kind info via a parallel
            // array/dict, filter on that instead of re-deriving from extension —
            // confirm via grep "kind" in this file before choosing the approach.
            ["jpg", "jpeg", "png", "heic", "tiff", "raw", "dng", "cr2", "nef", "arw", "psd"]
                .contains(url.pathExtension.lowercased())
        }
    }

    private func exportForSocial() {
        appState.socialExportRequest = SocialExportRequest(urls: socialExportURLs)
    }
```

Prefer deriving the raster-kind filter from `AssetKind` (the shipped classification
type used everywhere else in the app, e.g. `driveShareURLs`'s `switch node.kind {
case .image, .raw, .psd: ... }`) rather than a hardcoded extension list — the extension
list above is a fallback ONLY if `SelectionMenu`'s selection source doesn't already
carry `FileNode`/`AssetKind` values alongside the bare `URL`s. Read
`SelectionMenu.swift`'s `fileURLs` property definition in full before choosing; if it's
sourced from `FileNode`s (likely, matching every other selection-derived property in
the app), filter on `.kind` exactly like `driveShareURLs` does, not on extension.

- [ ] **Step 2: `ShareButton.swift` — hero viewer menu**

Verified current menu: `Button("Share") { share() }` then `Divider()` then `Button("Open")`
then `Menu("Open With")`. Add directly below "Share":

```swift
        Menu {
            Button("Share") { share() }
            Button("Export for Social…") { exportForSocial() }
                .disabled(AssetKind.isRaster(for: url) == false)
            Divider()
            Button("Open") { NSWorkspace.shared.open(url) }
            Menu("Open With") { OpenWithItems(url: url) }
        } label: {
```

```swift
    private func exportForSocial() {
        appState.socialExportRequest = SocialExportRequest(urls: [url])
    }
```

`AssetKind.isRaster(for:)` may not exist as a standalone helper — grep
`Muse/Muse/Models/AssetKind.swift` for the existing classification API (likely
`AssetKind(url:)` returning an enum with `.image`/`.raw`/`.psd`/etc. cases, matching
`driveShareURLs`'s `switch node.kind`). If `ShareButton` only has a bare `url: URL`
(no `FileNode`), classify it directly: `let kind = AssetKind(url: url); return kind ==
.image || kind == .raw || kind == .psd` — write this as a small private computed
property (`private var isRasterKind: Bool`) rather than inlining the switch twice.

- [ ] **Step 3: `ShareCollectionButton.swift` — collection header menu**

Add under "Share Drive Link" / the portfolio items (from Task 3.7 Step 8):

```swift
        Menu {
            Button("Save to…") { Task { await save() } }
            Button("Share Drive Link") { presentDriveShare(mode: .share) }
                .disabled(driveShareURLs.isEmpty)
            Button("Export for Social…") { exportForSocial() }
                .disabled(driveShareURLs.isEmpty)
            // ... portfolio Divider/items from Task 3.7 ...
        } label: {
```

```swift
    private func exportForSocial() {
        appState.socialExportRequest = SocialExportRequest(urls: driveShareURLs)
    }
```

Reuses `driveShareURLs` (the already-shipped, already-raster-filtered property) — the
"visible set — matches what the user sees, the collapsed-stacks export rule" behavior
comes free.

- [ ] **Step 4: Build and manually verify**

Confirm all three entry points open the card with the correct URL set; confirm each is
`.disabled` (not absent — matching "Share Drive Link"'s existing disabled-not-hidden
pattern at this exact menu) when the selection/file has no raster kind.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Views/SelectionMenu.swift" "Muse/Muse/Views/Viewer/ShareButton.swift" \
  "Muse/Muse/Views/ShareCollectionButton.swift"
git commit -m "feat(social-export): three entry points (grid menu, hero viewer, collection header)"
```

### Task 4.9: "Save Crop as Version" — absent-not-disabled Spec 04 seam

**Files:**
- Modify: `Muse/Muse/Views/Export/SocialExportCard.swift`

**Interfaces:**
- Consumes (once Spec 04 exists — NOT in this tree today):
  `EditStore.saveVersion(name: String, kind: String, stack: EditStack, for: URL)`,
  `SocialCropMath.composedCrop` (Task 4.2, already built).

Per the soft/severable dependency noted at the top of this plan: Spec 04 does not exist
in this tree, so this button is **absent, not disabled** — no `#if canImport`/feature
flag is needed since the type `EditStore` simply doesn't exist to reference yet. This
task documents the EXACT call this button will make once Spec 04 lands, so a future
session wires it mechanically rather than re-deriving the shape.

- [ ] **Step 1: Add a doc comment at the intended mount point in `SocialExportCard`**

In the `stage` view, below `SocialCropStageView`, add (as a comment, not live code —
the type doesn't exist to compile against):

```swift
            // Spec 04 seam (absent until EditStore/EditStack exist — house rule:
            // absent, not disabled). Once Spec 04 lands, mount here, gated on
            // (model.fit == .crop && case .fixed = model.preset.kind && the
            // current file's AssetKind is .image or .raw — NOT .psd, matching
            // Spec 04's Path-A editable-kinds rule):
            //
            //     if let url = model.currentURL, model.fit == .crop, isFixedPreset {
            //         ModalButton(title: String(localized: "Save Crop as Version"),
            //                     kind: .normal) {
            //             let state = model.state(for: url)
            //             let socialRect = SocialCropMath.rect(
            //                 sourceSize: state.decodedSize ?? .zero,
            //                 targetAspect: targetAspect(for: model.preset),
            //                 zoom: state.zoom, center: state.center)
            //             let existingCrop = EditStackIndex... /* current stack's GeometryParams.crop */
            //             let composed = SocialCropMath.composedCrop(existing: existingCrop, social: socialRect)
            //             var stack = /* current EditStack for url, or .init() */
            //             stack.adjustments... /* set .geometry(GeometryParams(crop: composed, ...)) */
            //             EditStore.shared.saveVersion(name: model.preset.nameKey, kind: "version",
            //                                          stack: stack, for: url)
            //         }
            //     }
```

- [ ] **Step 2: No test — no code exists to test.** This task is documentation-only
  until Spec 04 ships; a future spec-04-dependent plan (or a follow-up to THIS plan,
  once Spec 04 lands) implements the commented block above for real, with its own TDD
  cycle against `EditStore.saveVersion`'s real signature at that time.

- [ ] **Step 3: Commit**

```bash
git add "Muse/Muse/Views/Export/SocialExportCard.swift"
git commit -m "docs(social-export): document the Save-Crop-as-Version Spec 04 seam (absent until then)"
```

### Task 4.10: Localization export pass

**Files:**
- Modify: `Muse/Muse/Localizable.xcstrings`

- [ ] **Step 1: Grep for un-wrapped literals in new social-export and share files**

Run: `grep -rn '"[A-Z][a-z].*"' Muse/Muse/Views/Export/ Muse/Muse/Export/Social/ \
  Muse/Muse/Views/DriveShareForm.swift Muse/Muse/Views/ShareCollectionButton.swift \
  Muse/Muse/Views/ManageDriveSharesView.swift | grep -v 'String(localized:'`
and manually confirm every match is either a SwiftUI text-literal position
(auto-extracted: `Text("…")`, `Button("…")`, `Label`, `Picker` titles, `Section`
headers, `.accessibilityLabel`) or already wrapped in `String(localized:)`. Fix any
bare `String` params found — in particular, `SocialPreset.nameKey`/`.warningKey` are
plain `String` model properties (correctly NOT wrapped at declaration, since they're
data, not display text) — confirm every RENDER site of them wraps with
`String(localized: String.LocalizationValue(...))` (as written throughout Task 4.7)
rather than displaying the raw English key.

- [ ] **Step 2: Run the export**

```bash
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj -localizationPath /tmp/muse-l10n-social -exportLanguage fr
```

- [ ] **Step 3: Fill in the empty `fr` values** for every new key introduced by this
  plan — preset display names (INCLUDING the brand names "Threads"/"X"/"Glass"/
  "Facebook"/"Pinterest"/"Flickr / 500px", translation = identity per house rule),
  preset warning strings, card copy ("Preset"/"Include camera info (EXIF)"/"Include
  location"/"Export…"/etc.), layout picker labels ("Grid"/"Contact Sheet"/"Essay"),
  the signed-out explainer's four sentences, the unverified-app note, the Settings
  caption row, "Portfolio"/"Never" (Manage badges), "Publish Portfolio…"/"Update
  Portfolio…"/"Copy Portfolio Link", the two new `PublishError` messages, and the
  sweep-warning `.doneWithSweepWarning` copy (if that branch was chosen in Task 3.6).

- [ ] **Step 4: Re-run the export to confirm 0 untranslated**

```bash
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj -localizationPath /tmp/muse-l10n-social-verify -exportLanguage fr
```

Grep the output `.xliff` for any remaining empty `<target>` elements among the new
keys. Expected: 0.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Localizable.xcstrings"
git commit -m "docs(i18n): French translations for Spec 07's new strings"
```

---

## Phase 5 — Close-out

### Task 5.1: `CLAUDE.md` durable constraints + Implementation status row

**Files:**
- Modify: `/Users/carlostarrats/Documents/Projects/Muse/Muse App/CLAUDE.md`
- Modify: `docs/architecture-map.md` (new module folders)
- Modify: `docs/session-log.md` (narrative entry)
- Modify: `docs/new-build/DECISIONS.md` (mark Spec 07 as implemented, if that file
  tracks build status — confirm its convention first; it may only track decisions, not
  status, in which case skip this file)

- [ ] **Step 1: Add the 8 durable constraints from spec-07-implementation.md §7** into
  `CLAUDE.md`'s "Durable constraints & gotchas" section, condensed to the house
  terse one-two-line style (not the spec's fuller prose):

  - The share page makes exactly ONE kind of network fetch — the portfolio
    `manifest.json` GET, `connect-src`-pinned, quota-only + referrer-restricted API
    key, bounded read, re-validated, `m`-stripped (never chained), inline-snapshot
    fallback always present. Not a secret; a real secret/OAuth credential on the page
    stays forbidden.
  - `e` stays required for non-portfolio manifests (fail-open guard); `m`-present
    manifests never expire and never consult `e`.
  - `uploadManifest` is the only non-image Drive upload and must stay JSON-typed and
    narrowly named — image bytes reach Drive exclusively through `uploadFile`'s
    strip-verified path.
  - Portfolio records use the `neverExpires` sentinel, not an optional expiry.
  - Portfolio update order is upload-new → swap manifest → delete-old — the manifest
    `files.update` is the atomic cutover.
  - Social export renders through `OutputRender.forOutput` first, never upscales,
    bakes orientation at decode, and default-metadata outputs must pass
    `ImageMetadataStripper.isClean` before writing. The X preset's five invariants are
    test-pinned — don't trade them for quality.
  - Nothing in the social export card persists unless the user explicitly saves a
    version. Remembered bits: last preset-family EXIF choices, matte shade, share
    layout.
  - Manifest v2 keys are optional-only — a manifest without new features encodes with
    none of the new keys, and legacy fragments decode forever.

- [ ] **Step 2: Add the Implementation Status table row**

`| Polish 29 — Share page expansion (layouts, portfolio, social export presets, Google on-ramp) | ✅ shipped | <branch name> |`

- [ ] **Step 3: Update `docs/architecture-map.md`** with the new module folders:
  `Export/Social/` (preset table, render pipeline, metadata policy), `Views/Export/`
  (the social export card), `Commerce/` (the `SharingTier` seam — note it's a stub
  awaiting Spec 01's full `CommerceStore`).

- [ ] **Step 4: Add the session-log entry** — date, branch, one paragraph per phase
  (layout options, Google on-ramp, portfolio mode, social export), matching the
  existing entries' voice; explicitly note Deviations D1–D8 and the Phase-0 scoping
  decision (OutputRender built without the four shipped call-site conversions).

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/architecture-map.md docs/session-log.md
git commit -m "docs: Spec 07 share expansion — durable constraints, phase table, architecture map"
```

### Task 5.2: Full regression pass + final French localization confirmation

**Files:** none (verification-only task).

- [ ] **Step 1: Run the full Swift test suite**

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test
```

Expected: PASS (green), matching the "keep it green" house rule — every test from
Phases 0–4 plus every pre-existing test in the suite.

- [ ] **Step 2: Run the full Node test suite**

```bash
node --test web/share/share.test.mjs
```

Expected: PASS — every pre-existing test (legacy decode, bomb cap, sanitize, id
charset) plus every Phase 1/3 addition.

- [ ] **Step 3: Confirm 0 untranslated across the whole plan's new keys**

```bash
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj -localizationPath /tmp/muse-l10n-final -exportLanguage fr
```

Expected: 0 untranslated among every key introduced across Tasks 1.1–4.10 (Task 4.10
already covers most; this is the whole-plan final sweep in case a later task's commit
introduced a literal Task 4.10 didn't catch).

- [ ] **Step 4: `stat` the built `.app`'s executable mtime**

Confirm the binary handed to the owner for a final look-pass is freshly built, per the
house rule (`BUILD SUCCEEDED` is not proof of a working build).

- [ ] **Step 5: `git status` review before the final commit**

Confirm no stray fixture/scratch files (beyond the intentional `Fixtures/Social/*.jpg`
checked-in fixtures), no accidental credentials (in particular: confirm
`DRIVE_API_KEY` in `share.js` is still the placeholder `'REPLACE_AT_DEPLOY'` in the
committed source — the real key is pasted only at deploy time per Task 3.9, never
committed), and that the diff matches exactly the files touched across every task in
this plan plus Task 5.1's doc edits.

- [ ] **Step 6: Commit** (only if Step 5 found anything to fix; otherwise this task
  produces no commit of its own — it's a verification gate over Tasks 0.1–5.1's
  already-committed work)

### Task 5.3: Owner look-pass + remaining owner-only steps checklist

**Files:** none (operational).

- [ ] **Step 1:** Confirm all owner-only steps from spec-07-implementation.md §10 are
  either done or explicitly deferred with a reason:
  - Browser API key created + pasted (Task 3.9) — done or deferred.
  - Pages deployed twice (Task 1.6, Task 3.9) — done or deferred.
  - X no-recompress manual byte-compare protocol (export via X preset → post on x.com
    → download `?name=orig` → `cmp` against the exported file) — run once, record
    date + result in the session log. NOT verifiable by unit test (`XPresetRuleTests`
    pins the five INVARIANTS; this step verifies X's SERVER behavior, which is
    outside the app's control).
  - Preset table validated against current platform docs at ship time (IG/Threads/X/
    FB/Pinterest/Flickr/Glass specs drift) — the table is test-pinned, so any future
    change is a deliberate constant edit against `SocialPresetTests`.
  - `DriveConfig.consentScreenVerified` flipped when Google verification completes —
    deferred until that review completes; harmless to ship `false`.
  - `SharingTier.enforced` flip — deferred to Spec 09's pricing decision.
  - Visual look-pass on the three share-page layouts (Task 1.3 Step 4, already run)
    and the crop card (Task 4.7 Step 5, already run) — confirm both are recorded in
    the session log with a date.

---

## Self-Review

Spec-section coverage, mirroring spec-07-implementation.md's own §12 acceptance-mapping
table so a reader can audit this plan against the source spec section-by-section.

| Spec section | What it covers | Task(s) that implement it |
|---|---|---|
| §0 Dependencies | OutputRender prerequisite, soft Spec 04 dependency | "Dependencies & sequencing", Phase 0 (Tasks 0.1–0.2) |
| §1.1 Manifest v2 fields | `y`/`s`/`m` keys, `DriveShareLayout`, `jsonData()`, caps | Task 1.1 |
| §1.2 Page-side validation | `validateManifest` `y`/`s` rules, `layoutOf` | Task 1.2 (classic-only) + Task 3.3 (portfolio-aware) |
| §1.3 Rendering the three layouts | CSS `[data-layout]`, `#body` node, `SIZER_BY_LAYOUT` | Task 1.3 |
| §1.4 Choosing a layout at publish time | `DriveShareForm` fields, Layout picker, Intro field, `AppSettings.driveShareLayout` | Task 1.4 |
| §2.1 Portfolio mechanism (D5) | Drive-pointer manifest design | Task 3.5, Task 3.6 (implements the design) |
| §2.2 Portfolio manifest shape | `m`/`e:""` rules, exactly-one-fetch/no-chaining | Task 1.1 (struct), Task 3.3 (validation) |
| §2.3 Page fetch + CSP | `manifestFetchURL`, `acceptFetchedManifest`, render glue, `connect-src` | Task 3.3, Task 3.4 |
| §2.4 `DriveClient` additions | `uploadManifest`/`updateManifest`/`listChildren` | Task 3.1 |
| §2.5 `DriveShareRecord` growth | portfolio fields, `neverExpires`, `portfolio(forCollectionID:)` | Task 3.2 |
| §2.6 Publish flow | `publishPortfolio` | Task 3.5 |
| §2.7 Update flow | `updatePortfolio`, upload→swap→sweep order | Task 3.6 |
| §2.8 UI seams | `DriveShareRequest`/`DriveShareMode`, `CollectionModal`, menu items, sheet modes, Manage badges | Task 3.7 |
| §2.9 Tier seam | `Commerce/SharingTier.swift` | Task 3.8 |
| §3.1 Preset table | `SocialPreset` (12 presets) | Task 4.1 |
| §3.2 Fit modes + crop math | `SocialFit`, `MatteShade`, `SocialCropMath` | Task 4.2 |
| §3.3 Render pipeline | `SocialRender.export`, named pipeline constants | Task 4.4 |
| §3.4 X invariants | The five hard invariants | Task 4.4 (implementation) + Task 4.5 (dedicated tests) |
| §3.5 Metadata policy | `SocialMetadata`, `isClean` verify | Task 4.3, consumed in Task 4.4 |
| §3.6 The card | `SocialExportCard`, `SocialExportModel`, `socialExportRequest`, Save-Crop-as-Version seam | Task 4.6, Task 4.7, Task 4.9 |
| §3.7 Entry points | Grid menu, hero viewer, collection header | Task 4.8 |
| §3.8 Localization | French pass for all Spec 07 strings | Task 4.10, Task 5.2 Step 3 |
| §4.1 Signed-out explainer | `DriveShareSheet` explainer block | Task 2.1 |
| §4.2 Unverified-scope messaging | `DriveConfig.consentScreenVerified` | Task 2.2 (consumed by Task 2.1, Task 2.3) |
| §4.3 Settings copy | Google Drive section footer + caption | Task 2.3 |
| §5 What Spec 07 does NOT change | Every shipped Drive invariant, `AppState`/status-pill/search/analysis untouched | Global Constraints (stated up front); no task in this plan touches those areas — verified by scoping every Drive-file diff to additive changes only |
| §6 Performance (recorded, never asserted) | `PerfBaseline` rows | Not built as a separate task — this plan does not add `Perf/PerfBaseline.swift` rows since that infrastructure doesn't exist in this tree (Spec 01 not shipped); Tasks 1.3 Step 4, 3.4 Step 4, 4.7 Step 5, 5.3 Step 1 instead record the seven §6 rows as MANUAL verification notes in the session log, matching how spec-04's own plan handled the same gap (its Self-Review notes make the identical call) |
| §7 New durable constraints | The 8 constraints | Task 5.1 |
| §8 Tests | Every named test file/case | Distributed: `DriveShareManifestTests` (Task 1.1), Node tests (Task 1.2, 3.3), `DriveShareStoreTests` (Task 3.2), `DriveMultipartTests` (Task 3.1), `SocialPresetTests` (Task 4.1), `SocialCropMathTests` (Task 4.2), `SocialRenderTests` (Task 4.4), `SocialMetadataTests` (Task 4.3), `XPresetRuleTests` (Task 4.5), `SharingTierTests` (Task 3.8) |
| §9 Build order | Layout options → Google on-ramp → Portfolio → Social export | This plan's Phase 1 → Phase 2 → Phase 3 → Phase 4 structure, verbatim |
| §10 Owner-only steps | API key, deploys, X protocol, table validation, flags | Task 1.6, Task 3.9, Task 5.3 |
| §11 Deviations (D1–D8) | Recorded deliberately | D1/D3 at Task 3.3/3.4; D2 at Task 4.6; D4 at Task 3.2; D5 at "Dependencies & sequencing" + Task 3.5/3.6; D6 at Global Constraints + Task 4.7; D7 at Task 4.4 (never-upscale); D8 at Task 1.5 |
| §12 Acceptance mapping | Every pre-spec acceptance line | Traceable via this table's rows above — each spec-07-implementation.md §12 row's "where satisfied" column maps 1:1 to the plan-section row here |

**Placeholder scan:** every task carries concrete signatures, real (compilable, though
unverified-by-live-build) Swift/JS code, and named files. The few spots that
intentionally defer a literal value pending a live run: Task 4.4 Step 4's note about
adjusting rounding if a dims assertion is off by a pixel (a standard TDD "run once, fix
the real code, never loosen the test" instruction, not a vague placeholder); Task 4.5's
`noise-4096x4096.jpg` fixture production (an explicit "generate via a one-off script"
step, not hand-waved); Task 4.7's `SocialCropStageView` gesture-handling body, which is
scoped explicitly as "its own follow-up TDD sub-step" per the house no-UI-unit-tests
rule (the same treatment spec-04's plan gives its own UI-gesture-heavy views, e.g.
`EditSlider`). Task 4.9 is DELIBERATELY comment-only (not a placeholder — a documented,
correctly-scoped absence, per the house absent-not-disabled rule for an unshipped
dependency). No task contains "TBD," "handle appropriately," or "similar to Task N"
left unexpanded.

**Type consistency check:** `DriveShareManifest` (layout/bodyText/manifestID + 
`DriveShareLayout`, introduced Task 1.1) is referenced identically in Task 1.4
(`DriveShareForm` mapping), Task 3.3 (`share.js`'s wire-format mirror), Task 3.5/3.6
(manifest construction). `DriveShareRecord` (portfolio fields + `neverExpires`,
introduced Task 3.2) is referenced identically in Task 3.5/3.6 (record construction/
mutation) and Task 3.7 (Manage badges, menu lookup). `DriveShareRequest`/
`DriveShareMode` (introduced Task 3.7) supersede the shipped `.driveShare(title:urls:)`
payload consistently across ALL SIX call sites touched in that same task (never left
half-migrated). `SocialPreset`/`SocialFit`/`MatteShade` (Task 4.1/4.2) are consumed
identically by `SocialRender.Job` (Task 4.4), `SocialExportModel` (Task 4.7), and the
three entry points (Task 4.8) — no divergent re-declaration anywhere. `SocialRender.Job`/
`.Result` (Task 4.4) match exactly between their own test file and `SocialExportModel
.export`'s construction (Task 4.7). `OutputRender.forOutput`/`RenderedOutput` (Phase 0)
match Spec 01's own plan verbatim (cross-checked directly against
`2026-07-30-spec-01-foundation-plumbing.md` Task 16's code, not paraphrased), so a
future Spec 01 build will find this plan's Phase 0 work either already-satisfied
(skippable) or byte-identical to merge cleanly — this was the explicit point of
building it "to spec-01's exact text." Every `AppSettings` key introduced
(`driveShareLayout`, `socialExifChoices`, `socialMatteShade`) follows the exact
existing `driveShareLabel`/`driveShareName` getter/setter pattern (verified against the
real current file, not assumed).

**Known soft spots, flagged rather than hidden:** (1) Task 3.6's `sweepFailed` warning
surfacing offers two implementation options (a weak `AppState` reference vs. a new
`Phase` case) with an explicit recommendation and reasoning — an implementer must pick
one, not both; the plan states which is preferred and why. (2) Task 4.4's
`ThumbnailCache.withinDecodeBudget` call site is flagged as needing a live signature
check before compiling (the research pass didn't independently verify this one
function, only the ones explicitly requested) — resolved by one `grep` at
implementation time, not a design uncertainty. (3) Task 4.7's `cropRect`
`sourceSize`/`decodedSize` threading is called out explicitly as a real wiring detail
that must not be left as the placeholder `.zero` shown in the first code draft — the
step's prose says so directly rather than shipping the placeholder silently. (4) Task
4.8's raster-kind filter for `SelectionMenu`/`ShareButton` gives a preferred approach
(derive from `AssetKind`/`FileNode.kind`, matching `driveShareURLs`) and a fallback
(hardcoded extension list) with an explicit instruction to grep and prefer the former —
flagged because the research pass didn't verify whether `SelectionMenu.fileURLs` and
`ShareButton`'s bare `url` carry kind information alongside the raw `URL`.
