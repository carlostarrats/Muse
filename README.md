# Muse

**A filesystem-native file viewer and AI-organized library for macOS.**

[![Download Muse for macOS](https://img.shields.io/badge/Download-Muse%20for%20macOS-111111?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/carlostarrats/Muse/releases/latest/download/Muse-1.4.dmg)
[![Visit the website](https://img.shields.io/badge/Website-muse--site--phi.vercel.app-f2f2f2?style=for-the-badge)](https://muse-site-phi.vercel.app/)

Muse is a local-first way to browse, view, and organize the folders you
already have — Downloads, Documents, screenshots, an inspiration stash.
Point it at a folder and it reads your files where they live. Nothing is
imported, copied, or moved, and your files are never modified.

In the spirit of Adobe Bridge, but local-first, Apple-Intelligence-native — no subscriptions, no in-app purchases, no ads.

<img width="1359" height="948" alt="Screenshot 2026-06-15 at 11 14 32 AM" src="https://github.com/user-attachments/assets/3ecb33ff-2fe1-4875-9f72-f229c41b9e9a" />

## Download

**[Download Muse for macOS](https://github.com/carlostarrats/Muse/releases/latest/download/Muse-1.4.dmg)** — open the DMG and drag Muse to Applications.

More builds and release notes are on the [Releases page](https://github.com/carlostarrats/Muse/releases). Once installed, Muse keeps itself up to date via Sparkle (**Muse ▸ Check for Updates…**). Requires macOS 14.6+. The product website is at [muse-site-phi.vercel.app](https://muse-site-phi.vercel.app/).

## Privacy first

Everything happens on your Mac. **Muse collects nothing** — no analytics, no
telemetry, nothing about you or your files is ever sent to the developer. The
app is sandboxed and touches the network in only two places, both of which you
control:

1. **Updates** — checking for and downloading its own updates (see
   [Staying up to date](#staying-up-to-date)); you choose whether automatic
   checks are on.
2. **Sharing a collection to your own Google Drive** — only when *you* sign in
   and press Publish. The images and text go from your Mac straight to *your*
   Drive (least-privilege `drive.file` access, so Muse can only touch files it
   created); the developer still receives nothing. Uploaded images are stripped
   of EXIF/GPS/camera metadata first.

There is no other code path that touches the network. Optional iCloud Drive
sync, if you turn it on, is handled entirely by the system.

## What you can do

### Browse any folder
- Add folders from the sidebar; Muse indexes them automatically in the
  background. Pin the ones you use most.
- A fast, fluid masonry grid that keeps its jigsaw look at any size — sort
  by Date, Name, Size, Kind, Color, or Shape, and set the column count to
  taste.
- Files are read in place. Deleting always means moving to the Trash, and
  it's undoable.

### View almost anything
- Images, PDFs, video, audio, 3D models, fonts, Markdown, and code or text
  all open in their own viewer.
- Click an image for a full-screen hero view with zoom, pan, color
  swatches, and a panel of its details.
- Anything without a dedicated viewer falls back to Quick Look, and you can
  always right-click → **Open With** another app.

### Organize itself
- **On-device analysis.** After indexing, Apple's Vision framework analyzes
  new or changed images — tags, dominant colors, dimensions, and readable
  text — fully on your Mac. No button to press; already-analyzed files are
  never redone.
- **Collections** form automatically from what analysis finds, span your
  whole library, and stay alive — delete images or remove a folder and they
  shrink to match. Build your own by hand, too, and give each a custom icon
  and color.
- **Smart collections.** Define a collection by rules — rating, color, tag,
  kind, date, filename, or size, matched with All or Any — and it fills and
  updates itself live from your library, always current.
- **Smart screenshot collections.** Screenshots are grouped by what they're
  of — recipes, receipts, places, articles, quotes, code, and more.
- **Tags** you can filter by, rename, or delete globally. Your tag edits
  always win over the machine's.
- **Ratings and notes.** Star-rate any image and jot a free-text note on it,
  both filterable and searchable.
- **Search** names, tags, captions, and text found inside images — and search
  **by color**, pasting a hex value or a whole palette to find perceptually
  matching images.
- **Import keywords & ratings** (File menu) reads IPTC/XMP keywords and star
  ratings written by Lightroom, Bridge, or Capture One into your files.
- **Find Duplicates** (File menu) surfaces byte-identical files, visually
  similar images, and matching filenames to review and clear out — always
  keeping at least one copy of every group.

### Select, arrange, and manage
- **Multi-select** tiles and act in bulk — add to a collection, tag, share,
  or move — plus drag-to-move and Reveal in Finder.
- **Folder operations:** create a subfolder or rename one in place, right from
  the sidebar.
- Keyboard-navigate the grid (arrows, Page Up/Down, Space to open) and set the
  masonry column count to taste.
- **Back up and restore** your whole library — tags, ratings, notes,
  collections, and analysis — keyed by content so it survives moves.

### Share and sync
- Share an image straight from the viewer — AirDrop, Mail, Messages, or
  Save to Files.
- **Share a collection as a link.** Sign in to your own Google Drive and Muse
  uploads the collection into a tidy folder in *your* Drive, then hands you a
  link to a clean, branded gallery page. Images are stripped of EXIF/GPS/camera
  metadata first, the recipient can print the page to PDF, and you can unpublish
  any time from **Manage Drive Shares…**.
- **Share a collection as a PDF** — a paginated 11×14 layout that mirrors your
  grid, via Save to… or the Share menu.
- From Finder, right-click any file → **Share → Muse** to send it into your
  library.
- Optional **iCloud sync** keeps one folder synced across your Macs. Each
  image carries a tiny sidecar of its tags, colors, ratings, notes, and
  analysis, so a second Mac restores everything without re-analyzing.

### Make it yours
- Background moods: Light, Dark, Auto (light by day, dark at night), or a
  custom color — with a global tile backdrop to sit images on.
- Drive it from anywhere via Shortcuts, Siri, and Spotlight (App Intents) —
  and any Shortcut you build is reachable from launchers like Raycast or Alfred.

## Staying up to date

Muse is distributed directly (a Developer ID–signed, notarized build), not
through the Mac App Store, so it updates itself with
[Sparkle](https://sparkle-project.org). It checks quietly in the background
and shows nothing unless an update is available; you can also choose **Muse ▸
Check for Updates…** any time. When a new version is found you get the standard
update prompt with release notes, and you decide whether to install. Every
download is cryptographically verified (EdDSA) before it's applied, and the
feed is served over HTTPS from the project's GitHub Releases.

## Requirements

- macOS 14.6 or later (Apple Intelligence features require macOS 26+)
- Xcode 16+ to build

## Tech

- **UI:** SwiftUI, with PDFKit, AVKit, and SceneKit for the viewers
- **Intelligence:** Apple Vision (on-device) + Foundation Models, capability-gated
- **Database:** GRDB.swift (SQLite) with FTS5 full-text search
- **Updates:** [Sparkle](https://sparkle-project.org) (direct-distribution
  self-update; not used by any App Store build)
- **Storage:** `~/Library/Application Support/Muse/` (sandboxed container)

## Build

Open `Muse/Muse.xcodeproj` in Xcode 16+ and run (Cmd+R). GRDB and Sparkle are
fetched automatically via Swift Package Manager. On first launch, click **Add
Folder** in the sidebar to point Muse at any folder on disk.

## Releasing

Cutting a release (archive → notarize → sign the update → publish the
appcast to GitHub Releases) is documented step by step in
[`docs/RELEASING.md`](docs/RELEASING.md).

## License

Muse is **source-available** under the [PolyForm Shield License 1.0.0](LICENSE).
You're free to read, run, and modify the code — the one restriction is that you
may not use it to build a product that competes with Muse. The source is public
so the privacy claims above can be verified, not so a clone can be shipped.

## Acknowledgements

- Custom background color sliders are designed after
  [SwiftUI-Color-Kit](https://github.com/kieranb662/SwiftUI-Color-Kit)
  by Kieran Brown (implemented natively in Muse — no dependency).
