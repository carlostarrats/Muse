//
//  WorkingImage.swift
//  Muse
//
//  Type safety around the one crossing that a colour pipeline gets wrong most
//  often: display/file-referred pixels vs linear working-space pixels. Ported
//  from Surface Camera's `WorkingSpaceImage.swift`, and the bug it exists to
//  prevent travels with it:
//
//  Core Image applies the file's transfer function on LOAD. Applying a gamma
//  decode again — the obvious-looking "convert sRGB to linear" step — squares
//  it, and the image renders roughly 2.3× too dark. It looks like an exposure
//  bug, so the instinct is to add a compensating gain somewhere downstream,
//  and then every adjustment after it is subtly wrong.
//
//  The fix is structural rather than careful: adjustment methods exist ONLY on
//  `LinearImage`, so an encoded image cannot be adjusted at all, and the only
//  way to get a `LinearImage` is one of the two constructors below. There is
//  no third path to forget about.
//

import CoreImage

/// A `CIImage` known to be display/file-referred (transfer function applied).
struct EncodedImage {
    let ciImage: CIImage

    init(_ ciImage: CIImage) { self.ciImage = ciImage }

    /// The single sanctioned crossing into working space.
    func toLinearWorkingSpace() -> LinearImage {
        guard let working = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
            return LinearImage(ciImage)
        }
        return LinearImage(ciImage.matchedToWorkingSpace(from: working) ?? ciImage)
    }
}

/// A `CIImage` known to be linear working-space — un-clamped, scene-referred.
/// Highlight data above 1.0 survives here, which is what makes highlight
/// recovery (a negative exposure pulling detail back out of a blown sky)
/// actually work rather than just darkening flat white.
// `nonisolated`: the render chain's working image, built entirely off-main.
nonisolated struct LinearImage {
    let ciImage: CIImage

    init(_ ciImage: CIImage) { self.ciImage = ciImage }

    /// For sources Core Image already decoded INTO working space —
    /// `CIImage(contentsOf:)` and `CIRAWFilter.outputImage`. Re-deriving these
    /// through `EncodedImage.toLinearWorkingSpace()` would double-transform.
    nonisolated static func alreadyDecodedFromFile(_ image: CIImage) -> LinearImage {
        LinearImage(image)
    }

    func oriented(forExifOrientation orientation: Int32) -> LinearImage {
        LinearImage(ciImage.oriented(forExifOrientation: orientation))
    }

    func map(_ transform: (CIImage) -> CIImage) -> LinearImage {
        LinearImage(transform(ciImage))
    }
}
