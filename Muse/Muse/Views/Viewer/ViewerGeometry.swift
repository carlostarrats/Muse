import Foundation

/// Pure geometry for the hero viewer. Constants mirror the approved prototype:
/// info column 258pt + 40pt margin, 40pt side pad, 86pt top, 60pt bottom.
enum ViewerGeometry {
    static let columnWidth: CGFloat = 258
    static let columnMargin: CGFloat = 40
    static let sidePad: CGFloat = 40
    /// Clears the Preview | Edit switch outright: it starts at `chromeTop` and
    /// is `chromeHeight` tall, so 70 is where it ENDS — a photo fitted to 70
    /// touches it, and a tall one appeared to slide underneath on open. 16pt of
    /// air past the switch; the image opens fractionally smaller for it.
    static let topPad: CGFloat = 86

    /// The y of the info column's chrome row (zoom pill / Fit / ✕), and of the
    /// Preview | Edit switch: the viewer's top line.
    /// = the right rail's 20pt top inset + the column's own 12pt card inset.
    static let chromeTop: CGFloat = 32
    /// The chrome row's height — the zoom pill's, which sets it.
    static let chromeHeight: CGFloat = 38
    /// The y of the info column's FIRST CARD (COLLECTION). The editor's panels
    /// start here too, so the two modes' cards sit on one line:
    ///   32 chromeTop + 38 chrome + 12 chrome bottom pad
    ///   + 14 stack spacing + 20 filename header + 14 stack spacing.
    static let cardsTop: CGFloat = 130
    static let bottomPad: CGFloat = 60
    static let maxZoom: CGFloat = 4
    /// A little headroom below Fit (1.0) so the image can be pulled back a
    /// touch — not an infinite zoom-out, just one or two steps of breathing room.
    static let minZoom: CGFloat = 0.7

    /// Centered in the true viewable space: between the left edge and the info column.
    static func fitRect(imageSize: CGSize, viewport: CGSize) -> CGRect {
        let usableRight = viewport.width - columnWidth - columnMargin
        let availW = max(120, usableRight - sidePad * 2)
        let availH = max(120, viewport.height - topPad - bottomPad)
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(x: sidePad, y: topPad, width: availW, height: availH)
        }
        let s = min(availW / imageSize.width, availH / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: sidePad + (availW - w) / 2,
                      y: topPad + (availH - h) / 2,
                      width: w, height: h)
    }

    /// Aspect-fit `imageSize` centered inside `frame` — where a grid tile
    /// actually DRAWS its image (tiles letterbox with .fit). The hero flight
    /// must start and land here, not on the raw tile rect: fixed-aspect grid
    /// layouts give the tile a different aspect than the image, so a flight
    /// to the tile rect lands as a center-crop that visibly re-fits the
    /// moment the real tile reveals (the grid-mode close glitch). In masonry
    /// the tile frame already matches the image aspect, so this returns the
    /// tile rect itself (within rounding) and nothing changes.
    static func fitWithin(imageSize: CGSize, frame: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              frame.width > 0, frame.height > 0 else { return frame }
        let s = min(frame.width / imageSize.width, frame.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: frame.midX - w / 2, y: frame.midY - h / 2,
                      width: w, height: h)
    }

    static func clampZoom(_ z: CGFloat) -> CGFloat { min(maxZoom, max(minZoom, z)) }

    static func clampPan(_ offset: CGSize, fittedSize: CGSize, zoom: CGFloat) -> CGSize {
        let maxX = max(0, (zoom - 1) * fittedSize.width / 2)
        let maxY = max(0, (zoom - 1) * fittedSize.height / 2)
        return CGSize(width: min(maxX, max(-maxX, offset.width)),
                      height: min(maxY, max(-maxY, offset.height)))
    }
}
