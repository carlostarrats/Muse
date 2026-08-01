//
//  AppState+Import.swift
//  Muse
//
//  File > Import — one submenu over five sources, and ONE shell-modal flag for
//  every card any of them raises.
//
//  `importModal` REPLACES the shipped `metadataImportRequest` 1-for-1, so the
//  frozen-AppState rule holds at net-zero `@Published` count. The card swaps a
//  run performs (run → label mapping → report) are PHASE CHANGES of this one
//  flag, never stacked modals — a card is sized from its host's geometry, and
//  a card raised over a card has no honest host.
//
//  Every source writes through existing seams only: tags via
//  `MetadataImportApply.applyKeywords`, ratings via `TagStore.setRating`
//  (gap-fill), notes via `NoteStore` (fill-gaps), edits via `EditStore.save`
//  (never clobbers), collections via `CollectionStore.createManual`/`addFile`.
//  A new source is a reader and a mapper, never a new writer.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

/// One requested metadata/Lightroom import run over a folder.
struct MetadataImportRequest: Identifiable, Equatable {
    let id = UUID()
    let folder: URL
}

/// The distinct color-label values one scan found, and how often.
struct LabelMappingRequest: Identifiable {
    let id = UUID()
    /// Raw source values in first-seen order.
    var values: [String]
    var counts: [String: Int]
    /// Resolved by the card; the run model is suspended until it fires.
    var onResolve: ([String: LabelMapping.Choice]) -> Void
}

struct TakeoutImportRequest: Identifiable, Equatable {
    let id = UUID()
    var folder: URL
}

struct EagleImportRequest: Identifiable, Equatable {
    let id = UUID()
    var libraryURL: URL
    var destination: URL
}

struct ApplePhotosImportRequest: Identifiable, Equatable {
    let id = UUID()
    var destination: URL
}

struct LightroomPresetImportRequest: Identifiable, Equatable {
    let id = UUID()
    var urls: [URL]
}

/// Which import card the shell should build. Items whose spec dependency is
/// unbuilt are ABSENT from the menu, never disabled.
enum ImportModal: Identifiable {
    case metadata(MetadataImportRequest)
    case labelMapping(LabelMappingRequest)
    case lightroomPresets(LightroomPresetImportRequest)
    case applePhotos(ApplePhotosImportRequest)
    case takeout(TakeoutImportRequest)
    case eagle(EagleImportRequest)
    case report(ImportReport)

    var id: String {
        switch self {
        case .metadata(let r): return "metadata-\(r.id)"
        case .labelMapping(let r): return "labelMapping-\(r.id)"
        case .lightroomPresets(let r): return "lightroomPresets-\(r.id)"
        case .applePhotos(let r): return "applePhotos-\(r.id)"
        case .takeout(let r): return "takeout-\(r.id)"
        case .eagle(let r): return "eagle-\(r.id)"
        case .report(let r): return "report-\(r.id)"
        }
    }
}

extension AppState {

    /// Folder-only picker → import. A folder outside every root is added as
    /// a sidebar root first (the standard addRoot flow — it activates before
    /// appending) so the imported tags have rows to land on and the user can
    /// see the result. A folder already under a root is used as-is
    /// (containment via the trailing-slash prefix rule).
    func importMetadataAndEdits() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Select a folder of images — keywords, ratings, captions and Lightroom adjustments written by other apps will be imported.")
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let std = coveredFolder(url)
        importModal = .metadata(MetadataImportRequest(folder: std))
    }

    func importGoogleTakeout() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Select the folder you extracted from Google Takeout. Muse reads the photos where they are — nothing is copied or moved.")
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let std = coveredFolder(url)
        importModal = .takeout(TakeoutImportRequest(folder: std))
    }

    func importEagleLibrary() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = true
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.message = String(localized: "Select an Eagle library. Muse copies the images out of it into a folder you choose — the library itself is never modified.")
        picker.prompt = String(localized: "Choose Library")
        guard picker.runModal() == .OK, let library = picker.url else { return }

        let destinationPanel = NSOpenPanel()
        destinationPanel.canChooseFiles = false
        destinationPanel.canChooseDirectories = true
        destinationPanel.canCreateDirectories = true
        destinationPanel.message = String(localized: "Choose where the imported images should live.")
        destinationPanel.prompt = String(localized: "Import Here")
        guard destinationPanel.runModal() == .OK,
              let destination = destinationPanel.url else { return }
        let std = coveredFolder(destination)
        importModal = .eagle(EagleImportRequest(libraryURL: library.standardizedFileURL,
                                                destination: std))
    }

    func importApplePhotos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = String(localized: "Choose where the photos copied out of Apple Photos should live.")
        panel.prompt = String(localized: "Import Here")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let std = coveredFolder(url)
        importModal = .applePhotos(ApplePhotosImportRequest(destination: std))
    }

    func importLightroomPresets() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if let xmp = UTType(filenameExtension: "xmp") {
            panel.allowedContentTypes = [xmp]
        }
        panel.message = String(localized: "Select Lightroom preset files. They're imported as Muse looks — approximated, and yours to adjust.")
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importModal = .lightroomPresets(LightroomPresetImportRequest(urls: panel.urls))
    }

    /// Standardize the picked folder and make sure it's inside a library root,
    /// adding it as one when it isn't — otherwise every write would land
    /// nowhere. Trailing-slash containment, the shipped rule.
    @discardableResult
    func coveredFolder(_ url: URL) -> URL {
        let std = url.standardizedFileURL
        let covered = rootNodes.contains {
            let root = $0.url.standardizedFileURL.path
            return std.path == root || std.path.hasPrefix(root + "/")
        }
        if !covered {
            _ = bookmarks.addRoot(at: std)
        }
        return std
    }
}
