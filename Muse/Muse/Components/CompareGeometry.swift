//
//  CompareGeometry.swift
//  Muse
//
//  Pure synchronized zoom/pan math for side-by-side compare. The center is
//  NORMALIZED (unit image coordinates, not points) — that's what keeps a
//  portrait pane and a landscape pane looking at the same subject region
//  under one shared (zoom, center) pair.
//

import CoreGraphics

nonisolated enum CompareGeometry {
    static let zoomRange: ClosedRange<CGFloat> = 1...8

    /// Where `imageSize` draws inside `paneSize` at the shared (zoom, center):
    /// fit the image, then scale about the normalized center point.
    static func drawRect(imageSize: CGSize, paneSize: CGSize,
                         zoom: CGFloat, center: CGPoint) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              paneSize.width > 0, paneSize.height > 0 else { return .zero }

        let fitScale = min(paneSize.width / imageSize.width, paneSize.height / imageSize.height)
        let scaledSize = CGSize(width: imageSize.width * fitScale * zoom,
                                height: imageSize.height * fitScale * zoom)

        // The point in the SCALED image that must land at the pane's center.
        let originX = paneSize.width / 2 - scaledSize.width * center.x
        let originY = paneSize.height / 2 - scaledSize.height * center.y

        return CGRect(x: originX, y: originY, width: scaledSize.width, height: scaledSize.height)
    }

    /// Clamp so the image never pans fully out of the pane; at zoom 1 there's
    /// no room to pan at all, so it collapses to dead center.
    static func clampCenter(_ c: CGPoint, zoom: CGFloat) -> CGPoint {
        guard zoom > 1 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(max(c.x, 0), 1), y: min(max(c.y, 0), 1))
    }
}
