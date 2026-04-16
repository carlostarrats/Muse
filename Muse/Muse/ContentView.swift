//
//  ContentView.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Toolbar logo loaded from the bundled SVG.
private struct LogoView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        if let url = Bundle.main.url(forResource: "muse-logo", withExtension: "svg"),
           let img = NSImage(contentsOf: url) {
            view.image = img
            view.imageScaling = .scaleProportionallyUpOrDown
        }
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.widthAnchor.constraint(equalToConstant: 60).isActive = true
        view.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return view
    }
    func updateNSView(_ nsView: NSImageView, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    /// Tracks whether a delete confirmation is pending via the keyboard shortcut path.
    @State private var showKeyboardDeleteConfirmation: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            // MARK: - Main layout
            ZStack(alignment: .trailing) {
                // Main content area — switches based on viewMode
                ZStack {
                    switch appState.viewMode {
                    case .grid:
                        GridView()
                            .transition(.opacity)
                    case .universe:
                        UniverseView()
                            .transition(.opacity)
                    case .globe(let collectionID):
                        GlobeView(collectionID: collectionID)
                            .transition(.opacity)
                    case .folder:
                        FolderViewContainer()
                            .transition(.opacity)
                    }

                    // Large image preview overlay
                    if let image = appState.selectedImage {
                        ImagePreviewOverlay(image: image)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.3), value: appState.viewMode)
                .animation(.easeInOut(duration: 0.25), value: appState.selectedImage?.id)

                // Detail panel overlays on top of the grid (doesn't push it)
                if appState.detailPanelVisible {
                    ImageDetailPanel()
                        .shadow(color: .black.opacity(0.15), radius: 12, x: -4, y: 0)
                        .transition(.move(edge: .trailing))
                }
            }
            .navigationTitle("")
            .onAppear {
                // Hide the window title text and show the SVG logo instead
                if let window = NSApplication.shared.windows.first {
                    window.title = ""
                    window.titleVisibility = .hidden
                    // Add logo to the titlebar
                    if let url = Bundle.main.url(forResource: "muse-logo", withExtension: "svg"),
                       let img = NSImage(contentsOf: url) {
                        let imageView = NSImageView()
                        imageView.image = img
                        imageView.imageScaling = .scaleProportionallyUpOrDown
                        let container = NSView(frame: NSRect(x: 0, y: 0, width: 76, height: 38))
                        imageView.translatesAutoresizingMaskIntoConstraints = false
                        container.addSubview(imageView)
                        NSLayoutConstraint.activate([
                            imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                            imageView.widthAnchor.constraint(equalToConstant: 55),
                            imageView.heightAnchor.constraint(equalToConstant: 15)
                        ])
                        let accessory = NSTitlebarAccessoryViewController()
                        accessory.view = container
                        accessory.fullScreenMinHeight = 38
                        accessory.layoutAttribute = .leading
                        window.addTitlebarAccessoryViewController(accessory)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    if case .globe = appState.viewMode {
                        Button {
                            appState.viewMode = .universe
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .help("Back to Universe")
                    }
                }

                ToolbarItem(placement: .principal) {
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        ViewSwitcher()
                        CollectionFilter()
                        TagFilter()
                        SearchBar()
                            .frame(minWidth: 200, maxWidth: 400)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openImportPanel()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .keyboardShortcut("i", modifiers: .command)
                    .help("Import Images (⌘I)")
                }
            }

            // MARK: - Import progress bar
            // appState.isImporting mirrors ImportManager.isImporting and is @Published,
            // so SwiftUI will re-render when it changes.
            if appState.isImporting, let manager = appState.importManager {
                importProgressBanner(manager: manager)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
        // MARK: - Import drop zone overlay
        .overlay {
            ImportDropZone()
        }
        // MARK: - Keyboard shortcuts
        // Cmd+F — post a notification that SearchBar observes to claim focus
        .background(
            Button("") {
                NotificationCenter.default.post(name: .museSearchBarFocus, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        )
        // Escape — close detail panel if open, otherwise clear search
        .background(
            Button("") { handleEscape() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        )
        // Delete/Backspace — delete selected image (only when detail panel visible)
        .background(
            Button("") { triggerDeleteIfPossible() }
                .keyboardShortcut(.delete, modifiers: [])
                .hidden()
        )
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: $showKeyboardDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let image = appState.selectedImage {
                    Task { await appState.deleteImage(image) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove the image and its files. This action cannot be undone.")
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: appState.detailPanelVisible)
        .animation(.easeInOut(duration: 0.2), value: appState.importManager?.isImporting)
    }

    // MARK: - Import Progress Banner

    @ViewBuilder
    private func importProgressBanner(manager: ImportManager) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProgressView(value: manager.progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)
                    .tint(.accentColor)

                if !manager.currentFileName.isEmpty {
                    Text(manager.currentFileName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 160, alignment: .trailing)
                }

                Text("\(Int(manager.progress * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.regularMaterial)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Keyboard Actions

    private func handleEscape() {
        if appState.detailPanelVisible {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                appState.detailPanelVisible = false
                appState.selectedImage = nil
            }
        } else if !appState.searchQuery.isEmpty {
            appState.searchQuery = ""
        }
    }

    private func triggerDeleteIfPossible() {
        guard appState.detailPanelVisible, appState.selectedImage != nil else { return }
        showKeyboardDeleteConfirmation = true
    }

    private var deleteDialogTitle: String {
        if let image = appState.selectedImage {
            return "Delete \"\(image.fileName)\"?"
        }
        return "Delete image?"
    }

    // MARK: - Import

    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [UTType.image]

        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls

            Task {
                guard let manager = appState.importManager else { return }

                var files: [URL] = []
                for url in urls {
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

                    if isDirectory.boolValue {
                        await manager.importFolder(at: url)
                    } else {
                        files.append(url)
                    }
                }

                if !files.isEmpty {
                    await manager.importFiles(files)
                }

                await appState.refreshAfterImport()
            }
        }
    }
}

// MARK: - Image Preview Overlay

/// Shows a large image preview with fit-to-window and 100% zoom modes.
/// When the detail panel is open, the image sits to the left of it.
struct ImagePreviewOverlay: View {
    @EnvironmentObject var appState: AppState
    let image: MuseImage
    @State private var nsImage: NSImage?
    @State private var isFullSize = false

    private let panelWidth: CGFloat = 280

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dimmed background — click to dismiss
                Color.black.opacity(0.6)
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) {
                            appState.selectedImage = nil
                            appState.detailPanelVisible = false
                        }
                    }

                let availableWidth = appState.detailPanelVisible
                    ? geo.size.width - panelWidth
                    : geo.size.width

                if let nsImage = nsImage {
                    if isFullSize {
                        // 100% zoom — scrollable
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .frame(
                                    width: nsImage.size.width,
                                    height: nsImage.size.height
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                        .frame(width: availableWidth, height: geo.size.height)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // Fit to window
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
                            .padding(32)
                            .frame(width: availableWidth, height: geo.size.height)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Zoom toggle button — bottom left of image area
                    VStack {
                        Spacer()
                        HStack {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isFullSize.toggle()
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: isFullSize ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 12, weight: .medium))
                                    Text(isFullSize ? "Fit" : "100%")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.5), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(20)
                            Spacer()
                        }
                    }
                    .frame(width: availableWidth, height: geo.size.height)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView()
                        .scaleEffect(1.5)
                        .frame(width: availableWidth, height: geo.size.height)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear { loadFullImage() }
        .onChange(of: image.id) { _, _ in
            isFullSize = false
            loadFullImage()
        }
    }

    private func loadFullImage() {
        let url = image.resolvedStorageURL ?? image.resolvedThumbnailURL
        guard let url else { return }
        Task.detached(priority: .userInitiated) {
            let loaded = NSImage(contentsOf: url)
            await MainActor.run { nsImage = loaded }
        }
    }
}

// MARK: - Folder View Container

/// Combines FolderView with a collection tabs overlay for switching between folders.
struct FolderViewContainer: View {
    @EnvironmentObject var appState: AppState
    @State private var folderViewCoordinator: FolderView.Coordinator?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            FolderView()
                .onAppear {
                    // Coordinator is managed by FolderView's NSViewRepresentable
                }

            if FolderView.displayCollections(from: appState).count > 1 {
                FolderCollectionTabs { collection in
                    folderViewCoordinator?.switchCollection(collection)
                }
                .padding(12)
            }
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    /// Posted when the user presses Cmd+F to request search bar focus.
    static let museSearchBarFocus = Notification.Name("museSearchBarFocus")
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
