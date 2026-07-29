//
//  CollectionIconView.swift
//  Muse
//
//  Draws a collection's icon — an SF Symbol or an emoji — in the shared 18pt
//  sidebar icon slot. One view for every surface (sidebar row, Collections
//  page card, the Symbol & Color modal's live preview and its grid cells) so
//  the two icon kinds can't end up sized or aligned differently in one place
//  and not another.
//

import SwiftUI

struct CollectionIconView: View {
    let icon: CollectionAppearance.Icon
    /// Point size of the SF Symbol. An emoji draws slightly larger — see below.
    var size: CGFloat = 12
    /// Tint for the SYMBOL form. Ignored for an emoji, which carries its own
    /// colors; forcing a tint onto one either does nothing or flattens it.
    var tint: AnyShapeStyle = AnyShapeStyle(.primary)
    /// Width of the icon slot. The default matches the sidebar's shared column.
    var slotWidth: CGFloat = 18

    /// An emoji is drawn by the color-glyph font and reads optically SMALLER
    /// than a semibold SF Symbol at the same point size, so it's nudged up to
    /// keep the two visually equal weight in a row.
    static let emojiSizeBoost: CGFloat = 2

    var body: some View {
        Group {
            switch icon {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(tint)
            case .emoji(let emoji):
                Text(emoji)
                    .font(.system(size: size + Self.emojiSizeBoost))
            }
        }
        .frame(width: slotWidth)
    }
}
