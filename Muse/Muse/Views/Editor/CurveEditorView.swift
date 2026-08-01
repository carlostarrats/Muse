//
//  CurveEditorView.swift
//  Muse
//
//  A point curve over a unit square. Click to add, drag to move, double-click
//  to remove.
//
//  Monotonicity is enforced by CONSTRUCTION rather than by validation: a
//  point's x is clamped between its neighbours, so points can never cross and
//  the spline never has to cope with an out-of-order input.
//
//  `histogram` is the seam Spec 05 fills. Spec 04 always passes nil — the
//  parameter exists now so adding the histogram later isn't an API change to
//  every call site.
//

import SwiftUI

struct CurveHistogram: Equatable {
    /// 64 luminance bins, each 0…1, drawn as a silent backdrop.
    let bins: [Float]
}

struct CurveEditorView: View {
    @Binding var points: [CurveParams.Point]
    var histogram: CurveHistogram?
    let onCommit: () -> Void

    @Environment(\.theme) private var theme
    @State private var draggingIndex: Int?

    /// How close (in unit coordinates) a click has to be to grab an existing
    /// point rather than create a new one.
    private static let grabRadius = 0.04

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.15))
                if let histogram { histogramBackdrop(histogram, size: geo.size) }
                gridLines(size: geo.size)
                curvePath(size: geo.size)
                ForEach(points.indices, id: \.self) { i in
                    Circle()
                        .fill(theme.controlAccent)
                        .frame(width: 7, height: 7)
                        .position(x: CGFloat(points[i].x) * geo.size.width,
                                  y: CGFloat(1 - points[i].y) * geo.size.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { addOrMove($0.location, size: geo.size) }
                    .onEnded { _ in
                        draggingIndex = nil
                        onCommit()
                    }
            )
            .onTapGesture(count: 2) { location in
                removePoint(near: location, size: geo.size)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(Rectangle().stroke(theme.panelStroke))
        .accessibilityLabel(Text("Tone curve"))
        .accessibilityValue(Text(String(format: NSLocalizedString(
            "%lld curve points", comment: "VoiceOver: number of tone-curve points"),
                                        points.count)))
        .accessibilityAction(named: Text("Reset Curve")) {
            points = []
            onCommit()
        }
    }

    // MARK: - Drawing

    private func gridLines(size: CGSize) -> some View {
        Path { path in
            for i in 1..<4 {
                let f = CGFloat(i) / 4
                path.move(to: CGPoint(x: f * size.width, y: 0))
                path.addLine(to: CGPoint(x: f * size.width, y: size.height))
                path.move(to: CGPoint(x: 0, y: f * size.height))
                path.addLine(to: CGPoint(x: size.width, y: f * size.height))
            }
        }
        .stroke(theme.panelStroke.opacity(0.4), lineWidth: 0.5)
    }

    private func curvePath(size: CGSize) -> some View {
        // Drawn from the SAME LUT the renderer uses, so what the user sees is
        // what the pixels get — a separately-drawn bezier would look right and
        // render differently.
        let lut = CurveLUT.build(points: points)
        return Path { path in
            for (i, v) in lut.enumerated() {
                let x = CGFloat(i) / CGFloat(lut.count - 1) * size.width
                let y = (1 - CGFloat(v)) * size.height
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
        .stroke(theme.controlAccent, lineWidth: 1.5)
    }

    private func histogramBackdrop(_ histogram: CurveHistogram, size: CGSize) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(histogram.bins.indices, id: \.self) { i in
                Rectangle()
                    .fill(theme.textSecondary.opacity(0.15))
                    .frame(width: size.width / CGFloat(max(histogram.bins.count, 1)),
                           height: CGFloat(histogram.bins[i]) * size.height)
            }
        }
    }

    // MARK: - Editing

    private func addOrMove(_ location: CGPoint, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let x = Double(min(max(location.x / size.width, 0), 1))
        let y = Double(min(max(1 - location.y / size.height, 0), 1))

        if let index = draggingIndex {
            move(index: index, toX: x, y: y)
            return
        }
        if let nearest = nearestIndex(toX: x) {
            draggingIndex = nearest
            move(index: nearest, toX: x, y: y)
            return
        }
        guard points.count < CurveParams.maxPoints else { return }
        points.append(CurveParams.Point(x: x, y: y))
        points.sort { $0.x < $1.x }
        draggingIndex = points.firstIndex { $0.x == x && $0.y == y }
    }

    /// Clamping x between the neighbours is what makes crossing — and
    /// therefore a non-monotone curve — unrepresentable.
    private func move(index: Int, toX x: Double, y: Double) {
        guard points.indices.contains(index) else { return }
        let lower = index > 0 ? points[index - 1].x + 0.001 : 0
        let upper = index < points.count - 1 ? points[index + 1].x - 0.001 : 1
        points[index] = CurveParams.Point(x: min(max(x, lower), max(lower, upper)), y: y)
    }

    private func nearestIndex(toX x: Double) -> Int? {
        points.indices.min { abs(points[$0].x - x) < abs(points[$1].x - x) }
            .flatMap { abs(points[$0].x - x) < Self.grabRadius ? $0 : nil }
    }

    private func removePoint(near location: CGPoint, size: CGSize) {
        guard size.width > 0 else { return }
        let x = Double(location.x / size.width)
        guard let index = nearestIndex(toX: x) else { return }
        points.remove(at: index)
        onCommit()
    }
}
