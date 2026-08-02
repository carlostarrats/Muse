//
//  HistogramView.swift
//  Muse
//
//  The teaching histogram: three channel paths composited with `.screen`
//  (additive overlap is what makes single-channel clipping visible as a colour
//  rather than a shape), an optional luminance line, and drag-to-adjust —
//  left third moves Blacks, right third Exposure, middle inert.
//
//  The drag is a convenience, not the only path: the Light tab's sliders are
//  the accessible equivalent, so this needs no parallel accessibility action.
//

import SwiftUI
import AppKit

struct HistogramView: View {
    let stats: EditStats?
    let showLuminance: Bool
    @ObservedObject var session: EditSession

    @Environment(\.theme) private var theme
    /// Drag deltas are cumulative, so each frame's contribution is the
    /// difference from the last — a per-instance @State, never a shared one.
    @State private var lastTranslation: CGFloat = 0

    static let histogramHeight: CGFloat = 96
    private static let dragEVPerPoint = 0.01
    private static let dragBlacksPerPoint = 0.004

    /// Channels lighten onto a dark card and darken onto a light one — either
    /// way they stay visible instead of dissolving into the surface.
    private var channelBlend: BlendMode { theme.panelInkIsDark ? .multiply : .screen }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: theme.radius, style: .continuous)
                    .fill(theme.panelFill)
                if let stats {
                    channelPath(stats.histogram.r, in: geo.size)
                        .fill(Color.red.opacity(0.55)).blendMode(channelBlend)
                    channelPath(stats.histogram.g, in: geo.size)
                        .fill(Color.green.opacity(0.55)).blendMode(channelBlend)
                    channelPath(stats.histogram.b, in: geo.size)
                        .fill(Color.blue.opacity(0.55)).blendMode(channelBlend)
                    if showLuminance {
                        channelStroke(stats.histogram.luma, in: geo.size)
                            .stroke(theme.controlAccent, lineWidth: 1)
                    }
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in handleDrag(value, width: geo.size.width) }
                    .onEnded { _ in
                        lastTranslation = 0
                        session.commitGesture()
                    }
            )
        }
        .frame(height: Self.histogramHeight)
        .accessibilityLabel(Text("Histogram"))
    }

    private func channelPath(_ bins: [Float], in size: CGSize) -> Path {
        Path { path in
            guard !bins.isEmpty else { return }
            let stepX = size.width / CGFloat(bins.count - 1)
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in bins.enumerated() {
                path.addLine(to: CGPoint(x: CGFloat(i) * stepX,
                                         y: size.height * (1 - CGFloat(v))))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        }
    }

    private func channelStroke(_ bins: [Float], in size: CGSize) -> Path {
        Path { path in
            guard !bins.isEmpty else { return }
            let stepX = size.width / CGFloat(bins.count - 1)
            for (i, v) in bins.enumerated() {
                let point = CGPoint(x: CGFloat(i) * stepX, y: size.height * (1 - CGFloat(v)))
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }

    private func handleDrag(_ value: DragGesture.Value, width: CGFloat) {
        let startThird = value.startLocation.x / max(width, 1)
        let dx = Double(value.translation.width - lastTranslation)
        lastTranslation = value.translation.width
        if startThird < 1.0 / 3.0 {
            session.draft.setTone {
                $0.blacks = min(max($0.blacks + dx * Self.dragBlacksPerPoint, -1), 1)
            }
        } else if startThird > 2.0 / 3.0 {
            session.draft.setTone {
                $0.exposureEV = min(max($0.exposureEV + dx * Self.dragEVPerPoint,
                                        ToneParams.exposureRange.lowerBound),
                                    ToneParams.exposureRange.upperBound)
            }
        }
        // Middle third: inert. Dragging the midtones would be ambiguous
        // (contrast? brightness?), and guessing wrong is worse than doing
        // nothing.
    }
}
