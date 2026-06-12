# Muse

> **Work in progress** — actively being built. Not ready for use yet.


<img width="1382" height="1004" alt="Screenshot 2026-03-19 at 8 57 13 PM" src="https://github.com/user-attachments/assets/09e936a9-01d2-4774-8381-33ed9c3b3563" />



A native macOS desktop app for storing and organizing inspiration images. Local-only, no cloud.

Built with SwiftUI, SceneKit, and GRDB.swift.

## Features

### Grid View
- Masonry layout with parallax tilt on mouse movement
- Click to preview full-size image with info panel
- Cmd+click to multi-select for batch tagging
- Drag-and-drop import

### Universe View
- All collections displayed as 3D globes scattered in space
- Click a globe to fly into it and explore the collection
- Unsorted images get their own globe

### Globe View
- Single collection's images tiled on a 3D Fibonacci sphere
- Drag to spin, click an image to focus and see details
- Auto-rotation with smooth pause/resume

### Folder View
- Collections as 3D folders with open/close animation
- Images fan out in a grid when a folder opens
- Collection tabs for quick switching

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
