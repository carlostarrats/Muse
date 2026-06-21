# Collection PDF Tag Pills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the collection PDF export carry the active tag filter — export only the on-screen (refined) images, and draw the active tag labels as pills above the collection name in the PDF header.

**Architecture:** Two contained changes. (1) `CollectionPDFExporter.makePDF` gains a `tagLabels` parameter and a pill-aware page-1 header: bare CoreText capsules above the title, with a variable first-page header height fed into the already-variable `CollectionPDFLayout.paginate`. (2) `ShareCollectionButton` switches its export set from `activeCollectionFiles` (all members) to `visibleFiles` (the filtered grid) and passes the active labels.

**Tech Stack:** Swift, SwiftUI, CoreGraphics/CoreText (PDF drawing), AppKit. No new dependencies. macOS 14.6+.

## Global Constraints

- **No network calls.** Sandbox forbids it; nothing here needs it.
- **No new third-party deps.**
- **CoreText only inside the detached export task** — `drawHeader`/`drawCaption`/pill drawing run off the main thread, so use CTFont/CGColor, never AppKit (`NSFont`/`NSColor`).
- **Unfiltered export must be byte-for-byte unchanged** — no tags → no pills → 46pt header → identical output to today.
- **Pills appear for 1+ active tags** (not the on-screen banner's 2+ threshold) — the PDF has no chip row, so a single pill is the only refinement cue.
- **Pills are bare labels** — no "Viewing"/"and"/comma connective words.
- **Testing reality:** pill placement is CoreText text measurement with no pure-logic surface; it is verified by build + a manual tag-filtered export, consistent with the existing untested `drawHeader`/`drawCaption`. The unit-tested surface (`CollectionPDFLayout` pagination) is unchanged.

---

### Task 1: Pill-aware PDF header in `CollectionPDFExporter`

Add a `tagLabels` parameter (defaulted so the existing call site keeps compiling), the pill geometry constants, a pill row-layout helper, a pill-drawing helper, and wire them into `makePDF` (header-height computation) and `drawHeader` (draw pills above the title).

**Files:**
- Modify: `Muse/Muse/Export/CollectionPDFExporter.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `CollectionPDFExporter.makePDF(urls:title:count:columns:layoutAspect:tileBackdrop:tagLabels:)` — adds `tagLabels: [String] = []` as the final parameter.
  - Private nested `PillLayout` (`pills: [PillLayout.Pill]`, `blockHeight: CGFloat`) and helpers `layoutPills(...)`, `drawPill(...)` — internal to the exporter, no external consumer.

- [ ] **Step 1: Add the pill geometry constants and `PillLayout` model**

In `CollectionPDFExporter.swift`, just inside `enum CollectionPDFExporter {` (above `makePDF`), add:

```swift
    // MARK: - Tag pills (page-1 header)

    /// Geometry for the tag-filter pills drawn above the collection title.
    /// Mirrors the on-screen `BannerPill` (12pt medium, 8pt h-pad, quiet wash).
    private static let pillFontSize: CGFloat = 12
    private static let pillHeight: CGFloat = 16      // 12pt text + 2*2pt v-pad
    private static let pillPadH: CGFloat = 8
    private static let pillRowGap: CGFloat = 4       // between wrapped pill rows
    private static let pillGap: CGFloat = 6          // between pills in a row
    private static let pillToTitleGap: CGFloat = 10  // pill block → title baseline
    private static let titleFontSize: CGFloat = 24
    /// The original title-only header reserve (kept so the gap below the title
    /// to the first image is unchanged whether or not pills are present).
    private static let titleBlockHeight: CGFloat = 46

    /// One positioned pill plus the laid-out block, in TOP-LEFT-origin coords
    /// (y from the page top); the drawing code flips to PDF bottom-left.
    private struct PillLayout {
        struct Pill { let label: String; let x: CGFloat; let topFromTop: CGFloat; let width: CGFloat }
        let pills: [Pill]
        let blockHeight: CGFloat
    }
```

- [ ] **Step 2: Add the `layoutPills` and `drawPill` helpers**

Add these private helpers to the enum (e.g. directly below the `aspectFit` helper at the bottom of the file):

```swift
    /// Width of one pill: measured label width + horizontal padding both sides.
    private static func pillWidth(_ label: String, font: CTFont) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: label, attributes: attrs))
        let textW = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        return textW + pillPadH * 2
    }

    /// Lay `labels` left → right starting at (`originX`, `originTop`) (top-left
    /// origin), wrapping to a new row when the next pill would exceed `maxWidth`
    /// (always at least one pill per row). Returns positioned pills + the total
    /// block height. Caller guards `labels` non-empty.
    private static func layoutPills(_ labels: [String], font: CTFont,
                                    originX: CGFloat, originTop: CGFloat,
                                    maxWidth: CGFloat) -> PillLayout {
        var pills: [PillLayout.Pill] = []
        var x = originX
        var top = originTop
        var rows = 1
        for label in labels {
            let w = pillWidth(label, font: font)
            if x > originX, x + w > originX + maxWidth {
                x = originX
                top += pillHeight + pillRowGap
                rows += 1
            }
            pills.append(.init(label: label, x: x, topFromTop: top, width: w))
            x += w + pillGap
        }
        let blockHeight = CGFloat(rows) * pillHeight + CGFloat(rows - 1) * pillRowGap
        return PillLayout(pills: pills, blockHeight: blockHeight)
    }

    /// Draw one pill: a quiet capsule (black @ 8% on the white page) with the
    /// vertically-centered, left-padded label (black). PDF bottom-left coords.
    private static func drawPill(_ p: PillLayout.Pill, font: CTFont, in ctx: CGContext,
                                 pageSize: CGSize) {
        let rect = CGRect(x: p.x, y: pageSize.height - p.topFromTop - pillHeight,
                          width: p.width, height: pillHeight)
        let path = CGPath(roundedRect: rect, cornerWidth: pillHeight / 2,
                          cornerHeight: pillHeight / 2, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.08))
        ctx.fillPath()

        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: p.label, attributes: [fontKey: font, colorKey: CGColor(gray: 0, alpha: 1)]))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let baselineFromTop = p.topFromTop + (pillHeight - (ascent + descent)) / 2 + ascent
        ctx.textPosition = CGPoint(x: p.x + pillPadH, y: pageSize.height - baselineFromTop)
        CTLineDraw(line, ctx)
    }
