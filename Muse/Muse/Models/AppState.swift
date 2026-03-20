//
//  AppState.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import Foundation
import Combine

// MARK: - View Mode

enum ViewMode: Equatable {
    case grid
    case universe
    case globe(collectionID: UUID)
    case folder
}

/// Central state container for the Muse app. Owns all data and coordinates
/// between the database, repository, and import subsystems.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Published Properties

    /// All images loaded from the database.
    @Published var images: [MuseImage] = []

    /// All collections loaded from the database.
    @Published var collections: [MuseCollection] = []

    /// The currently focused image (drives the detail panel).
    @Published var selectedImage: MuseImage?

    /// Whether the right-side detail panel is visible.
    @Published var detailPanelVisible: Bool = false

    /// Multi-selection set for batch operations (Cmd+click).
    @Published var selectedImages: Set<UUID> = []

    /// The active search filter string.
    @Published var searchQuery: String = ""

    /// Mirrors `ImportManager.isImporting` in real-time for top-level UI observation.
    @Published var isImporting: Bool = false

    /// The current view mode (grid, universe, globe, folder).
    @Published var viewMode: ViewMode = .grid

    // MARK: - Dependencies

    let databaseManager: DatabaseManager
    private let repository: ImageRepository?
    let importManager: ImportManager?

    /// Keeps the Combine subscription alive for the lifetime of AppState.
    private var importCancellable: AnyCancellable?

    // MARK: - Init

    init() {
        let db = DatabaseManager()
        databaseManager = db

        if let queue = db.dbQueue {
            let repo = ImageRepository(dbQueue: queue)
            repository = repo
            let manager = ImportManager(repository: repo)
            importManager = manager
            // Mirror ImportManager.isImporting so the progress banner reacts immediately.
            importCancellable = manager.$isImporting
                .receive(on: RunLoop.main)
                .assign(to: \.isImporting, on: self)
        } else {
            repository = nil
            importManager = nil
        }
    }

    // MARK: - Computed Properties

    /// Images filtered by `searchQuery`. Matches against `fileName` and `notes`
    /// case-insensitively. Returns all images when the query is empty.
    var filteredImages: [MuseImage] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return images }
        let lowercased = query.lowercased()
        return images.filter { image in
            image.fileName.lowercased().contains(lowercased) ||
            image.notes.lowercased().contains(lowercased)
        }
    }

    // MARK: - Data Loading

    /// Fetches all images and collections from the repository. Safe to call at launch
    /// and after any data-mutating operation.
    func loadAll() async {
        guard let repo = repository else { return }
        do {
            async let fetchedImages = repo.fetchAllImages()
            async let fetchedCollections = repo.fetchAllCollections()
            images = try await fetchedImages
            collections = try await fetchedCollections
        } catch {
            print("[AppState] loadAll failed: \(error)")
        }
    }

    /// Re-fetches images after an import completes.
    /// Note: `isImporting` is kept in sync automatically via Combine — no manual update needed.
    func refreshAfterImport() async {
        guard let repo = repository else { return }
        do {
            images = try await repo.fetchAllImages()
        } catch {
            print("[AppState] refreshAfterImport failed: \(error)")
        }
    }

    // MARK: - Image Operations

    /// Updates an image record and refreshes the in-memory images list.
    func updateImage(_ image: MuseImage) async {
        guard let repo = repository else { return }
        do {
            try await repo.updateImage(image)
            images = try await repo.fetchAllImages()
            // Keep selectedImage in sync.
            if selectedImage?.id == image.id {
                selectedImage = image
            }
        } catch {
            print("[AppState] updateImage failed: \(error)")
        }
    }

    /// Deletes an image record and its files, then clears selection.
    func deleteImage(_ image: MuseImage) async {
        guard let repo = repository else { return }
        do {
            try await repo.deleteImage(image)
            images = try await repo.fetchAllImages()
            if selectedImage?.id == image.id {
                selectedImage = nil
                detailPanelVisible = false
            }
        } catch {
            print("[AppState] deleteImage failed: \(error)")
        }
    }

    // MARK: - Tag Operations

    /// Returns all tags for the given image.
    func fetchTags(for imageID: UUID) async -> [Tag] {
        guard let repo = repository else { return [] }
        do {
            return try await repo.fetchTags(for: imageID)
        } catch {
            print("[AppState] fetchTags failed: \(error)")
            return []
        }
    }

    /// Inserts a tag and returns the updated tag list for the image.
    func addTag(_ tag: Tag) async -> [Tag] {
        guard let repo = repository else { return [] }
        do {
            try await repo.addTag(tag)
            return try await repo.fetchTags(for: tag.imageID)
        } catch {
            print("[AppState] addTag failed: \(error)")
            return []
        }
    }

    /// Deletes a tag and returns the updated tag list for the image.
    func deleteTag(_ tag: Tag) async -> [Tag] {
        guard let repo = repository else { return [] }
        do {
            try await repo.deleteTag(tag)
            return try await repo.fetchTags(for: tag.imageID)
        } catch {
            print("[AppState] deleteTag failed: \(error)")
            return []
        }
    }

    // MARK: - Search

    /// Performs a tag-aware database search when the query is non-empty,
    /// falling back to `loadAll()` when cleared.
    func searchImages(query: String) async {
        guard let repo = repository else { return }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            await loadAll()
            return
        }
        do {
            images = try await repo.searchImages(query: query)
        } catch {
            print("[AppState] searchImages failed: \(error)")
        }
    }

    // MARK: - Multi-Select

    /// Toggles an image in/out of the multi-selection set.
    func toggleImageSelection(_ image: MuseImage) {
        if selectedImages.contains(image.id) {
            selectedImages.remove(image.id)
        } else {
            selectedImages.insert(image.id)
        }
    }

    /// Adds a tag to all currently selected images.
    func batchAddTag(label: String) async {
        guard let repo = repository else { return }
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        for imageID in selectedImages {
            let tag = Tag(imageID: imageID, label: trimmed, source: "manual")
            do {
                try await repo.addTag(tag)
            } catch {
                // Likely duplicate — skip silently
            }
        }
    }

    // MARK: - Collection Operations

    /// Inserts a new collection, refreshes the collections list, and returns the new collection.
    func insertCollection(name: String) async {
        guard let repo = repository else { return }
        var collection = MuseCollection(name: name)
        do {
            try await repo.insertCollection(&collection)
            collections = try await repo.fetchAllCollections()
        } catch {
            print("[AppState] insertCollection failed: \(error)")
        }
    }
}
