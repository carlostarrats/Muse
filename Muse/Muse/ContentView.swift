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
    @State private var showDuplicates = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            ZStack {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if appState.viewMode == .grid && !appState.isSearchActive {
                            CollectionsRow()
                        }
                        switch appState.viewMode {
                        case .grid:
                            GridView()
                        case .globe:
                            GlobeView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if appState.detailPanelVisible, let selected = appState.selectedFile {
                        DetailPanelView(file: selected)
                            .transition(.move(edge: .trailing))
                    }
                    if appState.chatPanelVisible && ChatService.shared.isAvailable {
                        ChatPanelView()
                            .transition(.move(edge: .trailing))
                    }
                }

                if let selected = appState.selectedFile, !appState.detailPanelVisible
                    || (appState.detailPanelVisible && shouldShowFullViewer) {
                    ViewerRouter(file: selected)
                        .transition(.opacity)
                }

                if appState.collectionsOverlayVisible {
                    CollectionsOverlay().zIndex(50)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    BreadcrumbView()
                }

                ToolbarItem(placement: .principal) {
                    SearchBar()
                }

                ToolbarItem(placement: .primaryAction) {
                    Picker("View", selection: $appState.viewMode) {
                        Image(systemName: "square.grid.2x2").tag(AppState.ViewMode.grid)
                        Image(systemName: "globe").tag(AppState.ViewMode.globe)
                    }
                    .pickerStyle(.segmented)
                    .help("Switch between grid and globe views")
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        appState.collectionsOverlayVisible.toggle()
                    } label: { Image(systemName: "square.grid.2x2") }
                    .help("All collections (⌘K)")
                    .keyboardShortcut("k", modifiers: .command)

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
                    Button {
                        let urls = appState.currentFiles
                            .filter { $0.kind == .image || $0.kind == .raw || $0.kind == .psd }
                            .map { $0.url }
                        Task {
                            await DuplicateFinder.shared.scan(in: urls)
                            showDuplicates = true
                        }
                    } label: {
                        Image(systemName: "square.on.square")
                    }
                    .help("Find Duplicates in this folder")
                    .disabled(DuplicateFinder.shared.isRunning)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        appState.detailPanelVisible.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .help(appState.detailPanelVisible ? "Hide details" : "Show details")
                    .disabled(appState.selectedFile == nil)
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

                ToolbarItem(placement: .primaryAction) {
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
            .animation(.easeInOut(duration: 0.18), value: appState.selectedFile?.id)
            .animation(.easeInOut(duration: 0.22), value: appState.detailPanelVisible)
        }
        .background(
            Button(action: {
                if appState.collectionsOverlayVisible {
                    appState.collectionsOverlayVisible = false
                } else if appState.selectedFile != nil {
                    appState.selectedFile = nil
                }
            }) { EmptyView() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        )
        .sheet(isPresented: $showDuplicates) {
            DuplicatesView(isPresented: $showDuplicates)
        }
        .overlay(alignment: .bottom) {
            if AnalyzePipeline.shared.isRunning {
                analyzeStatusBanner
            }
        }
    }

    private var shouldShowFullViewer: Bool {
        // The viewer is the big preview. When the detail panel is open + a file
        // is selected, show both — viewer beside panel.
        true
    }

    @ViewBuilder
    private var sortMenu: some View {
        Menu {
            Section("Standard") {
                ForEach([SortMode.dateModified, .dateCreated, .name, .size, .kind], id: \.self) { mode in
                    Button {
                        appState.sortMode = mode
                        appState.resort()
                    } label: {
                        Label(mode.displayName, systemImage: appState.sortMode == mode ? "checkmark" : "")
                    }
                }
            }
            Section("Smart") {
                ForEach([SortMode.dominantColor, .faceCount, .hasText], id: \.self) { mode in
                    Button {
                        appState.sortMode = mode
                        appState.resort()
                    } label: {
                        Label(mode.displayName, systemImage: appState.sortMode == mode ? "checkmark" : "")
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .help("Sort: \(appState.sortMode.displayName)")
    }

    @ViewBuilder
    private var analyzeStatusBanner: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
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

#Preview {
    ContentView()
        .environmentObject(AppState())
}
