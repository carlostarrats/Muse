//
//  ImageLayoutSheet.swift
//  Muse
//
//  Picks the global image layout (masonry default + fixed ratios). Styled to
//  match InfoSheet (24pt title, circular hover-X). Selecting a tile sets the
//  layout immediately — the grid re-lays-out live behind the open sheet.
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
            Text("Select an image layout. Applies globally")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .padding(.bottom, 20)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
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
        .frame(width: 640, height: 860)
    }

    // MARK: - Common Sizes

    private let sizes: [(String, String)] = [
        ("1:1", "Square medium format, iPhone"),
        ("2:3", "Sony, Canon, Nikon, 35mm film"),
        ("3:4", "iPhone, Google Pixel, Samsung Galaxy, OnePlus"),
        ("4:5", "Instagram, Large format film"),
        ("6:7", "Medium format"),
        ("9:16", "Video on most phones with camera support also"),
    ]

    private var commonSizes: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Common Sizes:")
                .font(.system(size: 15, weight: .semibold))
                .padding(.bottom, 6)
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

/// One selectable layout tile. Mirrors the grid tile's selection feel but is
/// blue-only (the modal's single color change): selected → blue tint fill, blue
/// ring (8pt continuous corners), blue label, inset content; unselected → grey
/// tileFill box with a hover veil.
private struct LayoutTile: View {
    let layout: ImageLayout
    let isSelected: Bool
    let tileFill: Color
    let onTap: () -> Void

    @State private var hovering = false

    // Match TileView's locked selection constants.
    private static let hoverVeilOpacity = 0.2
    private static let selectionInset: CGFloat = 8
    private static let ringWidth: CGFloat = 2.5
    private static let ringCornerRadius: CGFloat = 8
    private static let selectionTintOpacity = 0.18

    private var blue: Color { Color.accentColor }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                Text(layout.displayName)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isSelected ? blue : .primary)
                LayoutIconView(kind: layout.iconKind,
                               color: isSelected ? blue : .secondary)
                    .frame(width: 56, height: 48)
            }
            .padding(isSelected ? Self.selectionInset : 0)
            .frame(maxWidth: .infinity)
            .frame(height: 132)
            .background(
                RoundedRectangle(cornerRadius: Self.ringCornerRadius, style: .continuous)
                    .fill(isSelected ? blue.opacity(Self.selectionTintOpacity) : tileFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.ringCornerRadius, style: .continuous)
                    .fill(Color.black)
                    .opacity((hovering && !isSelected) ? Self.hoverVeilOpacity : 0)
                    .allowsHitTesting(false)
            )
            .overlay(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Self.ringCornerRadius, style: .continuous)
                            .strokeBorder(blue, lineWidth: Self.ringWidth)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: Self.ringCornerRadius, style: .continuous))
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.easeOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(layout.displayName) layout")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// One of the four generic preview graphics, drawn from simple cells so all
/// four share the same overall footprint. Quick context for the ratio, not a
/// literal preview.
private struct LayoutIconView: View {
    let kind: LayoutIconKind
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            switch kind {
            case .square:    cellGrid(cols: 3, rows: 3, cellAspect: 1, side: s)
            case .portrait:  cellGrid(cols: 4, rows: 3, cellAspect: 1.7, side: s)
            case .landscape: cellGrid(cols: 3, rows: 4, cellAspect: 0.55, side: s)
            case .mason:     masonGrid(side: s)
            }
        }
    }

    /// A `cols × rows` grid of identical cells (cellAspect = height ÷ width).
    private func cellGrid(cols: Int, rows: Int, cellAspect: CGFloat, side: CGFloat) -> some View {
        let gap: CGFloat = 3
        return VStack(spacing: gap) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: gap) {
                    ForEach(0..<cols, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(color)
                            .aspectRatio(1 / cellAspect, contentMode: .fit)
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The masonry pattern: 4 columns of staggered bar heights.
    private func masonGrid(side: CGFloat) -> some View {
        let gap: CGFloat = 3
        // Per-column relative bar heights (sum drives the stagger).
        let cols: [[CGFloat]] = [[0.55, 0.41], [0.30, 0.66], [0.66, 0.30], [0.41, 0.55]]
        return HStack(spacing: gap) {
            ForEach(0..<cols.count, id: \.self) { c in
                VStack(spacing: gap) {
                    ForEach(0..<cols[c].count, id: \.self) { r in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(color)
                            .frame(height: side * cols[c][r])
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
