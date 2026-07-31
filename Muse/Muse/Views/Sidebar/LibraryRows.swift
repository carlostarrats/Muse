//
//  LibraryRows.swift
//  Muse
//
//  Sidebar LIBRARY section rows: Places, On This Day, Rarely Seen, Shuffle.
//  Fixed and non-reorderable, and all four share ONE geometry implementation
//  (`LibraryRow`) built from the StarRow template — so this row family obeys
//  the same shared invariants as the folder tree (chevronSlotWidth,
//  chevronToIconGap, iconToTextGap, rowHeight, selectionFill,
//  selectedLabelColor). Never inline a copy of this geometry.
//

import SwiftUI

/// The shared row shape. `selected` draws the system source-list selection,
/// exactly like a selected folder row.
struct LibraryRow: View {
    let glyph: String
    let title: String
    let selected: Bool
    let action: () -> Void

    @Environment(\.sidebarReordering) private var isReordering
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            // A library row is never expandable, so the chevron slot is always
            // an invisible placeholder holding the shared icon column.
            Image(systemName: "chevron.right")
                .font(.system(size: SidebarView.chevronGlyphSize, weight: .semibold))
                .opacity(0)
                .frame(width: SidebarView.chevronSlotWidth, alignment: .leading)
                .accessibilityHidden(true)

            Image(systemName: glyph)
                .font(.system(size: SidebarView.rootIconSize, weight: .semibold))
                .foregroundStyle(selected ? SidebarView.selectedLabelColor : .secondary)
                .frame(width: 18)
                .padding(.leading, SidebarView.chevronToIconGap)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
                .foregroundStyle(selected ? SidebarView.selectedLabelColor : .primary)
                .padding(.leading, SidebarView.iconToTextGap)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, SidebarView.rowHorizontalPadding)
        .frame(height: SidebarView.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? SidebarView.selectionFill
                      : Color.primary.opacity(isHovered && !isReordering
                                              ? SidebarView.rowHoverFillOpacity : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .accessibilityAddTraits(.isButton)
    }
}

struct PlacesSidebarRow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var placesStore = PlacesStore.shared

    var body: some View {
        LibraryRow(glyph: "mappin.and.ellipse",
                   title: String(localized: "Places"),
                   selected: placesStore.showingPlaces) {
            appState.openPlacesPage()
        }
    }
}

struct OnThisDaySidebarRow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store = RediscoveryStore.shared

    var body: some View {
        LibraryRow(glyph: "calendar",
                   title: String(localized: "On This Day"),
                   selected: store.active == .onThisDay) {
            appState.openRediscovery(.onThisDay)
        }
    }
}

struct RarelySeenSidebarRow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store = RediscoveryStore.shared

    var body: some View {
        LibraryRow(glyph: "moon.zzz",
                   title: String(localized: "Rarely Seen"),
                   selected: store.active == .rarelySeen) {
            appState.openRediscovery(.rarelySeen)
        }
    }
}

struct ShuffleSidebarRow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store = RediscoveryStore.shared

    var body: some View {
        LibraryRow(glyph: "shuffle",
                   title: String(localized: "Shuffle"),
                   selected: store.active == .shuffle) {
            appState.openRediscovery(.shuffle)
        }
    }
}
