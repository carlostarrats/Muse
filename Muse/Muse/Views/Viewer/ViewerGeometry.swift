import Foundation

/// Pure geometry for the hero viewer. Constants mirror the approved prototype,
/// except the two side margins: info column 258pt + 28pt margin, 28pt side pad,
/// 86pt top, 60pt bottom.
///
/// The margins were the prototype's 40 until 2026-08-04 — cut by ~30% on owner
/// call, to hand the picture more of the window. Both modes read them, so one
/// change moves Preview's photo and column and the editor's two panels
/// together: `editorPanelWidth` is derived from `columnMargin`, so the panels
/// slide the same 12pt toward the window edges that the info column does.
enum ViewerGeometry {
    static let columnWidth: CGFloat = 258
    static let columnMargin: CGFloat = 28
    static let sidePad: CGFloat = 28
    /// Clears the Preview | Edit switch outright: it starts at `chromeTop` and
    /// is `chromeHeight` tall, so 70 is where it ENDS — a photo fitted to 70
    /// touches it, and a tall one appeared to slide underneath on open. 16pt of
    /// air past the switch; the image opens fractionally smaller for it.
    static let topPad: CGFloat = 86

    /// The y of the info column's chrome row (zoom pill / Fit / ✕), and of the
    /// Preview | Edit switch: the viewer's top line.
    /// The column carries it as content padding (`chromeTop − 12`) on top of
    /// its own 12pt card inset — see ViewerInfoColumn.
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

    /// One of the EDITOR's two panels, in points. Lives here rather than in
    /// `EditorView` because the window minimum below is derived from it — a
    /// private copy in the view is how the two silently disagreed.
    /// = 258 column + 24 card inset + (columnMargin − 12) margin + 20 stack spacing.
    static let editorPanelWidth: CGFloat = columnWidth + 24 + (columnMargin - 12) + 20

    /// The narrowest the main window may get.
    ///
    /// Derived from the EDITOR, which is the more demanding of the two modes
    /// that share this window: Preview has ONE 258pt info column, Edit has TWO
    /// `editorPanelWidth` panels. Sizing this from Preview alone (the first
    /// version of this constant) left the editor 60pt of picture at the
    /// minimum — technically laid out, useless to edit in. Both panels plus a
    /// picture at least as wide as one info column is the floor.
    ///
    /// It exists because the window had NO minimum at all, so it could be
    /// dragged narrower than the info column and the photo drew ON TOP of it
    /// (owner report).
    static let minWindowWidth: CGFloat = editorPanelWidth * 2 + columnWidth
    /// Enough for the chrome row, a card or two, and a picture between them.
    static let minWindowHeight: CGFloat = 480

    /// The hero overlay's own coordinate space.
    ///
    /// Exists so the EDITOR can report where it is drawing the photo in the
    /// space the hero's flight works in, without either side going through
    /// `.global`. Global coordinates looked equivalent and are not: the editor
    /// reports its rect when the CONTENT changes, and dragging the window by
    /// its title bar moves the global origin while the content rect stands
    /// still — so a close after a window move would take off from where the
    /// window used to be.
    static let overlaySpace = "museHeroOverlay"

    /// Centered in the true viewable space: between the left edge and the info column.
    static func fitRect(imageSize: CGSize, viewport: CGSize) -> CGRect {
        let usableRight = viewport.width - columnWidth - columnMargin
        // The box is derived from the space that actually EXISTS, both edges
        // clamped to it. It used to be `max(120, usableRight - sidePad * 2)`
        // at a fixed x of `sidePad`, which on a window narrower than ~378pt
        // produced a 120pt-wide rect starting at x=40 — straight through the
        // info column's left edge (owner report: "the image looks like it can
        // go over the UI"). `minWindowWidth` means neither clamp binds in
        // practice; they stay as the guarantee that no viewport, at any
        // aspect, can produce an overlapping rect.
        let left = min(sidePad, max(0, usableRight))
        let right = max(left, usableRight - sidePad)
        let availW = right - left
        let availH = max(120, viewport.height - topPad - bottomPad)
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(x: left, y: topPad, width: availW, height: availH)
        }
        let s = min(availW / imageSize.width, availH / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: left + (availW - w) / 2,
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
