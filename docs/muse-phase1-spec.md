# Muse Phase 1 -- macOS Inspiration Library App
## Build Specification for Claude Code

---

## Overview

Muse is a native macOS desktop app for storing, organizing, and browsing a personal library of inspiration images. Entirely local. No cloud, no accounts, no sign-in.

This spec covers Phase 1 only: project setup, data layer, image import, Grid view, and the detail panel. The app will eventually have 3D SceneKit views (Universe, Globe, Folder) and AI-powered auto-tagging, but those are separate specs. Do not build anything beyond what is described here.

---

## Project Setup

```
Xcode project name: Muse
Bundle ID: com.tarrats.muse
Deployment target: macOS 14.0+
Language: Swift 5.9+
UI Framework: SwiftUI
Local DB: SQLite via GRDB.swift
```

### Swift Package Dependencies

Add via Xcode > File > Add Package Dependencies:

- `https://github.com/groue/GRDB.swift` (latest stable)

No other external dependencies for Phase 1.

### Storage Location

All app data lives in `~/Library/Application Support/Muse/`:

```
Muse/
├── muse.db          # SQLite database
└── Images/
    ├── <uuid>_original.jpg
    └── <uuid>_thumb.jpg
```

Create these directories at launch if they do not exist.

---

## File Structure

Build these files. Do not add files for features outside this spec (no SceneKit scenes, no AI providers).

```
Muse/
├── MuseApp.swift                  # App entry point, injects AppState
├── ContentView.swift              # Main window layout
│
├── Models/
│   ├── MuseImage.swift            # Image record
│   ├── Collection.swift           # Collection/group record
│   ├── Tag.swift                  # Tag record
│   └── AppState.swift             # Observable app-wide state
│
├── Database/
│   ├── DatabaseManager.swift      # GRDB setup, migrations, error handling
│   └── ImageRepository.swift      # All CRUD operations
│
├── Import/
│   ├── ImportManager.swift        # Coordinates single + bulk import
│   └── ThumbnailGenerator.swift   # Async thumbnail creation
│
├── Views/
│   ├── GridView.swift             # Masonry image grid with depth/tilt
│   └── ImageDetailPanel.swift     # Right-side metadata/tag panel
│
├── Components/
│   ├── TagPill.swift              # Single tag display with delete
│   ├── FlowLayout.swift           # Wrapping horizontal layout for tags
│   ├── MasonryLayout.swift        # Multi-column masonry grid layout
│   ├── CollectionPicker.swift     # Dropdown to assign image to collection
│   ├── SearchBar.swift            # Filter bar
│   └── ImportDropZone.swift       # Drag-and-drop overlay
│
└── Settings/
    └── SettingsView.swift         # Storage info, appearance, placeholder for future AI keys
```

---

## Data Models

### MuseImage

Fields:
- `id` (UUID, primary key, auto-generated)
- `fileName` (String, not null) -- original file name
- `storagePath` (String, not null) -- relative path within app storage, not absolute URL
- `thumbnailPath` (String, nullable) -- relative path to thumbnail
- `collectionID` (UUID, nullable, foreign key to collections)
- `sourceURL` (String, nullable) -- original URL if dragged from browser
- `notes` (String, default empty)
- `width` (Int, nullable) -- original image width in pixels
- `height` (Int, nullable) -- original image height in pixels
- `fileSize` (Int, nullable) -- bytes
- `dateAdded` (Date, not null)
- `dateModified` (Date, not null)

Important: Tags are a separate table joined at query time. Do not store tags as a property on the model struct. Load them via a separate query or GRDB association.

Use relative paths (not absolute URLs) for `storagePath` and `thumbnailPath`. Resolve them against the app's storage directory at runtime. This prevents breakage if the user's home directory path changes.

### Collection

