//
//  ImageLayoutSheet.swift
//  Muse
//
//  Picks the global image layout (masonry default + fixed ratios). Styled to
//  match InfoSheet (same 600×720 frame, 24pt title, circular hover-X).
//  Selecting a tile sets the layout immediately — the grid re-lays-out live
//  behind the open sheet.
//

import SwiftUI

struct ImageLayoutSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var appState: AppState

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14),
                                count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Image Layout")
                    .font(.system(size: 24, weight: .semibold))
                Spacer()
                CloseButton { isPresented = false }
            }
            Text("Choose how images are arranged. Applies to every grid.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .padding(.bottom, 20)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(ImageLayout.allCases) { layout in
                            LayoutTile(
                                layout: layout,
                                isSelected: appState.imageLayout == layout,
                                tileFill: appState.moodPalette.tileFill
                            ) { appState.imageLayout = layout }
                        }
                    }
                    commonSizes
                }
                .padding(.bottom, 4)
            }
        }
        .padding(28)
        .frame(width: 600, height: 720)
    }

    // MARK: - Common Sizes

    private let sizes: [(String, String)] = [
        ("1:1", "Square medium format, iPhone"),
        ("2:3", "Sony, Canon, Nikon, 35mm film"),
        ("3:4", "iPhone, Google Pixel, Samsung Galaxy, OnePlus"),
        ("4:5", "Instagram, large format film"),
        ("6:7", "Medium format"),
        ("9:16", "Vertical video on most phones"),
    ]

    private var commonSizes: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Common Sizes")
                .font(.system(size: 15, weight: .semibold))
                .padding(.bottom, 16)
            ForEach(Array(sizes.enumerated()), id: \.offset) { idx, row in
                if idx > 0 { Divider().padding(.vertical, 12) }
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(row.0)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    Text(row.1)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Circular ✕, hover-brightening — identical to InfoSheet's. Esc also closes.
    private struct CloseButton: View {
        var action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.primary.opacity(hovering ? 0.16 : 0.08)))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
    }
}

/// One selectable layout tile. Mirrors a grid tile's selection exactly, but
/// blue-only: hovering darkens (veil); selecting shrinks the inner fill inward
/// (the gap reveals the sheet behind it), turns it blue, and draws the blue
/// ring at the outer edge. There is no intermediate pressed/darkened state.
private struct LayoutTile: View {
    let layout: ImageLayout
    let isSelected: Bool
    let tileFill: Color
    let onTap: () -> Void

    @State private var hovering = false

    // Match TileView's locked selection feel.
    private static let hoverVeilOpacity = 0.2
    private static let selectionInset: CGFloat = 10
    private static let ringWidth: CGFloat = 2.5
    private static let corner: CGFloat = 10

    private var blue: Color { Color.accentColor }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Inner fill: full-size grey when unselected; shrinks inward and
                // turns blue when selected (the inset gap shows the sheet behind).
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .fill(isSelected ? blue.opacity(0.18) : tileFill)
                    .padding(isSelected ? Self.selectionInset : 0)

                // Label + icon, shrinking with the fill when selected.
                VStack(spacing: 10) {
                    Text(layout.displayName)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isSelected ? blue : .primary)
                    LayoutIconView(kind: layout.iconKind,
                                   color: isSelected ? blue : .secondary)
                        .frame(width: 55, height: 55)
                }
                .padding(isSelected ? Self.selectionInset : 0)

                // Hover veil — unselected only; a calm dark wash, no resize.
                RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                    .fill(Color.black)
                    .opacity((hovering && !isSelected) ? Self.hoverVeilOpacity : 0)
                    .allowsHitTesting(false)

                // Ring at the outer edge when selected.
                if isSelected {
                    RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                        .strokeBorder(blue, lineWidth: Self.ringWidth)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.easeOut(duration: 0.15), value: isSelected)
        }
        // No pressed-state dimming — straight from hover to the blue selection.
        .buttonStyle(FlatButtonStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel("\(layout.displayName) layout")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A button style with no pressed appearance (the default plain style dims its
/// label on mouse-down, which read as a grey flash before the blue selection).
private struct FlatButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// One of the four generic preview graphics. All draw inside the same fixed
/// 55×55 frame and fill it, so the group reads as one consistent size while
/// each cell's shape still reflects the ratio (tall = portrait, wide =
/// landscape). Quick context for the ratio, not a literal preview.
private struct LayoutIconView: View {
    let kind: LayoutIconKind
    let color: Color

    private let gap: CGFloat = 3

    var body: some View {
        switch kind {
        case .square:    grid(cols: 3, rows: 3)
        case .portrait:  grid(cols: 4, rows: 3)
        case .landscape: grid(cols: 3, rows: 4)
        case .mason:     mason
        }
    }

    /// `cols × rows` cells that expand to fill the icon frame — so each cell's
    /// shape reflects the ratio (square / portrait / landscape).
    private func grid(cols: Int, rows: Int) -> some View {
        VStack(spacing: gap) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: gap) {
                    ForEach(0..<cols, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1.5).fill(color)
                    }
                }
            }
        }
    }

    /// The masonry pattern: 4 columns of staggered bar heights, filling the frame.
    private var mason: some View {
        GeometryReader { geo in
            let h = geo.size.height
            // Per-column relative bar heights (sum + gap ≈ frame height).
            let cols: [[CGFloat]] = [[0.53, 0.40], [0.30, 0.63], [0.63, 0.30], [0.40, 0.53]]
            HStack(spacing: gap) {
                ForEach(0..<cols.count, id: \.self) { c in
                    VStack(spacing: gap) {
                        ForEach(0..<cols[c].count, id: \.self) { r in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(color)
                                .frame(height: h * cols[c][r])
                        }
                    }
                }
            }
        }
    }
}
