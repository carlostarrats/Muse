# iCloud sync zone + macOS share integration — design

Date: 2026-06-13
Status: approved design, pending spec review → implementation plan

## Summary

Three related additions that make Muse easier to feed and lay the
groundwork for an eventual iOS companion app, **without giving up Muse's
zero-network, "Data Not Collected" identity**:

1. **A two-zone storage model.** Today every folder is a user-selected,
   device-local, security-scoped bookmark ("local zone"). We add a second,
   first-class **iCloud zone**: an app-owned iCloud Drive container whose
   contents sync across all of the user's devices via the OS sync daemon.
2. **Complete portable sidecar metadata.** Files in the iCloud folder carry
   their analysis (tags, intent, OCR-derived caption, color, dimensions,
   feature print) in a hidden `.muse/` sidecar that rides the same iCloud
   sync. Any device — including a fresh install or an eventual iOS app —
   reconstructs the full experience from the folder alone.
3. **macOS share integrations.** (a) An in-app **Share button** on an image
   (`NSSharingServicePicker`) for sending an image *out* (AirDrop, Mail,
   Messages, Save to Files). (b) A **"Send to Muse" share extension** so you
   can right-click a file anywhere (Finder, desktop, other apps) and drop it
   *into* the Muse iCloud folder.

## Goals

- A user can run Muse **local-only**, **iCloud-only**, or **mixed** — none
  is privileged. The iCloud-only user is fully supported with no local
  fallback.
- Save something on one device → it appears, fully analyzed, on another.
  (Cross-Mac today; iOS when that app exists.)
- The app makes **zero network calls** and the developer receives **no
  data**. Privacy label stays "Data Not Collected."
- Share an image out of Muse via the standard macOS share sheet.
- Send a file *into* Muse's iCloud inbox from anywhere via right-click.

## Non-goals

- **No CloudKit.** CloudKit means the app talks to Apple's servers over the
  network, which requires `network.client` and breaks the sandbox stance.
  We use iCloud Drive *document* sync, which is OS-mediated and needs no
  network entitlement.
- **No developer server, no analytics, no telemetry.** Unchanged.
- **The iOS app itself is out of scope here.** This design only builds the
  Mac-side foundation and verifies the iOS app can later plug in.
- **No live SQLite file in iCloud.** Syncing a mutating SQLite db via
  iCloud Drive is a known corruption trap. The sidecar is a snapshot, not
  the database.
- **No syncing of thumbnails or collections.** Both re-derive locally.

## Identity / privacy reconciliation

This is the load-bearing constraint, so it's stated explicitly.

| Mechanism | App makes network calls? | Entitlement added | Dev receives data? | Privacy label |
|---|---|---|---|---|
| iCloud **Drive** document sync (chosen) | No — `bird`/`cloudd` sync out-of-process | iCloud Documents (`com.apple.developer.icloud-*`, ubiquity container) | No | "Data Not Collected" holds |
| CloudKit (rejected) | Yes — app↔Apple servers | iCloud + network | No, but network surface exists | Would need review; breaks sandbox stance |

The **one** change to the current entitlement set is adding the iCloud
Documents / ubiquity-container capability. `com.apple.security.network.client`
is **not** added. The existing `Muse.entitlements`
(sandbox + user-selected read-write + app-scope bookmarks) gains the iCloud
container keys and an App Group (shared with the share extension); nothing
else. The app's data flow is still pure file I/O — iCloud sync happens in
Apple's daemon, in the user's own iCloud account, never touching a Muse
server (there is none).

CLAUDE.md's network policy section will be updated to record this nuance:
"Zero network *calls from the app*. iCloud Drive document sync is OS-mediated
and adds no `network.client` entitlement."

## The two-zone model

```
Muse roots
├── Local zone   (today's behavior, unchanged)
│   • user-selected folders, security-scoped bookmarks (Root.swift / BookmarkStore)
│   • device-local, never synced, no sidecar written
│
└── iCloud zone  (new) — exactly ONE app-managed folder
    • a single "Muse" folder in the app's iCloud Drive ubiquity container
    • auto-discovered on every signed-in device — NOT re-picked per device
    • the user may create their own subfolders inside it (their organization)
    • a hidden .muse/ sidecar directory carries metadata; it travels too
    • "Send to Muse" drops files directly into this one folder
```

Key properties:

- **Local zone is exactly today.** No behavior change for the privacy-purist
  user who never enables iCloud.
