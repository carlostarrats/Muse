//
//  CollectionPDFExporter.swift
//  Muse
//
//  Builds a paginated 11x14in PDF of a collection's members (images decoded via
//  ImageIO; non-image file cards rendered via QuickLook — the macOS type icon /
//  content preview, mirroring the grid), masonry/ratio pack, page-1 title block,
//  and writes it to a temp file. Heavy work (decode + PDF draw) runs off the main
//  thread. Returns the file URL.
//

import CoreGraphics
import ImageIO
import CoreText
import Foundation
import QuickLookThumbnailing

enum CollectionPDFExporter {

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

    /// Build the PDF for `urls` (image files, in display order). `count` is the
    /// number shown beside the title. `columns` mirrors the grid density.
    /// `tagLabels` (empty by default) draws the active tag-filter pills above the
    /// title on page 1. `pageSize` is the portrait page size in points (defaults
    /// to 11×14, the original); every other dimension (margin/gutter/captions/
    /// pagination) derives from it. Returns a temp-file URL, or nil if nothing
    /// rendered.
    static func makePDF(urls: [URL], title: String, count: Int, columns: Int,
                        layoutAspect: CGFloat?, tileBackdrop: CGColor?,
                        tagLabels: [String] = [],
                        pageSize: CGSize = PaperSize.default.size) async -> URL? {
        await Task.detached(priority: .userInitiated) { () -> URL? in
            let margin: CGFloat = 36
            let gutter: CGFloat = 12
            // Filename strip below every image: a gap, one ~9pt line, and a
            // little descender slack beneath the baseline.
            let captionFontSize: CGFloat = 9
            let captionGap: CGFloat = 4
            let captionDescender: CGFloat = 4
            let captionHeight: CGFloat = captionGap + captionFontSize + captionDescender
            let cols = max(1, columns)
            let contentWidth = pageSize.width - margin * 2
            let columnWidth = (contentWidth - gutter * CGFloat(cols - 1)) / CGFloat(cols)
            let maxPixel = Int((columnWidth * 2).rounded(.up))   // crisp without bloat

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

            // Load downsampled, orientation-corrected images + their aspect +
            // filename (drawn as a caption under each image). Images decode fast
            // via ImageIO; everything else (zip/pdf/doc…) falls back to
            // QuickLook's macOS type icon / content preview, exactly like the
            // grid's non-image cards. Decode with bounded concurrency (the
            // QuickLook fallback is a per-file XPC round-trip; serial would make
            // a file-card-heavy export feel hung) and reassemble in input order.
            let maxConcurrent = 8
            var slots = [CGImage?](repeating: nil, count: urls.count)
            await withTaskGroup(of: (Int, CGImage?).self) { group in
                var next = 0
                func schedule(_ i: Int) {
                    let url = urls[i]
                    group.addTask {
                        if let cg = imageIOThumbnail(url, maxPixel: maxPixel) { return (i, cg) }
                        return (i, await quickLookThumbnail(url, maxPixel: maxPixel))
                    }
                }
                while next < min(maxConcurrent, urls.count) { schedule(next); next += 1 }
                for await (i, cg) in group {
                    slots[i] = cg
                    if next < urls.count { schedule(next); next += 1 }
                }
            }
            var images: [(cg: CGImage, aspect: CGFloat, name: String)] = []
            images.reserveCapacity(urls.count)
            for (i, cg) in slots.enumerated() {
                guard let cg else { continue }
                let w = CGFloat(cg.width), h = CGFloat(cg.height)
                guard w > 0, h > 0 else { continue }
                images.append((cg, h / w, urls[i].lastPathComponent))
            }
            guard !images.isEmpty else { return nil }

            let geo = CollectionPDFLayout.Geometry(
                pageSize: pageSize, margin: margin, columns: cols,
                gutter: gutter, firstPageHeaderHeight: headerHeight,
                captionHeight: captionHeight)
            // Mirror the on-screen grid: a fixed ratio gives every tile a
            // uniform aspect (even row-major grid); masonry uses each image's
            // own aspect.
            let aspects: [CGFloat] = layoutAspect.map { Array(repeating: $0, count: images.count) }
                ?? images.map(\.aspect)
            let pages = CollectionPDFLayout.paginate(aspects: aspects, geometry: geo)
            let captionFont = CTFontCreateUIFontForLanguage(.system, captionFontSize, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, captionFontSize, nil)

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
                    drawHeader(title: title, count: count,
                               pillLayout: pillLayout, pillFont: pillFont,
                               in: ctx, pageSize: pageSize, margin: margin)
                }

                for pl in page.placements {
                    let img = images[pl.index].cg
                    // The placement rect is the whole tile (image + caption
                    // strip). Split off the caption strip from the bottom; the
                    // image occupies the rest.
                    let imageH = max(0, pl.rect.height - captionHeight)
                    let imageRect = CGRect(x: pl.rect.minX, y: pl.rect.minY,
                                           width: pl.rect.width, height: imageH)
                    // Flip top-left layout coords → PDF bottom-left.
                    let flipped = CGRect(
                        x: imageRect.origin.x,
                        y: pageSize.height - imageRect.origin.y - imageRect.height,
                        width: imageRect.width, height: imageRect.height)
                    let fit = aspectFit(imageW: CGFloat(img.width),
                                        imageH: CGFloat(img.height), in: flipped)
                    // Per-image backdrop (mirrors the grid tile fill). nil = no
                    // fill, so the white paper shows through (transparent). The
                    // image is drawn on top; for a fixed ratio it letterboxes
                    // over this fill, for masonry the image covers it (the fill
                    // shows only through transparent images).
                    if let tileBackdrop {
                        ctx.setFillColor(tileBackdrop)
                        ctx.fill(flipped)
                    }
                    ctx.draw(img, in: fit)

                    // Filename caption, centered under the image, truncated with
                    // an ellipsis so it never exceeds the image width or wraps.
                    let captionTop = imageRect.maxY + captionGap
                    let baselineY = pageSize.height - captionTop - captionFontSize
                    drawCaption(images[pl.index].name, font: captionFont,
                                in: ctx, x: pl.rect.minX, width: pl.rect.width,
                                baselineY: baselineY)
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

    /// Downsampled, orientation-corrected image thumbnail via ImageIO, or nil
    /// when the file isn't an ImageIO-decodable image (e.g. zip/pdf/doc).
    private static func imageIOThumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// The macOS type icon / content preview for a non-image file, via QuickLook
    /// (`.all` → same source as the grid's cards). Runs off the main thread.
    private static func quickLookThumbnail(_ url: URL, maxPixel: Int) async -> CGImage? {
        let size = CGSize(width: maxPixel, height: maxPixel)
        let req = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: 1, representationTypes: .all)
        let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req)
        return rep?.cgImage
    }

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

