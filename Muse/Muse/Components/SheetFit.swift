//
//  SheetFit.swift
//  Muse
//
//  Pure sizing math for window-fitted modal sheets. Kept out of the view
//  layer so it can be unit-tested (see SheetFitTests). Used by
//  `View.windowFittedSheetHeight` — see WindowFittedSheetHeight.swift.
//

import CoreGraphics

enum SheetFit {
    /// The height for a fixed-width sheet: its `ideal`, but never taller than
    /// the window it's presented over (`windowHeight` minus `margin`), and
    /// never below a usable `minHeight` floor.
    ///
    /// - `windowHeight == nil` means "not measured yet" → use `ideal` (matches
    ///   a plain fixed-frame sheet on first layout).
    /// - The `minHeight` floor wins over the window cap, so on a very short
    ///   window the sheet clamps to `min(ideal, minHeight)` rather than
    ///   collapsing to nothing.
    static func height(ideal: CGFloat,
                       windowHeight: CGFloat?,
                       minHeight: CGFloat,
                       margin: CGFloat) -> CGFloat {
        guard let windowHeight else { return ideal }
        let cap = max(minHeight, windowHeight - margin)
        return min(ideal, cap)
    }
}
