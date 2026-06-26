# iCloud Collection Share — design

**Date:** 2026-06-25
**Status:** approved, pending implementation
**Branch (planned):** `feat/icloud-collection-share`

## Context

A new "share a collection" capability. The full vision (from the
`Desktop/Martin` thread — owner ↔ client Martin Bruneau) is **two
independent share backends**:

1. **iCloud (this spec)** — a plain, no-infra helper: copy a collection
   into iCloud and hand the user Apple's native share link. **No web
   page, no branding, no form, no auto-expiry.**
2. **Google Drive (future spec)** — the automated, branded web-page
   experience: sign in once, Publish auto-creates a Drive folder, uploads,
   renders a hosted branded gallery (single static query-param page),
   auto-expires + auto-deletes, plus a print-ready PDF. This is the
   "magic" path and Martin's actual need; it is **out of scope here**.

**Build order (owner decision):** iCloud helper first. It is small,
needs no Google OAuth app, no hosting, no backend, and gets a working
share path live fast. Drive follows in its own spec → plan → branch.

### Why iCloud can't be the "magic" path (settled)

Apple exposes **no API to programmatically mint a viewable public iCloud
gallery link**. The only code-level API, `url(forPublishingUbiquitousItemAt:
expiration:)`, returns a *download-a-copy* link for a single flat file with
a system-set expiry and a flaky track record — not a gallery, not a folder.
So the nice viewable link still requires **one manual `Share → Copy Link`
click by the user**. That manual click is acceptable here precisely because
the iCloud helper makes no automation promise; the zero-touch automated
flow is the Drive feature, which has an API.

## What we're building

A per-collection **"Share to iCloud…"** action that:
- consolidates the collection's images into one iCloud Drive folder Muse
  owns, then
- presents the native macOS share sheet so the user copies Apple's link,
and a global **"Manage iCloud Shares…"** command (macOS **File menu**, next
to "Find Duplicates in Folder") that lists past shares and can delete a
folder to reclaim iCloud space.

## Architecture

### Destination folder

Muse already ships the iCloud ubiquity container
`iCloud.com.tarrats.Muse` with `NSUbiquitousContainerIsDocumentScopePublic
= true` (Info.plist), so the container already surfaces as a **"Muse"
folder in the user's iCloud Drive**. Share folders live in a dedicated
subtree so they never mix with the existing sync sidecars:

```
iCloud Drive / Muse / Shared Collections / <sanitized collection name> /
```

Resolve the container base via
`FileManager.default.url(forUbiquityContainerIdentifier:)` →
`Documents/Shared Collections/<name>/`. Writing to the app's **own**
ubiquity container needs no user-selection (the sandbox allows it under
the existing iCloud entitlement).

- **Name collisions / re-share:** a second share of the same collection
  **reuses and refreshes** its existing folder (clear + re-copy current
  members) rather than creating a duplicate.
- **All members copied:** even images already in iCloud elsewhere are
  copied into this one folder — a single link can only point at one folder.

### Copy + upload + share pipeline

A new `@MainActor` coordinator (`ICloudShareService`) drives:

1. **Resolve members** — collection's alive member paths via
   `CollectionStore.alivePaths(...)`, filtered to file (non-folder) image
   URLs (reuse the `ShareCollectionButton.exportURLs` filtering rule).
2. **Copy** into the destination folder. Collections only contain real,
   reachable images (Muse's reachability-aware membership reconciles out
   moved/deleted files), so "missing files" is not a real case at share
   time — copy all members. The one edge is a member whose **source** is
   an un-downloaded iCloud placeholder (dataless): **download-then-copy**
   it (we're moving it into iCloud regardless, so the download is
   intended). This force-download applies **only** to the share's own
   members, never to unrelated files.
3. **Wait for upload** — watch ubiquity upload status with `NSMetadataQuery`
   (`NSMetadataUbiquitousItemPercentUploadedKey` /
   `…IsUploadedKey`) until every copied item reports uploaded. The public
   link does not work until upload completes. Surface a **progress sheet**
   during copy+upload.
4. **Present share sheet** — `NSSharingServicePicker(items: [folderURL])`
   anchored to the originating control; the user picks **Copy Link**
   (or AirDrop/Mail). Muse does not attempt to capture the link back.

### Shared-share record + management

Each completed share is recorded locally (collection name, folder path,
item count, created date). Storage: a small JSON file in Application
Support (e.g. `iCloudShares.json`) — **not** the iCloud container, **not**
SQLite-in-iCloud (corruption trap, per durable constraints).

