//
//  ImportManager.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import Foundation
import ImageIO

/// Manages importing image files into Muse — copying to app storage, generating thumbnails,
/// reading metadata, and inserting records via ImageRepository.
@MainActor
final class ImportManager: ObservableObject {

    // MARK: - Published State

    @Published var isImporting: Bool = false
    @Published var progress: Double = 0.0
    @Published var currentFileName: String = ""
    @Published var errorCount: Int = 0

    // MARK: - Dependencies

    private let repository: ImageRepository

    // MARK: - Constants

    private static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "webp", "gif", "tiff"
    ]

    // MARK: - Init

    init(repository: ImageRepository) {
        self.repository = repository
    }

    // MARK: - Single File Import

    /// Copies the file at `url` into app storage, generates a thumbnail, reads metadata,
    /// inserts a record via the repository, and returns the created `MuseImage`.
    func importFile(at url: URL) async throws -> MuseImage {
        let uuid = UUID()
        let fileExtension = url.pathExtension.lowercased()
        let fileName = url.lastPathComponent

        // Destination paths (relative to appSupportDirectory)
        let originalRelativePath = "Images/\(uuid.uuidString)_original.\(fileExtension)"
        let thumbnailRelativePath = "Images/\(uuid.uuidString)_thumb.jpg"

        let originalDestination = DatabaseManager.appSupportDirectory
            .appendingPathComponent(originalRelativePath)
        let thumbnailDestination = DatabaseManager.appSupportDirectory
            .appendingPathComponent(thumbnailRelativePath)

        // Ensure the Images directory exists
        let fm = FileManager.default
        let imagesDir = DatabaseManager.imagesDirectory
        if !fm.fileExists(atPath: imagesDir.path) {
            try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        }

        // Copy original file
        try fm.copyItem(at: url, to: originalDestination)

        // Generate thumbnail (non-fatal on failure)
        let thumbnailGenerated = await ThumbnailGenerator.generateThumbnail(
            from: originalDestination,
            outputURL: thumbnailDestination
        )

        // Read image dimensions via CGImageSource
        var imageWidth: Int?
        var imageHeight: Int?
        if let imageSource = CGImageSourceCreateWithURL(originalDestination as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
            if let width = properties[kCGImagePropertyPixelWidth] as? Int {
                imageWidth = width
            }
            if let height = properties[kCGImagePropertyPixelHeight] as? Int {
                imageHeight = height
            }
        }

        // Read file size
        var fileSize: Int?
        if let attributes = try? fm.attributesOfItem(atPath: originalDestination.path),
           let size = attributes[.size] as? Int {
            fileSize = size
        }

        // Build the MuseImage record with relative paths
        var image = MuseImage(
            id: uuid,
            fileName: fileName,
            storagePath: originalRelativePath,
            thumbnailPath: thumbnailGenerated ? thumbnailRelativePath : nil,
            width: imageWidth,
            height: imageHeight,
            fileSize: fileSize
        )

        // Insert into the database
        try await repository.insertImage(&image)

        return image
    }

    // MARK: - Folder Import

    /// Recursively enumerates all supported image files under `url` and imports them
    /// sequentially, updating progress after each file. Failures are logged and counted
    /// but do not stop the batch.
    func importFolder(at url: URL) async {
        isImporting = true
        progress = 0.0
        errorCount = 0
        currentFileName = ""

        // Collect all supported files first so we can track progress
        let supportedFiles = collectSupportedFiles(under: url)

        guard !supportedFiles.isEmpty else {
            isImporting = false
            return
        }

        let total = Double(supportedFiles.count)

        for (index, fileURL) in supportedFiles.enumerated() {
            currentFileName = fileURL.lastPathComponent

            do {
                _ = try await importFile(at: fileURL)
            } catch {
                errorCount += 1
                print("[ImportManager] Failed to import \(fileURL.lastPathComponent): \(error)")
            }

            progress = Double(index + 1) / total
        }

        isImporting = false
        currentFileName = ""
    }

    // MARK: - Batch File Import

    /// Imports an array of file URLs with progress tracking.
    /// Works for both single and multiple file selections.
    func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isImporting = true
        progress = 0.0
        errorCount = 0
        currentFileName = ""

        let total = Double(urls.count)

        for (index, url) in urls.enumerated() {
            currentFileName = url.lastPathComponent
            do {
                _ = try await importFile(at: url)
            } catch {
                errorCount += 1
                print("[ImportManager] Failed to import \(url.lastPathComponent): \(error)")
            }
            progress = Double(index + 1) / total
        }

        isImporting = false
        currentFileName = ""
    }

    // MARK: - Private Helpers

    /// Returns all files with supported extensions found recursively under `directoryURL`.
    private func collectSupportedFiles(under directoryURL: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }
            let ext = fileURL.pathExtension.lowercased()
            if Self.supportedExtensions.contains(ext) {
                files.append(fileURL)
            }
        }
        return files
    }
}
