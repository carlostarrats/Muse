//
//  ContentView.swift
//  Muse
//
//  Phase 3 main shell: NavigationSplitView with sidebar + grid +
//  optional right detail panel + breadcrumb/sort/analyze toolbar.
//  Selected file pops up the viewer overlay via ViewerRouter.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var indexProgress = IndexProgress.shared
    @ObservedObject private var thumbProgress = ThumbProgress.shared
    @ObservedObject private var analyzePipeline = AnalyzePipeline.shared
    @State private var moodPickerShown = false
    @State private var infoShown = false

    var body: some View {
        ZStack {
        NavigationSplitView {
            SidebarView()
        } detail: {
            ZStack {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        // Chips stay pinned; the collections row lives inside
                        // the grid's scroll view and scrolls away with it.
                        if appState.viewMode == .grid && !appState.isSearchActive
                            && appState.activeCollectionID == nil {
                            TagChipsRow()
                        }
                        switch appState.viewMode {
                        case .grid:
                            GridView()
                        case .cloud:
                            CloudView()
                        case .graph:
                            GalaxyView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(appState.moodPalette.background)
                    .animation(.easeInOut(duration: 0.35), value: appState.moodPalette)

                }

            }
            .toolbar {
                // Far left, beside the sidebar toggle — fully separate from search.
                ToolbarItem(placement: .navigation) {
                    sortMenu
                }

                // Its own item (own surface), sitting next to sort.
                ToolbarItem(placement: .navigation) {
                    Toggle(isOn: $appState.showSubfolders) {
                        Image(systemName: "rectangle.stack")
                    }
                    .help(appState.showSubfolders
                          ? "Hide files inside subfolders"
                          : "Show files inside subfolders")
                    .onChange(of: appState.showSubfolders) { _, _ in
                        appState.toggleSubfolders()
                    }
                }

                ToolbarItem(placement: .principal) {
                    SearchBar()
                }

                ToolbarItem(placement: .primaryAction) {
                    Picker("View", selection: $appState.viewMode) {
                        Image(systemName: "square.grid.2x2").tag(AppState.ViewMode.grid)
                        Image(systemName: "cloud").tag(AppState.ViewMode.cloud)
                        Image(systemName: "point.3.connected.trianglepath.dotted").tag(AppState.ViewMode.graph)
                    }
                    .pickerStyle(.segmented)
                    .help("Switch between grid, cloud, and graph views")
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    if appState.activeCollectionID != nil {
                        Button {
                            appState.setActiveCollection(nil)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .help("Clear collection filter")
                    }
                }

                // Each its own item so they sit as separate toolbar surfaces
                // rather than one grouped cluster.
                ToolbarItem(placement: .primaryAction) {
                    moodMenu
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        appState.fluidEnabled.toggle()
                    } label: {
                        // Line icon at rest like the rest of the toolbar;
                        // fills (and goes blue) only while the effect is on.
                        // When off, no explicit tint — so it greys out with
                        // the window when the app is in the background, just
                        // like every other toolbar icon.
                        if appState.fluidEnabled {
                            Image(systemName: "drop.fill")
                                .foregroundStyle(Color.blue)
                        } else {
                            Image(systemName: "drop")
                        }
                    }
                    .help(appState.fluidEnabled ? "Disable Water Effect" : "Enable Water Effect")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        infoShown = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .help("About Muse — how indexing, Analyze, collections, and tags work")
                }
            }
            // Transparent title bar so the sidebar card flows continuously up
            // to the top and curves with the window corner (Lineform-style).
            .toolbarBackground(.hidden, for: .windowToolbar)
            // No window title — the toolbar starts at the search bar.
            .navigationTitle("")
            // The viewer covers everything (prototype) — no toolbar above it.
            // Must hide in the same transaction the viewer mounts: the stage
            // computes its fit center from the overlay size, and a later hide
            // moves that center mid-flight (the image visibly arcs).
            // It returns when the close flight *starts* (viewerDismissing),
            // fading in alongside the flight rather than popping after it;
            // HeroStage retargets mid-close, so the grid shifting down under
            // the returning toolbar still lands the image on its tile.
            .toolbar(appState.selectedFile == nil || appState.viewerDismissing
                     ? .automatic : .hidden,
                     for: .windowToolbar)
        }

        // Window-level overlays: the hero viewer spans the whole window —
        // sidebar and toolbar included — exactly like the prototype.
        if let selected = appState.selectedFile {
            // Hero (image) viewers mount instantly: the prototype's stage is
            // opaque from the first frame — only its backdrop fades in.
            // Fading the whole subtree made the flight semi-transparent.
            ViewerRouter(file: selected)
                .transition(selected.kind == .image || selected.kind == .raw
                            || selected.kind == .psd ? .identity : .opacity)
        }
        GridToastHost(deletion: appState.deletion)
            .zIndex(60)
        }
        .animation(.easeInOut(duration: 0.18), value: appState.selectedFile?.id)
        .background(
            Button(action: {
                if let selected = appState.selectedFile,
                   selected.kind == .image || selected.kind == .raw
                       || selected.kind == .psd {
                    // Hero viewer: run the return flight instead of popping.
                    appState.viewerClosing = true
                } else if appState.selectedFile != nil {
                    appState.selectedFile = nil
                } else if appState.graphFocusedCollectionID != nil {
                    appState.graphFocusedCollectionID = nil
                }
            }) { EmptyView() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        )
        .sheet(isPresented: $appState.duplicatesSheetVisible) {
            DuplicatesView(isPresented: $appState.duplicatesSheetVisible)
        }
        .sheet(isPresented: $infoShown) {
            InfoSheet(isPresented: $infoShown)
        }
        .overlay(alignment: .bottom) {
            if analyzePipeline.isRunning {
                analyzeStatusBanner
            } else if indexProgress.isActive {
                indexingBanner
            } else if thumbProgress.isActive {
                thumbsBanner
            }
        }
        .preferredColorScheme(appState.moodPalette.scheme)
    }

    @ViewBuilder
    private var sortMenu: some View {
        Menu {
            // Picker gives native menu checkmarks (the empty-systemImage
            // Label hack logged "no symbol named ''" console noise).
            // One flat list — Color and Shape simply use Analyze data when
            // it exists, no Standard/Smart ceremony.
            Picker("Sort", selection: Binding(
                get: { appState.sortMode },
                set: { appState.sortMode = $0; appState.resort() }
            )) {
                ForEach(SortMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "arrow.up.and.down.text.horizontal")
        }
        .help("Sort: \(appState.sortMode.displayName)")
    }

    @ViewBuilder
    private var moodMenu: some View {
        Button {
            moodPickerShown.toggle()
        } label: {
            Image(systemName: "paintpalette")
        }
        .help("Background: \(appState.mood.displayName)")
        .popover(isPresented: $moodPickerShown, arrowEdge: .bottom) {
            MoodPickerView()
                .environmentObject(appState)
        }
    }

    /// Bottom-center pill while tile thumbnails stream in for a big folder.
    private var thumbsBanner: some View {
        statusPill(label: "Loading images \(thumbProgress.completed) of \(thumbProgress.total)",
                   progress: Double(thumbProgress.completed) / Double(max(thumbProgress.total, 1)))
    }

    /// Bottom-center pill while the indexer works through a folder.
    private var indexingBanner: some View {
        statusPill(label: "Indexing \(indexProgress.completed) of \(indexProgress.total)",
                   progress: Double(indexProgress.completed) / Double(max(indexProgress.total, 1)))
    }

    /// One shared pill for every phase — same glass as the grid's column
    /// slider: ultra-thin material capsule, hairline outline, same height,
    /// same 16pt bottom seat.
    private func statusPill(label: String, progress: Double) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: min(max(progress, 0), 1))
                .progressViewStyle(.linear)
                .frame(width: 160)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(height: 20)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
        .overlay(Capsule(style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .padding(.bottom, 16)
        .transition(.opacity)
    }

    private var analyzeStatusBanner: some View {
        statusPill(label: analyzePipeline.current.isEmpty
                        ? "Analyzing…"
                        : "Analyzing \(analyzePipeline.current)",
                   progress: analyzePipeline.progress)
    }

}

/// Observes the DeleteCoordinator directly — nested ObservableObjects
/// don't republish through AppState.
private struct GridToastHost: View {
    @ObservedObject var deletion: DeleteCoordinator
    var body: some View {
        ViewerToast(toast: $deletion.toast)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
