import Foundation

/// No-reflow pill hover math, ported from the approved HTML prototype.
/// All inputs are NATURAL widths (measured once); never live geometry.
enum PillRowModel {
    /// Greedy row assignment by natural widths.
    static func rows(naturals: [CGFloat], container: CGFloat, gap: CGFloat) -> [Int] {
        var out: [Int] = []
        var row = 0, used: CGFloat = 0
        for (i, w) in naturals.enumerated() {
            let add = (used == 0 ? w : used + gap + w)
            if used > 0 && add > container { row += 1; used = w }
            else { used = add }
            out.append(row)
            _ = i
        }
        return out
    }

    /// Width of every pill given a hover. Invariants: pills before the hovered
    /// one (and other rows) keep natural width; the hovered pill grows by
    /// `grow` (stealing end-of-row slack first, then shrinking FOLLOWING
    /// same-row pills down to `floor`, then truncating itself); a row's total
    /// width never exceeds `container`.
    static func widths(naturals: [CGFloat], container: CGFloat, gap: CGFloat,
                       hovered: Int?, grow: CGFloat, floor: CGFloat,
                       buffer: CGFloat = 3) -> [CGFloat] {
        var out = naturals
        guard let h = hovered, naturals.indices.contains(h) else { return out }
        let assignment = rows(naturals: naturals, container: container, gap: gap)
        let myRow = assignment[h]
        let rowIdx = naturals.indices.filter { assignment[$0] == myRow }
        let rowW = rowIdx.reduce(CGFloat(0)) { $0 + naturals[$1] } + gap * CGFloat(rowIdx.count - 1)
        let slack = container - rowW
        var deficit = max(0, grow - slack + buffer)
        var grown = grow
        for i in rowIdx where i > h {
            guard deficit > 0 else { break }
            let take = min(deficit, max(0, naturals[i] - floor))
            out[i] = naturals[i] - take
            deficit -= take
        }
        if deficit > 0 { grown -= deficit }   // self-truncate remainder
        out[h] = naturals[h] + grown
        return out
    }
}
