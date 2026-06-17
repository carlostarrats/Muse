# Collection PDF Share Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Share control to the in-collection header that exports the collection's images as a paginated 11×14in PDF, openable via a Save-to-disk dialog or the standard macOS share sheet.

**Architecture:** A pure pagination function (`CollectionPDFLayout`) packs per-image aspect ratios into fixed-size pages with a masonry pack and page breaks. An exporter (`CollectionPDFExporter`) loads downsampled images via ImageIO, runs the layout, and draws each page into a `CGPDFContext`, returning a temp-file URL. A SwiftUI menu (`ShareCollectionButton`) builds the PDF on demand and routes it to an `NSSavePanel` (defaulted to Desktop) or `NSSharingServicePicker`. No system UI is customized; no new entitlement.

**Tech Stack:** Swift, SwiftUI, AppKit, CoreGraphics (`CGPDFContext`), ImageIO, CoreText, XCTest. macOS 14.6+.

**Spec:** `docs/superpowers/specs/2026-06-16-collection-pdf-share-design.md`

---

## File Structure

- **Create** `Muse/Muse/Export/CollectionPDFLayout.swift` — pure pagination (no I/O). Unit-tested.
- **Create** `Muse/Muse/Export/CollectionPDFExporter.swift` — ImageIO load + CGPDF draw → temp URL.
- **Create** `Muse/Muse/Views/ShareCollectionButton.swift` — header menu (Save to… / Share).
- **Create** `Muse/MuseTests/CollectionPDFLayoutTests.swift` — layout unit tests.
- **Modify** `Muse/Muse/Views/CollectionsRow.swift` — add `ShareCollectionButton` to `ActiveCollectionHeader`'s `HStack`, before `TrashButton`.

New `.swift` files under the `Muse` group (a `fileSystemSynchronizedGroups` root) are auto-included in the target — only verify after building. Build/test from the repo root `/Users/carlostarrats/Documents/Projects/Muse/Muse App`.

**Reference commands:**
- Build: `xcodebuild build -project "Muse/Muse.xcodeproj" -scheme Muse -destination 'platform=macOS' 2>&1 | tail -30`
- Test (this suite): `xcodebuild test -project "Muse/Muse.xcodeproj" -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/CollectionPDFLayoutTests 2>&1 | tail -30`

---

## Task 1: CollectionPDFLayout (pure pagination) + tests

**Files:**
- Create: `Muse/Muse/Export/CollectionPDFLayout.swift`
- Test: `Muse/MuseTests/CollectionPDFLayoutTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Muse/MuseTests/CollectionPDFLayoutTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import Muse

final class CollectionPDFLayoutTests: XCTestCase {
    // 11x14in @ 72dpi, 0.5in margins, 3 columns, 12pt gutter, 46pt page-1 header.
    private let geo = CollectionPDFLayout.Geometry(
        pageSize: CGSize(width: 792, height: 1008),
        margin: 36, columns: 3, gutter: 12, firstPageHeaderHeight: 46)

    func testEmptyInputProducesNoPages() {
        XCTAssertTrue(CollectionPDFLayout.paginate(aspects: [], geometry: geo).isEmpty)
    }

    func testEveryImagePlacedExactlyOnce() {
        let pages = CollectionPDFLayout.paginate(
            aspects: Array(repeating: 1.0, count: 25), geometry: geo)
        let indices = pages.flatMap { $0.placements.map(\.index) }.sorted()
        XCTAssertEqual(indices, Array(0..<25))
    }

    func testManyImagesPaginateIntoMultiplePages() {
        let pages = CollectionPDFLayout.paginate(
            aspects: Array(repeating: 1.0, count: 25), geometry: geo)
        XCTAssertGreaterThan(pages.count, 1)
    }

    func testNoTileCrossesPageBounds() {
        let pages = CollectionPDFLayout.paginate(
            aspects: Array(repeating: 1.5, count: 40), geometry: geo)
        let contentBottom = geo.pageSize.height - geo.margin
        for (p, page) in pages.enumerated() {
            let top = geo.margin + (p == 0 ? geo.firstPageHeaderHeight : 0)
            for pl in page.placements {
                XCTAssertGreaterThanOrEqual(pl.rect.minY, top - 0.5)
                XCTAssertLessThanOrEqual(pl.rect.maxY, contentBottom + 0.5)
                XCTAssertGreaterThanOrEqual(pl.rect.minX, geo.margin - 0.5)
                XCTAssertLessThanOrEqual(pl.rect.maxX, geo.pageSize.width - geo.margin + 0.5)
            }
        }
    }

    func testOversizedTallImageCappedToOnePage() {
        let pages = CollectionPDFLayout.paginate(aspects: [10.0], geometry: geo)
        XCTAssertEqual(pages.count, 1)
        let pl = pages[0].placements[0]
        let avail = (geo.pageSize.height - geo.margin)
                  - (geo.margin + geo.firstPageHeaderHeight)
        XCTAssertLessThanOrEqual(pl.rect.height, avail + 0.5)
    }

    func testColumnWidthMatchesGeometry() {
        let pages = CollectionPDFLayout.paginate(aspects: [1.0], geometry: geo)
        // (792 - 72 - 12*2) / 3 = 232
        XCTAssertEqual(pages[0].placements[0].rect.width, 232, accuracy: 0.5)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project "Muse/Muse.xcodeproj" -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/CollectionPDFLayoutTests 2>&1 | tail -30`
