//
//  PeakingOverlay.swift
//  Muse
//
//  Ported from Surface Camera's `App/Rendering/PeakingOverlay.swift` (read in
//  full). The chain is verbatim — high-pass magnitude via
//  `CIColorAbsoluteDifference` against a small Gaussian, then
//  `CIColorThreshold` → `CIMaskToAlpha` → `CISourceInCompositing` against a
//  solid accent fill. Two deliberate adaptations from the source:
//
//  1. The `CILinearToSRGBToneCurve` pre-encode is DROPPED. Surface's input is
//     a linear-TAGGED render, and its own doc note is emphatic that the edge
//     source must be display-referred. Muse's input is a decoded CGImage,
//     which is ALREADY display-referred — re-encoding would double-apply the
//     curve and shift the tuned `edgeThreshold`. Don't "restore" it.
//  2. The chain runs at a normalized 1080px working size. Surface's constants
//     were tuned against its ~1080px preview feed and `highPassRadius` is a
//     pixel-scale quantity — running at 4096px would silently retune both
//     the radius and the threshold.
//
//  Returns the tinted-edge layer ALONE (transparent everywhere else), so the
//  caller composites it as a SwiftUI overlay rather than this file having to
//  know what it's drawn over.
//

import CoreImage

nonisolated enum PeakingOverlay {
    /// `CIColorThreshold`'s cutoff on the high-pass magnitude. Surface's
    /// device-tuned value; a sharp step edge of display contrast Δ produces
    /// ~Δ/2 at the edge, so this marks isolated edges down to ~0.06 contrast
    /// while a defocused copy of the same edge measures ~0.
    static let edgeThreshold = 0.03
    /// Radius of the small Gaussian whose difference from the source IS the
    /// edge signal. Detail finer than ~this many pixels survives; anything
    /// smoother cancels to zero.
    static let highPassRadius = 1.5
    /// Convolution clamps at the boundary, which can leave a spurious bright
    /// band along the frame edge.
    static let boundaryInset: CGFloat = 3
    static let workingLongEdge: CGFloat = 1080

    static func render(_ source: CIImage, accent: CIColor) -> CIImage? {
        let extent = source.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return nil }

        let longEdge = max(extent.width, extent.height)
        let scale = longEdge > workingLongEdge ? workingLongEdge / longEdge : 1.0
        let working = source
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(x: 0, y: 0,
                                width: (extent.width * scale).rounded(.down),
                                height: (extent.height * scale).rounded(.down)))
        guard working.extent.width > 1, working.extent.height > 1 else { return nil }

        let smoothed = working.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: highPassRadius])
            .cropped(to: working.extent)
        let highPass = working.applyingFilter(
            "CIColorAbsoluteDifference", parameters: ["inputImage2": smoothed])
        let thresholded = highPass.applyingFilter(
            "CIColorThreshold", parameters: ["inputThreshold": edgeThreshold])
        let alphaMask = thresholded.applyingFilter("CIMaskToAlpha")

        let accentFill = CIImage(color: accent).cropped(to: alphaMask.extent)
        let tintedEdges = accentFill.applyingFilter(
            "CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: alphaMask])

        // Inset in WORKING space (the band is a working-space artifact), then
        // scale back onto the caller's rect.
        let inset = tintedEdges.cropped(
            to: working.extent.insetBy(dx: boundaryInset, dy: boundaryInset))
        let backScale = scale > 0 ? 1 / scale : 1
        let restored = inset
            .transformed(by: CGAffineTransform(scaleX: backScale, y: backScale))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)

        // Composite over a fully transparent field so the result's extent is
        // exactly the caller's, regardless of the inset.
        return restored.composited(over: CIImage(color: CIColor.clear).cropped(to: extent))
    }
}