Fields:
- `id` (UUID, primary key)
- `name` (String, not null)
- `colorHex` (String, default "#5E8BFF")
- `sortOrder` (Int, default 0) -- for manual reordering later
- `dateCreated` (Date, not null)

Do not store a denormalized `imageCount`. Query it when needed.

### Tag

Fields:
- `id` (UUID, primary key)
- `imageID` (UUID, not null, foreign key to muse_images, cascade delete)
- `label` (String, not null)
- `source` (String, not null, default "manual") -- "manual" or "ai"

Add a unique index on (imageID, label) to prevent duplicate tags on the same image.

---

## Database Layer

### DatabaseManager

Responsibilities:
- Create a `DatabaseQueue` (not pool) pointed at the muse.db path
- Run migrations using GRDB's `DatabaseMigrator`
- Provide the shared queue to the repository layer

Error handling:
- Wrap all setup in do/catch. Never use `try!` or force unwraps.
- If the database cannot be created or migrated, surface an alert to the user and do not crash.

Migration v1 creates the three tables described above with proper types, foreign keys, and the unique index on tags.

### ImageRepository

All methods are async and do not run on the main thread. Use GRDB's async read/write methods.

Required operations:
- `insertImage(_ image: inout MuseImage) async throws`
- `updateImage(_ image: MuseImage) async throws`
- `deleteImage(_ image: MuseImage) async throws` -- also deletes the image and thumbnail files from disk
- `fetchAllImages() async throws -> [MuseImage]`
- `fetchImages(inCollection collectionID: UUID) async throws -> [MuseImage]`
- `searchImages(query: String) async throws -> [MuseImage]` -- searches file name, notes, and tag labels
- `fetchTags(for imageID: UUID) async throws -> [Tag]`
- `addTag(_ tag: Tag) async throws`
- `deleteTag(_ tag: Tag) async throws`
- `insertCollection(_ collection: inout Collection) async throws`
- `fetchAllCollections() async throws -> [Collection]`
- `deleteCollection(_ collection: Collection) async throws` -- nulls out collectionID on associated images, does not delete the images

---

## Import System

### ImportManager

Handles bringing images into the app. Two entry points:

1. Single file import (from NSOpenPanel or drag-and-drop)
2. Folder import (recursively finds all images in a directory)

Supported formats: jpg, jpeg, png, heic, webp, gif, tiff

Import flow for a single image:
1. Copy the file to `~/Library/Application Support/Muse/Images/<uuid>_original.<ext>`
2. Generate a thumbnail (see below)
3. Read image dimensions using `NSImage` or `CGImageSource`
4. Read file size
5. Create a `MuseImage` record and insert into the database
6. Return the created record

For folder import:
- Enumerate all supported files recursively
- Import each one sequentially (not concurrently, to avoid overwhelming disk I/O)
- Track and publish progress as a fraction (0.0 to 1.0)
- Skip files that fail and log the error. Do not stop the batch.
- Publish the current file name being imported so the UI can show it

ImportManager should be an `ObservableObject` with `@Published` properties for:
- `isImporting: Bool`
- `progress: Double`
- `currentFileName: String`
- `errorCount: Int`

### ThumbnailGenerator

Generate thumbnails asynchronously off the main thread.

Behavior:
- Max dimension 400px on the longest side, preserving aspect ratio
- Output as JPEG at 0.8 compression quality
- Save to `<uuid>_thumb.jpg` in the Images directory
- If thumbnail generation fails, the image still imports. thumbnailPath is just nil.

Do not use `NSImage.lockFocus` (deprecated). Use `CGContext` or `CIImage` for resizing.

---

## App State

### AppState

An `ObservableObject` injected as an `@EnvironmentObject` from the app entry point.

Published properties:
- `images: [MuseImage]` -- all images, loaded at launch
- `collections: [Collection]` -- all collections, loaded at launch
- `selectedImage: MuseImage?` -- currently focused image
- `detailPanelVisible: Bool` -- whether the right panel is showing
- `searchQuery: String` -- current search filter
- `isImporting: Bool` -- mirrors ImportManager state

