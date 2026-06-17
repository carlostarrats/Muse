//
//  CollectionsPage.swift
//  Muse
//
//  The dedicated Collections page, reached via the toolbar's collections
//  icon. A "Collections" header (back arrow, no edit/trash) sits above a
//  vertically-scrolling grid of cover cards — four per row, resized to fit
//  the window width, ordered alphabetically. Tapping a card drills into the
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

    /// Collections, A→Z (case-insensitive).
    private var sorted: [CollectionStore.Loaded] {
        engine.collections.sorted {
            $0.collection.name.localizedCaseInsensitiveCompare($1.collection.name)
                == .orderedAscending
        }
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
            HeaderIconButton(systemName: "plus", help: "New Collection") {
                createCollection()
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 48)
    }

    /// Create an empty, hand-made collection (auto-named "Collection N"). It
    /// shows as a card immediately; open it to rename, or add images via "Add
    /// to Collection" from a selection.
    private func createCollection() {
        Task { @MainActor in
            guard let q = Database.shared.dbQueue else { return }
            _ = try? await CollectionStore.createManual(queue: q)
            await CollectionsEngine.shared.reload()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No collections yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Collections form automatically as Muse analyzes your images.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}
