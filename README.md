# Muse

> **Work in progress** — actively being built. Not ready for use yet.


<img width="1382" height="1004" alt="Screenshot 2026-03-19 at 8 57 13 PM" src="https://github.com/user-attachments/assets/09e936a9-01d2-4774-8381-33ed9c3b3563" />



**A filesystem-native file viewer and AI-organized library for macOS.**

Muse is a local-first way to browse, view, and organize the folders you
already have — Downloads, Documents, screenshots, an inspiration stash.
Point it at a folder and it reads your files where they live. Nothing is
imported, copied, or moved, and your files are never modified.

In the spirit of Adobe Bridge, but local-first, Apple-Intelligence-native,
and **free forever** — no subscriptions, no in-app purchases, no ads.

## Privacy first

Everything happens on your Mac. **Muse makes zero network calls** — nothing
is uploaded, collected, or shared. The app is sandboxed and doesn't even
include the network entitlement, so there's no accidental phoning home. The
privacy label is "Data Not Collected." Optional iCloud Drive sync, if you
turn it on, is handled entirely by the system; Muse still sends nothing
anywhere.

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
  shrink to match. Build your own by hand, too.
- **Smart screenshot collections.** Screenshots are grouped by what they're
  of — recipes, receipts, places, articles, quotes, code, and more.
- **Tags** you can filter by, rename, or delete globally. Your tag edits
  always win over the machine's.
- **Search** names, tags, captions, and text found inside images.
- **Find Duplicates** (File menu) surfaces byte-identical files, visually
  similar images, and matching filenames to review and clear out.

### Share and sync
- Share an image straight from the viewer — AirDrop, Mail, Messages, or
  Save to Files.
- From Finder, right-click any file → **Share → Muse** to send it into your
  library.
- Optional **iCloud sync** keeps one folder synced across your Macs. Each
  image carries a tiny sidecar of its tags, colors, and analysis, so a
  second Mac restores everything without re-analyzing.

### Make it yours
- Background moods: Light, Dark, Auto (light by day, dark at night), or a
  custom color.
- Drive it from anywhere via Shortcuts, Siri, and Spotlight (App Intents).

## Requirements

- macOS 14.6 or later (Apple Intelligence features require macOS 26+)
- Xcode 16+ to build

## Tech

- **UI:** SwiftUI, with PDFKit, AVKit, and SceneKit for the viewers
- **Intelligence:** Apple Vision (on-device) + Foundation Models, capability-gated
- **Database:** GRDB.swift (SQLite) with FTS5 full-text search
- **Storage:** `~/Library/Application Support/Muse/` (sandboxed container)

## Build

Open `Muse/Muse.xcodeproj` in Xcode 16+ and run (Cmd+R). GRDB is fetched
automatically via Swift Package Manager. On first launch, click **Add
Folder** in the sidebar to point Muse at any folder on disk.

## Acknowledgements

- Custom background color sliders are designed after
  [SwiftUI-Color-Kit](https://github.com/kieranb662/SwiftUI-Color-Kit)
  by Kieran Brown (implemented natively in Muse — no dependency).
