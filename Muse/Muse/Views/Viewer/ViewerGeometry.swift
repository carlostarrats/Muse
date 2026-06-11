import Foundation

/// Pure geometry for the hero viewer. Constants mirror the approved prototype:
/// info column 258pt + 40pt margin, 40pt side pad, 70pt top, 60pt bottom.
enum ViewerGeometry {
    static let columnWidth: CGFloat = 258
    static let columnMargin: CGFloat = 40
    static let sidePad: CGFloat = 40
    static let topPad: CGFloat = 70
    static let bottomPad: CGFloat = 60
    static let maxZoom: CGFloat = 4
    static let minZoom: CGFloat = 1

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

    static func clampZoom(_ z: CGFloat) -> CGFloat { min(maxZoom, max(minZoom, z)) }

    static func clampPan(_ offset: CGSize, fittedSize: CGSize, zoom: CGFloat) -> CGSize {
        let maxX = max(0, (zoom - 1) * fittedSize.width / 2)
        let maxY = max(0, (zoom - 1) * fittedSize.height / 2)
        return CGSize(width: min(maxX, max(-maxX, offset.width)),
                      height: min(maxY, max(-maxY, offset.height)))
    }
}