```

- [ ] **Step 3: Add the `tagLabels` parameter and compute the variable header height in `makePDF`**

Change the `makePDF` signature to add the new final parameter:

```swift
    static func makePDF(urls: [URL], title: String, count: Int, columns: Int,
                        layoutAspect: CGFloat?, tileBackdrop: CGColor?,
                        tagLabels: [String] = []) async -> URL? {
```

Inside the detached task, **delete** the fixed header line:

```swift
            let headerHeight: CGFloat = 46
```

Then, immediately after `let contentWidth = pageSize.width - margin * 2` (currently line ~37), insert the pill layout + computed header height:

```swift
            // Tag-filter pills (page-1 header). Lay them out now so the first-
            // page header reserve can grow to fit; empty labels → no pills → the
            // original 46pt title-only header (unchanged unfiltered export).
            let pillFont = CTFontCreateUIFontForLanguage(.system, pillFontSize, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, pillFontSize, nil)
            let pillLayout: PillLayout? = tagLabels.isEmpty ? nil
                : layoutPills(tagLabels, font: pillFont, originX: margin,
                              originTop: margin, maxWidth: contentWidth)
            let headerHeight: CGFloat = pillLayout
                .map { $0.blockHeight + pillToTitleGap + titleBlockHeight } ?? titleBlockHeight
```

- [ ] **Step 4: Pass the pill layout into the header draw call**

Update the `drawHeader` call inside the `pageIndex == 0` block:

```swift
                if pageIndex == 0 {
                    drawHeader(title: title, count: count,
                               pillLayout: pillLayout, pillFont: pillFont,
                               in: ctx, pageSize: pageSize, margin: margin)
                }
```

- [ ] **Step 5: Rewrite `drawHeader` to draw pills above the title**

Replace the existing `drawHeader(title:count:in:pageSize:margin:)` with:

```swift
    /// Page-1 header: optional tag-filter pills at the top, then "Title  count"
    /// below them. With no pills the title sits exactly where it did before
    /// (baseline 24pt below the top margin). CoreText only (off the main thread).
    private static func drawHeader(title: String, count: Int,
                                   pillLayout: PillLayout?, pillFont: CTFont,
                                   in ctx: CGContext, pageSize: CGSize, margin: CGFloat) {
        var titleBaselineFromTop = margin + titleFontSize
        if let pillLayout {
            for p in pillLayout.pills {
                drawPill(p, font: pillFont, in: ctx, pageSize: pageSize)
            }
            titleBaselineFromTop = margin + pillLayout.blockHeight
                + pillToTitleGap + titleFontSize
        }

        let base = CTFontCreateUIFontForLanguage(.system, titleFontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, titleFontSize, nil)
        let font = CTFontCreateCopyWithSymbolicTraits(base, titleFontSize, nil, .traitBold, .traitBold) ?? base
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let attr = NSMutableAttributedString(
            string: title,
            attributes: [fontKey: font, colorKey: CGColor(gray: 0, alpha: 1)])
        attr.append(NSAttributedString(
            string: "  \(count)",
            attributes: [fontKey: font, colorKey: CGColor(gray: 0.5, alpha: 1)]))
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: margin, y: pageSize.height - titleBaselineFromTop)
        CTLineDraw(line, ctx)
    }
