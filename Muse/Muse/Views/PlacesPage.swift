//
//  PlacesPage.swift
//  Muse
//
//  The dedicated Places page — modelled on CollectionsPage: the same top
//  clearance, the same 42pt header with a back arrow, the same four-up grid of
//  cover cards.
//
//  Tapping a card runs a programmatic `near:` token search rather than opening
//  a fourth `visibleFiles` substitution: one navigation system, and Places
//  dog-foods the token engine it shares with search.
//

import SwiftUI

struct PlacesPage: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var placesStore = PlacesStore.shared

    private let columns = 4
    private let hGap: CGFloat = 24
    private let vGap: CGFloat = 40
    /// Matches CollectionsPage's header lead.
    private let hInset: CGFloat = 14

    private var sorted: [PlaceGroup] {
        // Name breaks ties so the grid never reshuffles between renders.
        func byCount(_ a: PlaceGroup, _ b: PlaceGroup) -> Bool {
            if a.count != b.count { return a.count > b.count }
            return a.displayName < b.displayName
        }
        func byRecency(_ a: PlaceGroup, _ b: PlaceGroup) -> Bool {
            if a.latestAt != b.latestAt { return a.latestAt > b.latestAt }
            return a.displayName < b.displayName
        }
        return placesStore.groups.sorted(by: placesStore.sortByCount ? byCount : byRecency)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Same reserve as CollectionsPage: a ScrollView clips to its own
            // frame, so content must be cut off at the floating toolbar's
            // boundary rather than sliding under it.
            Color.clear.frame(height: TagChipsRow.noTagsTopClearance)
            GeometryReader { geo in
                let cardWidth = max(80, (geo.size.width - hInset * 2
                                         - hGap * CGFloat(columns - 1)) / CGFloat(columns))
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 0) {
                            PageScrollCatcher(isActive: {
                                appState.selectedFile == nil && !appState.modalPresented
                            })
                            .frame(width: 0, height: 0)
                            header
                            if !sorted.isEmpty {
                                LazyVGrid(
                                    columns: Array(
                                        repeating: GridItem(.fixed(cardWidth), spacing: hGap),
                                        count: columns),
                                    alignment: .leading,
                                    spacing: vGap
                                ) {
                                    ForEach(sorted) { group in
                                        PlaceGroupCard(group: group, width: cardWidth)
                                            .onTapGesture { appState.openPlaceSearch(group) }
                                            .accessibilityAddTraits(.isButton)
                                            .accessibilityLabel(
                                                "\(group.displayName), \(group.count)")
                                            .accessibilityAction(named: Text("Show Photos")) {
                                                appState.openPlaceSearch(group)
                                            }
                                    }
                                }
                                .padding(.horizontal, hInset)
                                .padding(.top, 20)
                                .padding(.bottom, 24)
                            }
                        }
                        if sorted.isEmpty {
                            emptyState(viewportHeight: geo.size.height)
                        }
                    }
                }
                .scrollDisabled(sorted.isEmpty)
            }
        }
        .background(appState.moodPalette.background)
        .task { await placesStore.reload() }
    }

    private var header: some View {
        HStack(spacing: 18) {
            BackArrowButton(help: String(localized: "Back")) {
                appState.closePlacesPage()
            }
            Text("Places")
                .font(.system(size: 42, weight: .semibold))
            Spacer()
            Menu {
                Button("Most Photos") { placesStore.sortByCount = true }
                Button("Most Recent") { placesStore.sortByCount = false }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort Places")
            .accessibilityLabel("Sort Places")
        }
        .padding(.horizontal, hInset)
        .padding(.top, 14)
        .padding(.bottom, 48)
    }

    private func emptyState(viewportHeight: CGFloat) -> some View {
        Text("No places yet — photos with a location appear here as analysis runs.")
            .font(.title3)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(40)
            .frame(maxWidth: .infinity, minHeight: viewportHeight)
    }
}

/// A place's cover card. The thumbnail is the SAME 320×320 `renderedVariants`
/// entry the grid and collection piles use — no new cache variant.
private struct PlaceGroupCard: View {
    let group: PlaceGroup
    let width: CGFloat

    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: width, height: width * 0.75)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(hovering ? 0.18 : 0.10), radius: 9, x: 0, y: 3)

            Text(group.displayName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(group.count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .task(id: group.coverPath) {
            guard let path = group.coverPath else { image = nil; return }
            image = await ThumbnailCache.shared.thumbnail(
                for: URL(fileURLWithPath: path), size: CGSize(width: 320, height: 320))
        }
    }
}
