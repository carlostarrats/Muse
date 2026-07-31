//
//  RegionMath.swift
//  Muse
//
//  The on-screen rect the image currently occupies, and marquee → unit image
//  coordinates. Mirrors exactly the transform stack HeroStage renders
//  (scaleEffect(zoom) → offset(pan) over the fitted rect).
//

import CoreGraphics

nonisolated enum RegionMath {
    static func imageFrame(fitRect: CGRect, zoom: CGFloat, pan: CGSize) -> CGRect {
        let scaledWidth = fitRect.width * zoom
        let scaledHeight = fitRect.height * zoom
        return CGRect(x: fitRect.midX - scaledWidth / 2 + pan.width,
                      y: fitRect.midY - scaledHeight / 2 + pan.height,
                      width: scaledWidth, height: scaledHeight)
    }

    /// Marquee intersected with `imageFrame`, normalized to unit image
    /// coordinates (top-left origin). nil when degenerate or disjoint.
    static func normalizedRegion(marquee: CGRect, imageFrame: CGRect) -> CGRect? {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return nil }
        let intersection = marquee.intersection(imageFrame)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return nil }
        return CGRect(x: (intersection.origin.x - imageFrame.origin.x) / imageFrame.width,
                      y: (intersection.origin.y - imageFrame.origin.y) / imageFrame.height,
                      width: intersection.width / imageFrame.width,
                      height: intersection.height / imageFrame.height)
    }
}
