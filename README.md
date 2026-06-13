# Muse

> **Work in progress** — actively being built. Not ready for use yet.


<img width="1382" height="1004" alt="Screenshot 2026-03-19 at 8 57 13 PM" src="https://github.com/user-attachments/assets/09e936a9-01d2-4774-8381-33ed9c3b3563" />



A native macOS desktop app for storing and organizing inspiration images. Local-only, no cloud.

Built with SwiftUI, SceneKit, and GRDB.swift.

## Features

Three ways to look at a folder — switch with the grid / cloud / galaxy
picker in the toolbar. All of them open an image with the same hero zoom.

### Grid View
- Masonry layout with parallax tilt on mouse movement
- Sortable (Date, Name, Size, Kind, Color, Shape)
- Click to preview full-size image with info panel
- Cmd+click to multi-select for batch tagging
- Drag-and-drop import

### Cloud View
- The folder's images as flat cards floating in a loose 3D ball
- Click-drag to orbit (with inertia), scroll/pinch to zoom
- Cards drift continuously so the cluster stays alive
- Click a card for the hero zoom

### Galaxy View
- The folder's images positioned by learned similarity — a blend of
  visual look (Vision feature prints), meaning (text embeddings), and
  color (palette) — so related images cluster together
- Faint constellation lines link the nearest matches
- Orbit + zoom; click a tile for the hero zoom

### Collections
- Auto-built from analysis; shown as cover cards above the grid
- Pin folders to the sidebar for quick access

### Core
- Import single files, multiple files, or entire folders (jpg, png, heic, webp, gif, tiff)
- Tags, collections, notes, and search
- Batch tagging across multiple selected images
- Progress bar during import

## Requirements

- macOS 14.0+
- Xcode 26.3+
- Swift 6.2

## Tech

- **UI:** SwiftUI + SceneKit
- **Database:** GRDB.swift 7.x (SQLite)
- **Storage:** `~/Library/Application Support/Muse/`

## Build

Open `Muse/Muse.xcodeproj` in Xcode and run (Cmd+R). GRDB is fetched automatically via Swift Package Manager.

## Acknowledgements

- Custom background color sliders are designed after
  [SwiftUI-Color-Kit](https://github.com/kieranb662/SwiftUI-Color-Kit)
  by Kieran Brown (implemented natively in Muse — no dependency).