Expected: FAIL — compile error, `CollectionPDFLayout` not found.

- [ ] **Step 3: Write the implementation**

Create `Muse/Muse/Export/CollectionPDFLayout.swift`:

```swift
//
//  CollectionPDFLayout.swift
//  Muse
//
//  Pure pagination of a collection's images into fixed-size PDF pages using
//  a masonry (shortest-column) pack. No I/O — deterministic and unit-tested.
//  Coordinates use a TOP-LEFT origin (y grows downward); the exporter flips
//  to PDF's bottom-left origin when drawing.
//

import CoreGraphics

enum CollectionPDFLayout {

    struct Placement: Equatable {
        let index: Int      // index into the input aspects array
        let rect: CGRect    // page coordinates, top-left origin
    }

    struct Page: Equatable {
        var placements: [Placement]
    }

    struct Geometry {
        var pageSize: CGSize                // e.g. 792 x 1008 (11x14in @ 72dpi)
        var margin: CGFloat                 // outer margin on all sides
        var columns: Int                    // tiles per row (>= 1)
        var gutter: CGFloat                 // gap between tiles
        var firstPageHeaderHeight: CGFloat  // reserved at top of page 1 only
    }

    /// Pack `aspects` (height ÷ width per image) into pages. Each tile keeps
    /// its image's shape (tile height = columnWidth × aspect) so nothing is
    /// cropped. A tile taller than a page's content area is capped to fit one
    /// page. No image is ever split across a page boundary.
    static func paginate(aspects: [CGFloat], geometry g: Geometry) -> [Page] {
        guard !aspects.isEmpty else { return [] }
        let cols = max(1, g.columns)
        let contentWidth = max(1, g.pageSize.width - g.margin * 2)
        let columnWidth = max(1, (contentWidth - g.gutter * CGFloat(cols - 1)) / CGFloat(cols))
        let contentBottom = g.pageSize.height - g.margin

        func contentTop(firstPage: Bool) -> CGFloat {
            g.margin + (firstPage ? g.firstPageHeaderHeight : 0)
        }
        func available(firstPage: Bool) -> CGFloat {
            max(1, contentBottom - contentTop(firstPage: firstPage))
        }

        var pages: [Page] = []
        var current = Page(placements: [])
        var colHeights = [CGFloat](repeating: 0, count: cols)
        var firstPage = true

        for (i, rawAspect) in aspects.enumerated() {
            let aspect = rawAspect > 0 ? rawAspect : 1
            var avail = available(firstPage: firstPage)
            var tileH = min(columnWidth * aspect, avail)

            // Shortest column.
            var col = 0
            for c in 1..<cols where colHeights[c] < colHeights[col] { col = c }

            // New page if the tile won't fit — but never break just to place
            // the first tile of an (already empty) page.
            if !current.placements.isEmpty, colHeights[col] + tileH > avail {
                pages.append(current)
                current = Page(placements: [])
                colHeights = [CGFloat](repeating: 0, count: cols)
                firstPage = false
                col = 0
                avail = available(firstPage: firstPage)
                tileH = min(columnWidth * aspect, avail)
            }

            let x = g.margin + CGFloat(col) * (columnWidth + g.gutter)
            let y = contentTop(firstPage: firstPage) + colHeights[col]
            current.placements.append(
                Placement(index: i, rect: CGRect(x: x, y: y, width: columnWidth, height: tileH)))
            colHeights[col] += tileH + g.gutter
        }

        if !current.placements.isEmpty { pages.append(current) }
        return pages
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project "Muse/Muse.xcodeproj" -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/CollectionPDFLayoutTests 2>&1 | tail -30`
Expected: PASS — all six tests succeed. (If the run reports the test class is unknown, the file wasn't picked up by the `MuseTests` target — add it to the target in Xcode, then re-run.)

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Export/CollectionPDFLayout.swift" "Muse/MuseTests/CollectionPDFLayoutTests.swift"
git commit -m "Add CollectionPDFLayout: pure paginated masonry pack for PDF export

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: CollectionPDFExporter (image load + PDF draw)

**Files:**
- Create: `Muse/Muse/Export/CollectionPDFExporter.swift`

No unit test — this is ImageIO + CoreGraphics I/O, verified by building and by the manual run in Task 5.

- [ ] **Step 1: Write the implementation**

Create `Muse/Muse/Export/CollectionPDFExporter.swift`:

```swift
//
//  CollectionPDFExporter.swift
//  Muse
//
//  Builds a paginated 11x14in PDF of a collection's images (whole images,
//  masonry pack, page-1 title block) and writes it to a temp file. Heavy work
//  (ImageIO decode + PDF draw) runs off the main thread. Returns the file URL.
//

import CoreGraphics
import ImageIO
import CoreText
import AppKit

enum CollectionPDFExporter {

    /// Build the PDF for `urls` (image files, in display order). `count` is the
    /// number shown beside the title. `columns` mirrors the grid density.
    /// Returns a temp-file URL, or nil if nothing could be rendered.
    static func makePDF(urls: [URL], title: String, count: Int, columns: Int) async -> URL? {
        await Task.detached(priority: .userInitiated) { () -> URL? in
            let pageSize = CGSize(width: 792, height: 1008)   // 11x14in @ 72dpi
            let margin: CGFloat = 36
            let gutter: CGFloat = 12
            let headerHeight: CGFloat = 46
            let cols = max(1, columns)
            let contentWidth = pageSize.width - margin * 2
            let columnWidth = (contentWidth - gutter * CGFloat(cols - 1)) / CGFloat(cols)
            let maxPixel = Int((columnWidth * 2).rounded(.up))   // crisp without bloat

            // Load downsampled, orientation-corrected images + their aspect.
            var images: [(cg: CGImage, aspect: CGFloat)] = []
            images.reserveCapacity(urls.count)
            for url in urls {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { continue }
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel
                ]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { continue }
                let w = CGFloat(cg.width), h = CGFloat(cg.height)
                guard w > 0, h > 0 else { continue }
                images.append((cg, h / w))
            }
            guard !images.isEmpty else { return nil }

            let geo = CollectionPDFLayout.Geometry(
                pageSize: pageSize, margin: margin, columns: cols,
                gutter: gutter, firstPageHeaderHeight: headerHeight)
            let pages = CollectionPDFLayout.paginate(aspects: images.map(\.aspect), geometry: geo)

            // PDF context (origin bottom-left).
            let data = NSMutableData()
            guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
            var mediaBox = CGRect(origin: .zero, size: pageSize)
            guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

            for (pageIndex, page) in pages.enumerated() {
                ctx.beginPDFPage(nil)
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(origin: .zero, size: pageSize))

                if pageIndex == 0 {
                    drawHeader(title: title, count: count, in: ctx,
                               pageSize: pageSize, margin: margin)
                }

                for pl in page.placements {
                    let img = images[pl.index].cg
                    // Flip top-left layout coords → PDF bottom-left.
                    let flipped = CGRect(
                        x: pl.rect.origin.x,
                        y: pageSize.height - pl.rect.origin.y - pl.rect.height,
                        width: pl.rect.width, height: pl.rect.height)
                    let fit = aspectFit(imageW: CGFloat(img.width),
                                        imageH: CGFloat(img.height), in: flipped)
                    ctx.draw(img, in: fit)
                }
                ctx.endPDFPage()
            }
            ctx.closePDF()

            let safe = title.replacingOccurrences(of: "/", with: "-")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = safe.isEmpty ? "Collection" : safe
            let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("\(name).pdf")
            try? FileManager.default.removeItem(at: outURL)
            guard data.write(to: outURL, atomically: true) else { return nil }
            return outURL
        }.value
    }

    /// "Title  count" at 24pt, top-left of the content box. PDF (bottom-left)
    /// coordinates: text baseline sits 24pt below the top margin.
    private static func drawHeader(title: String, count: Int, in ctx: CGContext,
                                   pageSize: CGSize, margin: CGFloat) {
        let attr = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
                .foregroundColor: NSColor.black
            ])
        attr.append(NSAttributedString(
            string: "  \(count)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
                .foregroundColor: NSColor.gray
            ]))
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: margin, y: pageSize.height - margin - 24)
        CTLineDraw(line, ctx)
    }

    /// Largest rect with the image's aspect that fits inside `box`, centered.
    private static func aspectFit(imageW: CGFloat, imageH: CGFloat, in box: CGRect) -> CGRect {
        guard imageW > 0, imageH > 0, box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / imageW, box.height / imageH)
        let w = imageW * scale, h = imageH * scale
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project "Muse/Muse.xcodeproj" -scheme Muse -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add "Muse/Muse/Export/CollectionPDFExporter.swift"
git commit -m "Add CollectionPDFExporter: render collection images to a paginated PDF

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: ShareCollectionButton (header menu)

**Files:**
- Create: `Muse/Muse/Views/ShareCollectionButton.swift`

- [ ] **Step 1: Write the implementation**

Create `Muse/Muse/Views/ShareCollectionButton.swift`:

```swift
//
//  ShareCollectionButton.swift
//  Muse
//
//  In-collection header control: a menu with "Save to…" (NSSavePanel,
//  defaulted to Desktop) and "Share" (standard NSSharingServicePicker). Both
//  build a paginated PDF of the collection's displayed images first. Nothing
//  about the system share sheet is customized; no new entitlement is needed.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ShareCollectionButton: View {
    @EnvironmentObject var appState: AppState
    let title: String
    let count: Int

    // Mirror the grid's current density (the bottom-right column slider).
    @AppStorage("gridColumnCount") private var gridColumns = 4
    @State private var hovering = false
    @State private var preparing = false

    /// The collection's displayed image members, in grid order.
    private var imageURLs: [URL] {
        (appState.activeCollectionFiles ?? []).compactMap { node in
            switch node.kind {
            case .image, .raw, .psd: return node.url
            default: return nil
            }
        }
    }

    var body: some View {
        Menu {
            Button("Save to…") { Task { await save() } }
            Button("Share") { Task { await share() } }
        } label: {
            Group {
                if preparing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(hovering ? .primary : .secondary)
                }
            }
            .frame(width: 40, height: 40)
            .background(Circle().fill(.primary.opacity(hovering ? 0.16 : 0.08)))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .disabled(preparing || count == 0 || imageURLs.isEmpty)
        .help("Share collection")
    }

    private func buildPDF() async -> URL? {
        preparing = true
        defer { preparing = false }
        let urls = imageURLs
        return await CollectionPDFExporter.makePDF(
            urls: urls, title: title, count: urls.count, columns: gridColumns)
    }

    private func save() async {
        guard let pdf = await buildPDF() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.nameFieldStringValue = "\(title).pdf"
        panel.directoryURL = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: pdf, to: dest)
    }

    private func share() async {
        guard let pdf = await buildPDF() else { return }
        guard let contentView = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [pdf])
        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project "Muse/Muse.xcodeproj" -scheme Muse -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`. (The view is unused until Task 4 — this only checks it compiles.)

- [ ] **Step 3: Commit**

```bash
git add "Muse/Muse/Views/ShareCollectionButton.swift"
git commit -m "Add ShareCollectionButton: Save to… / Share menu for a collection

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Wire the button into the collection header

