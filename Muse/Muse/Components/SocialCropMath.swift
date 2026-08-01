//
//  SocialCropMath.swift
//  Muse
//
//  Pure crop-rect math for the social export crop stage. CoreGraphics only —
//  no AppKit (the Components/ pure-UI-math convention).
//

import CoreGraphics

/// How a source image is fitted into a fixed-dimension frame. Crop is the
/// default; matte is the culturally dominant "no crop" look; blur-extend fills
/// the surround with a blown-up blur of the picture itself.
enum SocialFit: String { case crop, matte, blurExtend }

enum MatteShade: String { case white, black }

enum SocialCropMath {
    static let zoomRange: ClosedRange<CGFloat> = 1...4

    /// The normalized source-crop rect (unit coords, display-oriented) for a
    /// target aspect at a zoom/center chosen in the crop UI. zoom 1 = the
    /// minimal crop that fills the target frame (aspect-fill); zoom z > 1
    /// magnifies. The center is clamped so the rect never leaves the unit
    /// square, and degenerate inputs return the full frame rather than NaN.
    static func rect(sourceSize: CGSize, targetAspect: CGFloat,
                     zoom: CGFloat, center: CGPoint) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0,
              targetAspect > 0, targetAspect.isFinite else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let sourceAspect = sourceSize.width / sourceSize.height
        let clampedZoom = max(zoomRange.lowerBound, min(zoomRange.upperBound, zoom))

        var w: CGFloat
        var h: CGFloat
        if sourceAspect > targetAspect {
            // Source is relatively wider than the target — crop width.
            h = 1
            w = targetAspect / sourceAspect
        } else {
            w = 1
            h = sourceAspect / targetAspect
        }
        // zoom > 1 shrinks the visible rect (i.e. magnifies the image).
        w /= clampedZoom
        h /= clampedZoom

        let cx = max(0, min(1, center.x))
        let cy = max(0, min(1, center.y))
        var x = cx - w / 2
        var y = cy - h / 2
        x = max(0, min(1 - w, x))
        y = max(0, min(1 - h, y))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// "Save Crop as Version": compose the social rect into the photo's existing
    /// crop. The social rect is chosen in POST-geometry display space, so it maps
    /// proportionally INSIDE whatever crop the edit stack already has.
    static func composedCrop(existing: CGRect?, social: CGRect) -> CGRect {
        guard let existing else { return social }
        return CGRect(
            x: existing.minX + social.minX * existing.width,
            y: existing.minY + social.minY * existing.height,
            width: social.width * existing.width,
            height: social.height * existing.height)
    }
}