- **Exactly one app folder.** Muse owns a single top-level "Muse" folder in
  iCloud — not a set of managed folders. Anything the *user* puts inside it
  (files, their own subfolders) is theirs to organize; Muse just indexes it.
- **iCloud folder is auto-discovered**, not bookmarked. It is reached via
  `FileManager.url(forUbiquityContainerIdentifier:)`. Because it's the app's
  own container, the Mac app and the eventual iOS app both see the same
  contents automatically — the user does not re-add it on each device. This
  is the crucial difference from local folders.
- **iCloud-only is first-class.** A user may add nothing to the local zone.
  Everything (files + complete sidecars) lives in the one Muse folder and
  travels.

### Hydration (the hard requirement)

For a local-zone file, the on-device SQLite index is the source of truth and
any export is a convenience. For an **iCloud-only user on a fresh device
there is no local fallback** — the only thing that traveled is the files plus
their `.muse/` sidecars. Therefore:

> **The sidecar must be a *complete* portable record.** A fresh device must
> reconstruct the entire per-file experience from the container alone, then
> re-derive collections and regenerate thumbnails locally.

On opening an iCloud folder, Muse:
1. Enumerates files (existing indexer path; already iCloud-aware —
   `Indexer.isUbiquitous`, dataless-file handling, the size/mtime
   oscillation fix all apply).
2. For each file, if a `.muse/<content_hash>.json` sidecar exists and is
   newer/equal, **import it into the local SQLite** instead of running
   Vision. Caption, tags, color, palette, dimensions, intent, feature print
   are hydrated directly.
3. Only files with **no sidecar or a stale one** go through the normal
   `AnalyzePipeline`; after analysis, Muse **writes the sidecar back**.
4. Collections re-derive via `CollectionsEngine` from the hydrated per-file
   data. Thumbnails regenerate via `ThumbnailCache.prewarmToDisk`.

This means an iCloud-only library never re-runs Vision on a second device —
a big win for an eventual iOS app where Vision is slow and battery-hungry.

## Sidecar format

- **Location:** a hidden `.muse/` directory **inside the Muse iCloud folder**
  (and any user subfolders within it). iCloud Drive syncs dot-directories, so
  it travels with the files.
- **Granularity:** **one JSON file per asset, keyed by content hash** —
  `.muse/<content_hash>.json`. Rationale:
  - **Conflict isolation** — with two devices editing, iCloud creates
    conflict copies per file; a tag edit on image A can't collide with the
    whole folder's metadata. A single per-folder file would conflict on
    every concurrent edit.
  - **Rename/move resilience** — keyed by content hash, not path, so moving
    or renaming the image doesn't orphan its metadata.
  - **Granular sync** — only changed sidecars re-sync.
  - Cost: many small files. Acceptable; hidden from the user in `.muse/`.
- **Written with file coordination** (`NSFileCoordinator`) to play nicely
  with the sync daemon. Never a live SQLite handle.

### What travels (portable, from `FileRow` + `TagRow`)

```jsonc
{
  "schema": 1,
  "content_hash": "…",          // identity key
  "kind": "image",
  "width": 1920, "height": 1080,
  "duration_seconds": null,
  "created_at": 0, "modified_at": 0,
  "caption": "…",               // Vision-derived, not LLM
  "dominant_color": "#RRGGBB",
  "palette": "…",
  "feature_print": "<base64>",  // for on-device similarity
  "analyzed_hash": "…",         // so the importing device knows it's current
  "intent": "recipe",           // screenshot intent bucket | null
  "intent_model_version": "…",
  "tags": [
    { "label": "dog", "source": "vision", "confidence": 0.9, "model_version": "…" },
    { "label": "favorite", "source": "manual" }
  ]
}
```

### What does NOT travel (device-local / re-derived)

- **Path bookmarks** (`PathRow.bookmark_data`) — device- and path-specific,
  meaningless on another device.
- **`last_seen_at`** — device-local liveness.
- **Thumbnails** — regenerated by `ThumbnailCache`.
- **Collections / collection members** — re-derived by `CollectionsEngine`
  from per-file tags + intent. Avoids the "collection spans an iCloud folder
  *and* a local folder" merge problem entirely.
- **Duplicate groups** — re-derived on demand.
- **FTS5 index** — rebuilt locally from imported captions/tags.
- **Embeddings** (`EmbeddingRow`) — re-derivable; optional future inclusion
  if recompute proves expensive, but excluded from v1 to keep the sidecar
  light.

### Conflict handling

