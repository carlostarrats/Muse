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
import Foundation

enum CollectionPDFExporter {

    /// Build the PDF for `urls` (image files, in display order). `count` is the
    /// number shown beside the title. `columns` mirrors the grid density.
    /// Returns a temp-file URL, or nil if nothing could be rendered.
    static func makePDF(urls: [URL], title: String, count: Int, columns: Int,
                        layoutAspect: CGFloat?, tileBackdrop: CGColor?) async -> URL? {
        await Task.detached(priority: .userInitiated) { () -> URL? in
            let pageSize = CGSize(width: 792, height: 1008)   // 11x14in @ 72dpi
            let margin: CGFloat = 36
            let gutter: CGFloat = 12
            let headerHeight: CGFloat = 46
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

            // Load downsampled, orientation-corrected images + their aspect +
            // filename (drawn as a caption under each image).
            var images: [(cg: CGImage, aspect: CGFloat, name: String)] = []
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
                images.append((cg, h / w, url.lastPathComponent))
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
                    drawHeader(title: title, count: count, in: ctx,
                               pageSize: pageSize, margin: margin)
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

    /// "Title  count" at 24pt, top-left of the content box. PDF (bottom-left)
    /// coordinates: text baseline sits 24pt below the top margin. Built with
    /// CoreText (CTFont/CGColor) only — no AppKit — since this runs off the
    /// main thread inside the detached export task.
    private static func drawHeader(title: String, count: Int, in ctx: CGContext,
                                   pageSize: CGSize, margin: CGFloat) {
        let base = CTFontCreateUIFontForLanguage(.system, 24, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let font = CTFontCreateCopyWithSymbolicTraits(base, 24, nil, .traitBold, .traitBold) ?? base
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let attr = NSMutableAttributedString(
            string: title,
            attributes: [fontKey: font, colorKey: CGColor(gray: 0, alpha: 1)])
        attr.append(NSAttributedString(
            string: "  \(count)",
            attributes: [fontKey: font, colorKey: CGColor(gray: 0.5, alpha: 1)]))
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: margin, y: pageSize.height - margin - 24)
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
}
