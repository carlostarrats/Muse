//
//  EffectiveDimensions.swift
//  Muse
//
//  The crop-aware layer above ImageHeaderSizeCache — "what the user SEES",
//  where the header cache answers "what the ORIGINAL file is".
//
//  ImageHeaderSizeCache remains the single orientation-applied truth for the
//  original bytes, and stays the direct read for DECODE BUDGETS and ANALYSIS
//  (both of which are properties of the file, not of the current edit). Layout
//  consumers — grid tile aspect, hero flight geometry, the Info card — call
//  THIS instead, so a Spec-04 crop is reflected everywhere without revisiting
//  each call site.
//
//  Identity function today: no edit-stack provider is installed, so every
//  answer is exactly ImageHeaderSizeCache's.
//

import Foundation
import CoreGraphics

nonisolated enum EffectiveDimensions {

    /// No I/O — safe to call from a SwiftUI view body (a header read here would
    /// be a file open per body pass, i.e. per frame of an animating flight).
    static func cached(_ url: URL) -> CGSize? {
        EditStackIndex.croppedSize(for: url) ?? ImageHeaderSizeCache.cached(url)
    }

    /// May perform a header read on a cache miss — off-main only.
    ///
    /// The header read comes FIRST, and the crop is asked for afterwards. That
    /// order is load-bearing: `EditStackIndex.croppedSize` scales the crop
    /// against `ImageHeaderSizeCache.cached`, a no-I/O lookup, so on a cold
    /// cache it answers nil and this would fall through to the ORIGINAL
    /// dimensions of a cropped file. Resolving first warms the very table the
    /// crop needs, so the second call can succeed. Both callers — the Info
    /// card's dimensions row and the hero flight's take-off rect — say in as
    /// many words that they want the post-crop size.
    static func resolve(_ url: URL) -> CGSize? {
        let original = ImageHeaderSizeCache.resolve(url)
        return EditStackIndex.croppedSize(for: url) ?? original
    }

    /// Width ÷ height of the drawn image. Prefers the no-I/O path and only
    /// falls back to a header read when nothing is cached.
    static func aspect(_ url: URL) -> CGFloat? {
        guard let size = cached(url) ?? resolve(url), size.height > 0 else { return nil }
        return size.width / size.height
    }
}