- Per-file sidecars + content-hash keys isolate most conflicts.
- On an iCloud conflict copy, resolve **last-writer-wins per file** using the
  sidecar's own modified timestamp, with one exception preserving the
  existing invariant: **manual tags beat vision tags** (Q32) — a merge keeps
  any `source:"manual"` tag from either side.

## Feature: in-app Share button (sending OUT)

- A Share control on the hero viewer (and/or grid tile context menu) opens
  `NSSharingServicePicker` for the selected file's URL.
- Standard macOS targets: AirDrop, **Mail**, Messages, Save to Files, etc.
  The OS owns the transfer; no entitlement, no network surface for the app.
- Read-only on the original file. No new viewer or editing path.
- This is the "share an image to someone" direction — distinct from
  "Send to Muse" below, which brings files *in*.

## Feature: "Send to Muse" share extension (bringing IN)

- A new **Share Extension** app-extension target ("Send to Muse") that
  appears in the system share sheet and in **Finder right-click → Share**.
- It copies the dropped file(s) directly into the **single Muse iCloud
  folder** (top level). No sub-inbox — the one folder *is* the destination.
- Extension ↔ main app share an **App Group** and the iCloud container so the
  extension can write into it. The main app's `FolderWatcher` (FSEvents) sees
  the new file, indexes it, analyzes it, and writes the sidecar — the normal
  pipeline, no special-casing.
- **Requires the Muse iCloud folder to exist** (created when the user enables
  iCloud). A purely local-only user who never enables iCloud simply doesn't
  use this extension; we do not invent a parallel local drop-target.

## Scope: build now vs. later

**Build now (this plan, Mac app):**
- iCloud Documents entitlement + ubiquity container + App Group.
- Two-zone model in `AppState` / roots (local bookmarks vs. discovered
  iCloud container); sidebar surfaces the iCloud zone.
- Complete sidecar read/write integrated into `AnalyzePipeline` (write) and
  the folder-load path (read/hydrate before analyzing).
- In-app Share button.
- "Send to Muse" share extension → the single Muse iCloud folder.
- CLAUDE.md network-policy + architecture updates.

**Verified-feasible, deferred (eventual iOS app):**
- The iOS app reuses the *same* ubiquity container + sidecar format, so it
  plugs in with no schema change. This plan must not encode any Mac-only
  assumption into the sidecar (e.g. AppKit-specific color encoding) that
  would block iOS.

## Affected code (orientation, not exhaustive)

- `Muse.entitlements` — add iCloud Documents + ubiquity container + App Group.
- `Models/Root.swift`, `Filesystem/BookmarkStore.swift`, `Models/AppState.swift`
  — introduce zone concept; discover the iCloud container.
- `Indexing/Indexer.swift` — already iCloud-aware; add sidecar-hydrate
  short-circuit before analysis.
- `Intelligence/AnalyzePipeline.swift` — write sidecar after analyzing an
  iCloud-zone file.
- New `Filesystem/SidecarStore.swift` — read/write/merge `.muse/*.json` with
  `NSFileCoordinator`.
- `Intelligence/Collections/CollectionsEngine.swift`,
  `Filesystem/ThumbnailCache.swift` — unchanged logic; they already re-derive
  from per-file data.
- `Views/Viewer/…` and/or `Views/GridView.swift` — Share button.
- New **share-extension target** — "Save to Muse".

## Testing considerations

- **Sidecar round-trip:** analyze → write sidecar → wipe local SQLite →
  hydrate from sidecar → assert FileRow + tags + intent identical.
- **iCloud-only cold start:** simulate a container with files + sidecars and
  no local db; assert full hydration without invoking Vision.
- **Conflict merge:** two sidecars for one hash; assert last-writer-wins with
  manual-tag preservation.
- **Local-only unaffected:** a local-zone folder writes no sidecar and
  behaves exactly as today.
- **Dataless iCloud files:** not-downloaded items are skipped, never
  empty-hashed (existing invariant).
- Existing suite stays green.

## Open decisions (resolved)

- **Sidecar granularity:** per-asset, content-hash-keyed (decided above).
- **CloudKit vs iCloud Drive:** iCloud Drive document sync (decided).
- **Collections sync:** no — re-derive (decided).
- **iCloud surface:** exactly one app-managed "Muse" folder; the user may
  create their own subfolders inside it. No multiple managed folders, no
  separate "inbox" subfolder (decided).
- **"Send to Muse" destination:** the single Muse iCloud folder, top level.
  Requires iCloud enabled; no parallel local drop-target (decided).

## Open questions (for spec review)

- None outstanding.
