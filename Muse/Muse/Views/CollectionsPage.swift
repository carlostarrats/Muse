//
//  CollectionsPage.swift
//  Muse
//
//  The dedicated Collections page, reached via the toolbar's collections
//  icon. A "Collections" header (back arrow, no edit/trash) sits above a
//  vertically-scrolling grid of cover cards — four per row, resized to fit
//  the window width, ordered by the toolbar sort (name / date created / date
//  modified). Tapping a card drills into the
//  collection (the filtered grid + in-collection header takes over while the
//  page stays "open", so the in-collection back arrow returns here).
//

import SwiftUI

struct CollectionsPage: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var engine = CollectionsEngine.shared

    private let columns = 4
    private let hGap: CGFloat = 24
    private let vGap: CGFloat = 52
    private let hInset: CGFloat = 14

    /// Collections ordered by the Collections-page sort (Name / Date Created /
    /// Date Modified + direction). Reactive: changing the toolbar sort or arrow
    /// updates `appState.collectionSort*`, which re-runs this computed property.
    private var sorted: [CollectionStore.Loaded] {
        let loaded = engine.collections
        let items = loaded.map {
            CollectionSort.Item(id: $0.collection.id,
                                name: $0.collection.name,
                                createdAt: $0.collection.created_at,
                                updatedAt: $0.collection.updated_at)
        }
        let orderedIDs = CollectionSort.order(items,
                                              by: appState.collectionSortMode,
                                              reversed: appState.collectionSortReversed)
        let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.collection.id, $0) })
        return orderedIDs.compactMap { byID[$0] }
    }

    var body: some View {
        GeometryReader { geo in
            // Width that makes exactly `columns` cards (plus gaps + insets)
            // fill the viewport. Cards resize with the window.
            let available = max(0, geo.size.width
                                - hInset * 2
                                - hGap * CGFloat(columns - 1))
            let cardWidth = available / CGFloat(columns)
            // Cover keeps the card's 2:1 mosaic aspect.
            let cover = CGSize(width: cardWidth, height: cardWidth / 2)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Page Up / Page Down scrolls the cards a screenful at a time.
                    PageScrollCatcher(isActive: { appState.selectedFile == nil })
                        .frame(width: 0, height: 0)
                    header
                    if sorted.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.fixed(cardWidth), spacing: hGap),
                                count: columns),
                            alignment: .leading,
                            spacing: vGap
                        ) {
                            ForEach(sorted, id: \.collection.id) { loaded in
                                CollectionCard(loaded: loaded, coverSize: cover)
                            }
                        }
                        .padding(.horizontal, hInset)
                        // Matches the in-collection grid's top content inset
                        // (20) so the gap under the title is identical there
                        // (header's 48 + the grid's 20).
                        .padding(.top, 20)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .background(appState.moodPalette.background)
    }

    // Mirrors the in-collection header geometry: back arrow + 42pt title,
    // 14 leading / 14 top, and the same 48pt gap before the cards below.
    private var header: some View {
        HStack(spacing: 18) {
            BackArrowButton(help: "Back") {
                appState.toggleCollectionsPage()
            }
            Text("Collections")
                .font(.system(size: 42, weight: .semibold))
            Spacer()
            // Far right, same size/position as the in-collection trash button.
            AddCollectionButton { createCollection() }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 48)
    }

    /// Open the shared "Name Collection" modal (empty selection → empty named
    /// collection). Unified with the grid's "New Collection from Selection".
    private func createCollection() {
        appState.requestNewCollection()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No collections yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Collections form automatically as Muse analyzes your images — or tap + to make your own.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

/// "+" header button — same size/shape as the in-collection trash button
/// (40×40, 16pt glyph), but additive, so it leans on the accent/primary on
/// hover rather than red.
private struct AddCollectionButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.primary.opacity(hovering ? 0.16 : 0.08)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("New Collection")
        .accessibilityLabel("New Collection")
    }
}