Computed property:
- `filteredImages: [MuseImage]` -- images filtered by searchQuery (match on fileName, notes). Tag-based filtering can query the repository.

Methods:
- `loadAll() async` -- fetches images and collections from the repository, called at launch
- `refreshAfterImport() async` -- re-fetches images after an import completes

---

## Views

### ContentView

Layout:
- Full window. No sidebar in Phase 1.
- Main area shows `GridView`
- When `detailPanelVisible` is true and `selectedImage` is non-nil, `ImageDetailPanel` slides in from the right edge with a spring animation
- The grid shrinks to make room for the panel (it does not get covered by it)

Toolbar:
- Leading: App title "Muse" as plain text
- Trailing: Search bar, Import button (plus icon, opens NSOpenPanel for files or folders)

Drag and drop:
- The entire window accepts image file drops
- On drop, import the dropped files using ImportManager
- Show a subtle overlay border/highlight while dragging over the window

Import progress:
- While `isImporting` is true, show a small non-modal progress indicator. A thin progress bar at the top of the window or a floating pill showing the current file name and percentage. Do not use a modal sheet or blocking overlay.

### GridView

A scrollable masonry grid of image thumbnails.

Layout:
- Custom masonry layout (multi-column, items of varying height placed to minimize whitespace)
- Default 4 columns, responsive to window width (3 columns below 800px, 5 above 1400px)
- 12px spacing between items
- 20px padding around the grid

Depth effect:
- Each tile gets a random subtle 3D rotation offset on both X and Y axes (small, like 1-3 degrees). Assign this once per tile, not on every render.
- The entire grid has a very slight perspective tilt tied to the mouse cursor position. As the cursor moves left/right, the grid tilts a tiny amount on the Y axis. Same for up/down on the X axis. Max tilt around 2-3 degrees. Smooth with a short animation.

Image tiles:
- Show the thumbnail image, filling the tile width with the natural aspect ratio determining height
- 6px corner radius
- Subtle shadow
- On hover: slight scale up (1.02x) with a quick ease-out transition
- On click: set as `selectedImage`, show detail panel

Performance:
- Load thumbnails asynchronously. Use `AsyncImage` or load `NSImage` in a background task and cache it.
- Do not load NSImage synchronously in the view body.
- For large libraries (500+ images), consider lazy loading only visible images. `LazyVStack` or similar.

### ImageDetailPanel

A right-side panel, 300px wide, with a blurred material background (`.regularMaterial`).

Sections from top to bottom:

1. Header: "Details" label + close button (X icon). Close button sets `detailPanelVisible` to false and clears `selectedImage`.

2. Image preview: Show a larger thumbnail of the selected image at the top of the panel. Constrain to panel width with natural aspect ratio.

3. File info: File name, date added (formatted as abbreviated date), file dimensions (e.g. "1920 x 1080"), file size (formatted as KB/MB). If sourceURL exists, show it truncated.

4. Collection: A dropdown picker showing all collections plus an "Uncategorized" option. Changing the selection updates the image's collectionID and saves.

5. Tags: A flow layout of tag pills. Each pill shows the label and a small X button to delete. Below the tags, a text field to add a new tag. Pressing Enter or clicking "Add" creates a manual tag. Prevent adding a duplicate tag (same label on the same image).

6. Notes: A multi-line text editor. Save changes on focus loss (not on every keystroke).

7. Actions: A "Delete Image" button with a confirmation dialog. Deleting removes the DB record and the files from disk.

All edits save immediately via the repository. Refresh the relevant AppState properties after any change.

### TagPill

A small rounded pill component. Shows the tag label. If `source` is "ai", show a small sparkle icon or visual indicator. Has an optional onDelete closure that shows the X button.

### FlowLayout

