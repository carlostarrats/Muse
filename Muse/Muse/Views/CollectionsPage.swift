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

    @State private var showingNewSmart = false

    /// Collections ordered by the Collections-page sort (Name / Date Created /
    /// Date Modified + direction). Reactive: changing the toolbar sort or arrow
    /// updates `appState.collectionSort*`, which re-runs this computed property.
    private var sorted: [CollectionStore.Loaded] {
        // Content gate (matches SidebarView + sidebarCollections): show collections
        // only when a real root holds reachable images. `hasReachableContent` catches
        // the always-present, empty iCloud "Muse" root; `rootNodes` catches genuine
        // zero-roots (the reachable-count sentinel reads "unknown → has content"
        // before roots are pushed, which alone would leave ghost collections with
        // stale counts on screen). Underlying rows are untouched and reappear the
        // moment reachable images exist under a root again.
        guard !appState.rootNodes.isEmpty,
              CollectionsEngine.shared.hasReachableContent else { return [] }
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
        VStack(spacing: 0) {
            // The Collections page has no tag chips, but it must clip on scroll
            // exactly like the grid. The grid sits below TagChipsRow, whose
            // no-tags branch reserves a 10pt clearance below the floating
            // toolbar; because the grid's ScrollView clips to its own frame,
            // content is CUT OFF at that boundary instead of sliding up under
            // the toolbar. Reserve the same 10pt above this page's ScrollView so
            // its clip boundary matches — cards cut off below the toolbar rather
            // than scrolling up under it. This makes the no-tags cutoff
            // universal, and aligns the "Collections" title with the
            // in-collection header (which sits below the same reserve). Shares
            // TagChipsRow's constant so the two reserves can never drift apart.
            Color.clear.frame(height: TagChipsRow.noTagsTopClearance)
            GeometryReader { geo in
                // Width that makes exactly `columns` cards (plus gaps + insets)
                // fill the viewport. Cards resize with the window.
                let available = max(0, geo.size.width
                                    - hInset * 2
                                    - hGap * CGFloat(columns - 1))
                let cardWidth = available / CGFloat(columns)
                // Square-ish pile cell: the scattered stack needs vertical
                // room around the cards for the rest-state peek and hover fan.
                let cover = CGSize(width: cardWidth, height: cardWidth * 0.9)

                ScrollView {
                    // ZStack, not sequential VStack flow: the empty state
                    // fills and centers in the FULL `geo.size.height` — same
                    // "ignore whatever floating chrome sits above" approach
                    // GridView's empty state uses (confirmed correct there).
                    // Stacking it as a THIRD VStack row instead (below a real
                    // header row) means its own height gets ADDED to the
                    // header's, overflowing the actual viewport — the exact
                    // bug that made it read as sitting too low.
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 0) {
                            // Page Up / Page Down scrolls the cards a screenful at a time.
                            PageScrollCatcher(isActive: { appState.selectedFile == nil })
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
                        if sorted.isEmpty {
                            emptyState(viewportHeight: geo.size.height)
                        }
                    }
                }
                // See GridView's identical modifier: a ScrollView still
                // permits rubber-band drag/bounce even when content exactly
                // fills the viewport, which reads as "not really centered."
                // Nothing to scroll to in the empty state, so disable it.
                .scrollDisabled(sorted.isEmpty)
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
            AddCollectionButton(
                onNewCollection: { createCollection() },
                onNewSmartCollection: { showingNewSmart = true })
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 48)
        .sheet(isPresented: $showingNewSmart) {
            SmartCollectionRulesView(collectionID: nil,
                                     initialName: defaultSmartName(),
                                     initialSet: SmartRuleSet(match: .all, rules: [])) {
                showingNewSmart = false
            }
        }
    }

    /// Default auto-name for a new smart collection ("Collection N"), reusing the
    /// same numbering as hand-made collections so names never collide.
    private func defaultSmartName() -> String {
        let names = appState.sidebarCollections.map { $0.collection.name }
        return ManualCollectionName.next(existing: names)
    }

    /// Open the shared "Name Collection" modal (empty selection → empty named
    /// collection). Unified with the grid's "New Collection from Selection".
    private func createCollection() {
        appState.requestNewCollection()
    }

    // Text weight/color matches GridView's empty state exactly (`.title3` /
    // `.secondary`) so the two read as the same design, not two different
    // one-offs.
    private func emptyState(viewportHeight: CGFloat) -> some View {
        // `.padding` before `.frame(minHeight:)`, not after — see GridView's
        // identical fix. Padding after adds its own inset on top of the
        // already-viewport-tall frame, overflowing the visible area and
        // reading as "too low" once scroll is disabled and the excess clips.
        Text("No collections yet")
            .font(.title3)
            .foregroundStyle(.secondary)
            .padding(40)
            .frame(maxWidth: .infinity, minHeight: viewportHeight)
    }
}

/// "+" header menu — same size/shape as the in-collection trash button
/// (40×40, 16pt glyph), but additive, so it leans on the accent/primary on
/// hover rather than red. Offers a plain hand-made collection or a smart one.
private struct AddCollectionButton: View {
    var onNewCollection: () -> Void
    var onNewSmartCollection: () -> Void
    @State private var hovering = false

    var body: some View {
        Menu {
            Button("New Collection") { onNewCollection() }
            Button("New Smart Collection…") { onNewSmartCollection() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.primary.opacity(hovering ? 0.16 : 0.08)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("New Collection")
        .accessibilityLabel("New Collection")
    }
}