```

- [ ] **Step 6: Build**

Run: `cd "Muse" && xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. (The existing `ShareCollectionButton` call site still compiles because `tagLabels` defaults to `[]`.)

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Export/CollectionPDFExporter.swift
git commit -m "feat: draw active tag pills above the title in the collection PDF header"
```

---

### Task 2: Export the filtered grid + pass tag labels — `ShareCollectionButton`

Switch the export set from all members to the on-screen filtered grid and feed the active tag labels into the exporter.

**Files:**
- Modify: `Muse/Muse/Views/ShareCollectionButton.swift`

**Interfaces:**
- Consumes: `CollectionPDFExporter.makePDF(...tagLabels:)` from Task 1; `AppState.visibleFiles: [FileNode]`; `AppState.activeTagLabels: [String]`.
- Produces: no new interface.

- [ ] **Step 1: Export the filtered grid instead of all members**

Replace the `exportURLs` computed property:

```swift
    /// The collection's CURRENTLY VISIBLE members, in grid order — the on-screen
    /// set, so an active tag/facet filter narrows the export (images and file
    /// cards alike; folders are excluded — they aren't grid content to export).
    private var exportURLs: [URL] {
        appState.visibleFiles.compactMap { node in
            node.kind == .folder ? nil : node.url
        }
    }
```

- [ ] **Step 2: Pass the active tag labels into `makePDF`**

In `makePDF()`, add `tagLabels` to the exporter call:

```swift
        return await CollectionPDFExporter.makePDF(
            urls: urls, title: title, count: urls.count, columns: gridColumns,
            layoutAspect: layoutAspect, tileBackdrop: backdrop,
            tagLabels: appState.activeTagLabels)
```

- [ ] **Step 3: Build**

Run: `cd "Muse" && xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the unit suite (regression guard)**

Run: `cd "Muse" && xcodebuild -scheme Muse -destination 'platform=macOS' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **` (no test changes; `CollectionPDFLayout` pagination tests still pass — geometry is unchanged for the unfiltered case).

- [ ] **Step 5: Manual verification (the real test for the CoreText drawing)**

In the running app, open a collection that has tagged images:
1. **Unfiltered export** → Save to… → confirm the PDF is identical to before (title + count, no pills, all members).
2. **Single tag** (click one chip) → export → confirm the PDF shows ONLY the matching images and ONE pill above the title.
3. **Two tags** (Cmd-click a second chip) → export → confirm the PDF shows only the intersection images and both pills (`[a] [b]`) above the title, no "Viewing"/"and" words.
4. **Filter to empty** → confirm the Share button is disabled (no export of an empty grid).

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Views/ShareCollectionButton.swift
git commit -m "feat: export the tag-filtered grid (not all members) from a collection share"
```

---

## Self-Review

- **Spec coverage:** Export-the-filtered-set → Task 2 Step 1 (`visibleFiles`). Pills for 1+ tags → Task 1 (`tagLabels.isEmpty ? nil : ...`, drawn for every label). Bare pills / no connective words → Task 1 `drawPill` draws only labels. Variable header / unchanged unfiltered → Task 1 Step 3 (`headerHeight` falls back to `titleBlockHeight = 46`). Pass labels → Task 2 Step 2. All spec points covered.
- **Placeholder scan:** No TBDs; every code step shows complete code.
- **Type consistency:** `makePDF(...tagLabels:)`, `PillLayout`/`PillLayout.Pill`, `layoutPills`, `drawPill`, `pillFont`, `pillLayout`, the constants (`pillFontSize`/`pillHeight`/`pillPadH`/`pillRowGap`/`pillGap`/`pillToTitleGap`/`titleFontSize`/`titleBlockHeight`) are named identically across Tasks 1–2 and the `drawHeader` signature change matches its call site.