A custom SwiftUI layout that arranges children horizontally, wrapping to the next line when they exceed the available width. This is needed for tags. SwiftUI does not have a built-in flow layout. Implement it using the `Layout` protocol (available in macOS 13+).

### MasonryLayout

A custom layout or view that places items in columns, always adding the next item to the shortest column. Accept a `columns` parameter. Use SwiftUI's `Layout` protocol or a `GeometryReader`-based approach.

### CollectionPicker

A simple `Picker` or `Menu` that lists all collections from AppState. Includes an "Uncategorized" option that sets collectionID to nil. Includes a "New Collection..." option at the bottom that presents an inline text field or a small popover to create a new collection with a name.

### SearchBar

A text field with a magnifying glass icon. Bound to `appState.searchQuery`. Debounce input by 300ms before filtering.

### ImportDropZone

An invisible overlay on the full window that responds to drag-and-drop. When files are dragged over the window, show a visible drop indicator (e.g. a dashed border and "Drop images to import" label). On drop, hand the URLs to ImportManager.

---

## Settings

### SettingsView

Accessible via the standard macOS Settings menu item (Cmd+,).

Sections:

1. Storage: Show the path to the images directory. "Open in Finder" button. Show total image count and approximate disk usage.

2. Appearance: System / Light / Dark theme picker using `@AppStorage`.

3. AI Tagging (placeholder): Show a note that says "AI tagging coming soon." with disabled fields for API keys. This section exists so the settings window does not look empty and so the structure is ready for Phase 2. Do not build any AI functionality.

---

## Keyboard Shortcuts

- `Cmd+I` -- Open import panel
- `Escape` -- Close detail panel (if open) or clear search (if active)
- `Cmd+F` -- Focus the search bar
- `Delete/Backspace` -- Delete selected image (with confirmation) when detail panel is open

---

## Error Handling Expectations

Do not use `try!`, `force unwraps`, or `fatalError()` anywhere except in previews.

- Database errors: Surface an alert. Do not crash.
- Import failures: Log the error, increment errorCount, continue the batch.
- Missing thumbnail: Show a gray placeholder rectangle. Do not crash.
- Missing image file on disk: Show placeholder, allow the user to delete the orphaned record.
- Invalid image format: Skip during import, log it.

---

## What Is NOT in This Spec

Do not build any of the following. They are planned for later phases:

- SceneKit views (Universe, Globe, Folder)
- AI tagging (Claude, OpenAI, Gemini providers)
- Bulk tag operations
- Collection color picker
- Image editing or cropping
- Export or sharing
- Any network calls

---

## Build Order

Follow this sequence. Each step should compile and be testable before moving to the next.

1. Create the Xcode project. Add GRDB.swift package.
2. Build DatabaseManager with migration v1. Verify the DB file is created on launch.
3. Build the three model structs (MuseImage, Collection, Tag).
4. Build ImageRepository with insert and fetch operations for images.
5. Build ThumbnailGenerator.
6. Build ImportManager. Test: import a single image via NSOpenPanel, verify it appears in the database and thumbnail is generated.
7. Build AppState. Wire it up in MuseApp.swift as an EnvironmentObject.
8. Build MasonryLayout.
9. Build GridView showing imported images. Test: import 10-20 images, scroll through the grid, verify thumbnails load without blocking.
10. Build FlowLayout, TagPill, CollectionPicker.
11. Build ImageDetailPanel. Wire tap-to-focus in GridView. Test: tap an image, panel slides in, shows metadata.
12. Build tag add/delete in the detail panel. Test: add tags, delete tags, verify persistence.
13. Build SearchBar and filtering. Test: type a query, grid filters.
14. Build ImportDropZone. Test: drag files from Finder onto the window.
15. Build SettingsView.
16. Add keyboard shortcuts.
17. Add the import progress indicator.
18. Test with a large batch (200+ images). Profile for performance issues with thumbnail loading and grid scrolling.
