//
//  PillFlow.swift
//  Muse
//
//  Wrapping pill layout with the no-reflow hover behavior, plus the
//  HoverPill view it lays out. Width math lives in PillRowModel; this
//  file only measures naturals and places. The PARENT owns the hovered
//  index and wraps it in .animation(.easeOut(duration: 0.18), value:)
//  so width changes animate without rows ever reflowing.
//

import SwiftUI

/// Wrapping pill rows with the no-reflow hover behavior. Children must be
/// HoverPill so natural widths are stable; widths come from PillRowModel.
struct PillFlow: Layout {
    var gap: CGFloat = 6
    var hovered: Int?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let container = proposal.width ?? 230
        let naturals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let rows = PillRowModel.rows(naturals: naturals, container: container, gap: gap)
        let rowCount = (rows.max() ?? -1) + 1
        let h = subviews.first?.sizeThatFits(.unspecified).height ?? 22
        return CGSize(width: container,
                      height: CGFloat(rowCount) * h + CGFloat(max(0, rowCount - 1)) * gap)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let container = bounds.width
        let naturals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let rows = PillRowModel.rows(naturals: naturals, container: container, gap: gap)
        let widths = PillRowModel.widths(naturals: naturals, container: container, gap: gap,
                                         hovered: hovered, grow: 17, floor: 26)
        let h = subviews.first?.sizeThatFits(.unspecified).height ?? 22
        var x = bounds.minX, y = bounds.minY, row = 0
        for (i, sub) in subviews.enumerated() {
            if rows[i] != row { row = rows[i]; x = bounds.minX; y = bounds.minY + CGFloat(row) * (h + gap) }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: widths[i], height: h))
            x += widths[i] + gap
        }
    }
}

/// One pill inside a PillFlow. Its natural width NEVER depends on hover —
/// the ✕ circle is an overlay revealed inside the grown width that PillFlow
/// proposes, so PillRowModel's naturals stay stable at every frame.
struct HoverPill: View {
    let index: Int
    let label: String
    let isHovered: Bool
    var onHover: (Int, Bool) -> Void
    var onTap: () -> Void
    var onRemove: () -> Void

    @State private var removeHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(isHovered ? 0.26 : 0.12))
        )
        .overlay(alignment: .trailing) {
            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white.opacity(removeHovered ? 1.0 : 0.75))
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(.white.opacity(removeHovered ? 0.32 : 0.14)))
                }
                .buttonStyle(.plain)
                .onHover { removeHovered = $0 }
                .padding(.trailing, 4)
                .transition(.opacity)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: onTap)
        .onHover { inside in
            if !inside { removeHovered = false }
            onHover(index, inside)
        }
    }
}
