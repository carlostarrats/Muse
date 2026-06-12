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

    var body: some View {
        ZStack {
        NavigationSplitView {
            SidebarView()
        } detail: {
            ZStack {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if appState.viewMode == .grid && !appState.isSearchActive {
                            // Chips only on the main page — inside a collection
                            // the back-arrow header takes over.
                            if appState.activeCollectionID == nil {
                                TagChipsRow()
                            }
                            // A tag filter takes the page over: collections
                            // hide until the filter clears back to "All".
                            if appState.activeTagLabel == nil {
                                CollectionsRow()
                            }
                        }
                        switch appState.viewMode {
                        case .grid:
                            GridView()
                        case .cloud:
                            CloudView()
                        case .graph:
                            GraphView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(appState.moodPalette.background)
                    .animation(.easeInOut(duration: 0.35), value: appState.moodPalette)

                    if appState.chatPanelVisible && ChatService.shared.isAvailable {
                        ChatPanelView()
                            .transition(.move(edge: .trailing))
                    }
                }

            }
            .toolbar {
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
                    sortMenu
                }

                ToolbarItem(placement: .primaryAction) {
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

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await appState.analyzeCurrentFolder() }
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .help("Analyze current folder (AI tag + OCR + color)")
                    .disabled(AnalyzePipeline.shared.isRunning)
                }

                ToolbarItem(placement: .primaryAction) {
                    if ChatService.shared.isAvailable {
                        Button {
                            appState.chatPanelVisible.toggle()
                        } label: {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                                .foregroundStyle(appState.chatPanelVisible ? Color.purple : Color.primary)
                        }
                        .help("Ask Muse")
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    moodMenu
                    Button {
                        appState.fluidEnabled.toggle()
                    } label: {
                        Image(systemName: "drop.fill")
                            .foregroundStyle(appState.fluidEnabled ? Color.blue : Color.primary)
                    }
                    .help(appState.fluidEnabled ? "Disable Water Effect" : "Enable Water Effect")
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
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
        .overlay(alignment: .bottom) {
            if AnalyzePipeline.shared.isRunning {
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
            Picker("Sort", selection: Binding(
                get: { appState.sortMode },
                set: { appState.sortMode = $0; appState.resort() }
            )) {
                Section("Standard") {
                    ForEach([SortMode.dateModified, .dateCreated, .name, .size, .kind], id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Section("Smart") {
                    ForEach([SortMode.dominantColor, .faceCount, .hasText], id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .help("Sort: \(appState.sortMode.displayName)")
    }

    @ViewBuilder
    private var moodMenu: some View {
        Menu {
            Picker("Background mood", selection: Binding(
                get: { appState.mood },
                set: { appState.setMood($0) }
            )) {
                ForEach(Mood.allCases) { mood in
                    Text(mood.displayName).tag(mood)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "paintpalette")
        }
        .help("Background mood: \(appState.mood.displayName)")
    }

    /// Bottom-center pill while tile thumbnails stream in for a big folder.
    private var thumbsBanner: some View {
        statusPill(label: "Loading images \(thumbProgress.completed) of \(thumbProgress.total)",
                   completed: thumbProgress.completed, total: thumbProgress.total)
    }

    /// Bottom-center pill while the indexer works through a folder.
    private var indexingBanner: some View {
        statusPill(label: "Indexing \(indexProgress.completed) of \(indexProgress.total)",
                   completed: indexProgress.completed, total: indexProgress.total)
    }

    /// Same glass as the grid's column slider: ultra-thin material capsule
    /// with the hairline outline, same height, same 16pt bottom seat.
    private func statusPill(label: String, completed: Int, total: Int) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: Double(completed), total: Double(max(total, 1)))
                .progressViewStyle(.linear)
                .frame(width: 160)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(height: 20)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
        .overlay(Capsule(style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .padding(.bottom, 16)
        .transition(.opacity)
    }

    @ViewBuilder
    private var analyzeStatusBanner: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("Analyzing")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                ProgressView(value: AnalyzePipeline.shared.progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 240)
                if !AnalyzePipeline.shared.current.isEmpty {
                    Text(AnalyzePipeline.shared.current)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
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