- **"Manage iCloud Shares…"** opens a sheet listing records.
- **Delete** removes the iCloud folder (frees the space) and drops the
  record. Deletion uses `FileManager.removeItem` on the ubiquity folder;
  the OS sync daemon propagates the removal.
- The list is reachable **only** from the **File menu** command — no
  in-app navigation/sidebar/toolbar entry (owner decision).

## UI surfaces

- **Per-collection action:** extend `ShareCollectionButton` (in
  `ActiveCollectionHeader`, `Views/CollectionsRow.swift`). Its menu gains
  **"Share to iCloud…"** beside the existing Save-PDF / Share-PDF items.
- **Progress sheet:** modal over the collection while copy+upload runs;
  shows count uploaded / total and a cancel.
- **Manage sheet:** plain list (name · count · date · Delete), opened from
  the File-menu command. Presented via a window/sheet hook on the main
  scene.
- **Menu command:** `CommandGroup(after: .newItem)` in `MuseApp.swift`,
  adjacent to "Find Duplicates in Folder" → `Button("Manage iCloud
  Shares…")`.

## Components & isolation

| Unit | Responsibility | Testable as |
|---|---|---|
| `ICloudSharePaths` | sanitize collection name → folder URL; collision/reuse resolution | pure unit |
| `ICloudShareRecord` + `ICloudShareStore` | JSON-backed list of past shares (load/add/remove) | pure unit (temp dir) |
| `UploadStatusTracker` | NSMetadataQuery → "all uploaded?" state machine | logic unit (inputs mocked) |
| `ICloudShareService` | orchestrates resolve→copy→wait→present | integration only |
| `ManageICloudSharesView` / progress sheet | SwiftUI surfaces | not unit-tested (per repo convention) |

Pure units (`ICloudSharePaths`, `ICloudShareStore`, name sanitization,
member filtering, upload-status reducer) get `MuseTests` coverage. The
iCloud write, metadata-query wait, and share sheet are integration-only.

## Error handling

- **Not signed into iCloud / iCloud Drive off:** ubiquity URL is nil →
  show a clear message ("Sign in to iCloud and enable iCloud Drive to
  share to iCloud"), abort cleanly. Localized.
- **Dataless source member:** download-then-copy (see pipeline step 2);
  no partial-share state — collections don't carry missing/broken members.
- **Upload stalls:** progress sheet stays cancelable; cancel leaves the
  (partial) folder — surfaced in Manage so the user can delete it.
- **Copy failure (space/permission):** abort with a localized message;
  clean up the partial folder.

## Testing & verification constraints

- **Debug builds strip the three iCloud keys** (`Muse-Debug.entitlements`
  = production minus iCloud, the data-loss-safety gotcha). So the iCloud
  write + share path **cannot be exercised in a Debug build**. Unit tests
  cover the pure logic; the end-to-end copy→upload→share is verified
  manually in a **release-signed build**.
- Verify early on a signed build that **public-link sharing works on an
  app-container item** (expected: yes, standard iCloud Drive mechanism).
  Fallback if it ever doesn't: a one-time user-picked iCloud Drive folder
  via security-scoped bookmark. Do not build the fallback preemptively.
- iCloud container is data-loss-sensitive: only ever write under
  `Documents/Shared Collections/`; never touch the sync sidecar zone.

## Localization

Every new user-facing string is localized (the app ships French). Wrap
literals in `String(localized:)`; menu/`Button`/`Text` titles auto-extract;
hand-wrap AppKit setters and any dynamic strings (`NSSharingServicePicker`
has no user text, but the progress/manage/error copy does). Run
`-exportLocalizations` and fill `fr` before the feature is "done."

## Out of scope (explicitly)

- Branded web page, the name/message form, the hosted single-page app.
- Auto-expiry (soft page expiry) and auto-deletion on a timer.
- Print-ready PDF bundled with the share (existing PDF export is untouched).
- Google Drive, OAuth, any network egress. **The iCloud helper adds no
  network code** — it writes local files into the ubiquity container and
  lets the OS sync daemon + the native share sheet do the rest. Muse's
  "only network path is Sparkle" promise is unchanged by this feature.

## Open questions

None. (Drive feature's design — OAuth scope, hosting, expiry mechanics,
PDF placement — is deferred to its own spec.)