**Files:**
- Modify: `Muse/Muse/Views/CollectionsRow.swift` (inside `ActiveCollectionHeader.body`, the `HStack`)

- [ ] **Step 1: Add the button before the trash button**

In `Muse/Muse/Views/CollectionsRow.swift`, find this block in `ActiveCollectionHeader.body` (currently ends the `HStack`):

```swift
            Spacer()
            TrashButton { confirmDelete = true }
        }
```

Replace it with:

```swift
            Spacer()
            ShareCollectionButton(title: loaded.collection.name, count: loaded.aliveCount)
            TrashButton { confirmDelete = true }
        }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project "Muse/Muse.xcodeproj" -scheme Muse -destination 'platform=macOS' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add "Muse/Muse/Views/CollectionsRow.swift"
git commit -m "Wire ShareCollectionButton into the in-collection header

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Manual verification in the running app

**Files:** none (verification only)

- [ ] **Step 1: Build and run the app**

Use the `run` skill (or open `Muse/Muse.xcodeproj` in Xcode and Cmd+R). Point Muse at a folder with images and let a collection form (or open an existing one).

- [ ] **Step 2: Verify the control + Save path**

- Inside a collection, confirm a Share (`square.and.arrow.up`) circle sits between Edit/Spacer and the Trash button, matching the header button styling.
- Click it → menu shows **Save to…** and **Share**.
- Choose **Save to…** → the save dialog opens defaulted to the Desktop with `<Collection Name>.pdf` pre-filled. Save it.
- Open the saved PDF in Preview and confirm:
  - 11×14 portrait pages, multiple pages for a large collection (not one tall page).
  - Page 1 has the collection name at 24pt with the count right after it, top-left.
  - Images are whole (not cropped), packed masonry-style, no chrome/tags.
  - Tile density matches the grid's current column-slider setting (try changing the slider, re-export, confirm the difference).

- [ ] **Step 3: Verify the Share path**

- Click Share → **Share** → the standard macOS share sheet appears with the PDF (AirDrop/Mail/Messages/etc.). Confirm it lists the PDF and the button returns from its spinner state afterward.

- [ ] **Step 4: Verify the empty/edge guard**

- Confirm the control is disabled for a collection with zero images.

- [ ] **Step 5: Commit any fixes**

If manual verification surfaces issues, fix them and commit with a descriptive message. Otherwise no commit needed.

---

## Notes for the implementer

- **PDF coordinate flip:** `CollectionPDFLayout` uses a top-left origin; `CGPDFContext` uses bottom-left. The exporter flips each rect (`y = pageHeight - origin.y - height`). Don't double-flip.
- **Orientation:** thumbnails are created with `kCGImageSourceCreateThumbnailWithTransform`, so the decoded pixels (and thus the aspect fed to layout) are already upright. Don't re-apply EXIF orientation.
- **Off-main:** all decode/draw is inside `Task.detached`; only the `NSSavePanel`/`NSSharingServicePicker` presentation touches the main actor (in the `@MainActor` View methods).
- **No new entitlement:** `NSSavePanel` grants write access to the chosen location through the existing `files.user-selected.read-write`. Do not add a Desktop entitlement.