    /// One filename line, centered in `[x, x+width]` at `baselineY` (PDF
    /// bottom-left coords). End-truncated with an ellipsis via CoreText so it
    /// never exceeds the image's width and never wraps to a second line. Drawn
    /// with CoreText only (no AppKit) since this runs off the main thread.
    private static func drawCaption(_ name: String, font: CTFont, in ctx: CGContext,
                                    x: CGFloat, width: CGFloat, baselineY: CGFloat) {
        guard !name.isEmpty, width > 0 else { return }
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let attrs: [NSAttributedString.Key: Any] = [
            fontKey: font, colorKey: CGColor(gray: 0.45, alpha: 1)]
        let full = CTLineCreateWithAttributedString(
            NSAttributedString(string: name, attributes: attrs))
        // Ellipsis token in the same style; .end keeps the start of the name.
        let token = CTLineCreateWithAttributedString(
            NSAttributedString(string: "\u{2026}", attributes: attrs))
        let line = CTLineCreateTruncatedLine(full, Double(width), .end, token) ?? full
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let offset = max(0, (width - lineWidth) / 2)
        ctx.textPosition = CGPoint(x: x + offset, y: baselineY)
        CTLineDraw(line, ctx)
    }

    /// Largest rect with the image's aspect that fits inside `box`, centered.
    private static func aspectFit(imageW: CGFloat, imageH: CGFloat, in box: CGRect) -> CGRect {
        guard imageW > 0, imageH > 0, box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / imageW, box.height / imageH)
        let w = imageW * scale, h = imageH * scale
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

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
            // Clamp to the content width so an over-long single tag (the first
            // pill of a row never wraps) can't run off the page edge; drawPill
            // truncates the label to fit the clamped capsule.
            let w = min(pillWidth(label, font: font), maxWidth)
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
        let attrs: [NSAttributedString.Key: Any] = [
            fontKey: font, colorKey: CGColor(gray: 0, alpha: 1)]
        // Truncate to the clamped capsule's inner width (mirrors drawCaption) so
        // an over-long tag ends with an ellipsis instead of overrunning the pill.
        let full = CTLineCreateWithAttributedString(
            NSAttributedString(string: p.label, attributes: attrs))
        let token = CTLineCreateWithAttributedString(
            NSAttributedString(string: "\u{2026}", attributes: attrs))
        let innerWidth = max(0, p.width - pillPadH * 2)
        let line = CTLineCreateTruncatedLine(full, Double(innerWidth), .end, token) ?? full
        var ascent: CGFloat = 0, descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let baselineFromTop = p.topFromTop + (pillHeight - (ascent + descent)) / 2 + ascent
        ctx.textPosition = CGPoint(x: p.x + pillPadH, y: pageSize.height - baselineFromTop)
        CTLineDraw(line, ctx)
    }
}
