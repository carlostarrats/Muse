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
