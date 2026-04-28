//
//  MuseAppIntents.swift
//  Muse
//
//  App Intents — Apple's automation API for Shortcuts/Siri/Spotlight.
//  Per Q23b, App Intents is Muse's primary external automation surface
//  (MCP server cut from v1 due to App Store sandbox).
//

import Foundation
import AppIntents
import AppKit

// MARK: - Notifications used to drive the running app from intents

extension Notification.Name {
    static let museOpenFolder = Notification.Name("muse.openFolder")
    static let museRunDuplicates = Notification.Name("muse.runDuplicates")
    static let museRunAnalyze = Notification.Name("muse.runAnalyze")
}

// MARK: - File summary entity

struct FileSummaryEntity: AppEntity, Identifiable {
    var id: String
    var basename: String
    var path: String

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Muse File")
    static var defaultQuery = FileSummaryQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(basename)", subtitle: "\(path)")
    }
}

struct FileSummaryQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FileSummaryEntity] {
        []
    }

    func suggestedEntities() async throws -> [FileSummaryEntity] {
        []
    }
}

// MARK: - Intents

struct OpenFolderIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Folder in Muse"
    static var description = IntentDescription("Open a specific folder in Muse.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Folder", description: "Path of the folder to open")
    var path: String

    func perform() async throws -> some IntentResult {
        let url = URL(fileURLWithPath: path)
        await MainActor.run {
            NotificationCenter.default.post(
                name: .museOpenFolder,
                object: nil,
                userInfo: ["url": url]
            )
        }
        return .result()
    }
}

struct FindDuplicatesIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Duplicates in Folder"
    static var description = IntentDescription("Run Muse's duplicate scan on a folder.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Folder")
    var path: String

    func perform() async throws -> some IntentResult {
        let url = URL(fileURLWithPath: path)
        await MainActor.run {
            NotificationCenter.default.post(
                name: .museRunDuplicates,
                object: nil,
                userInfo: ["url": url]
            )
        }
        return .result()
    }
}

struct AnalyzeFolderIntent: AppIntent {
    static var title: LocalizedStringResource = "Analyze Folder with Muse AI"
    static var description = IntentDescription("Run Vision-based tagging, OCR, and color extraction on every image in a folder.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Folder")
    var path: String

    func perform() async throws -> some IntentResult {
        let url = URL(fileURLWithPath: path)
        await MainActor.run {
            NotificationCenter.default.post(
                name: .museRunAnalyze,
                object: nil,
                userInfo: ["url": url]
            )
        }
        return .result()
    }
}

struct SearchLibraryIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Muse Library"
    static var description = IntentDescription("Search files, captions, and tags in Muse's indexed library.")

    @Parameter(title: "Query", description: "Search text")
    var query: String

    @Parameter(title: "Limit", default: 20)
    var limit: Int

    func perform() async throws -> some IntentResult & ReturnsValue<[FileSummaryEntity]> {
        let results = await MainActor.run {
            Task { await SearchService.search(query: query, scope: .everywhere) }
        }
        let files = await results.value
        let mapped = files.prefix(max(1, limit)).map { node in
            FileSummaryEntity(
                id: node.url.path,
                basename: node.basename,
                path: node.url.path
            )
        }
        return .result(value: Array(mapped))
    }
}

// MARK: - AppShortcuts registration

struct MuseAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenFolderIntent(),
            phrases: ["Open \(.applicationName) at folder"],
            shortTitle: "Open Folder",
            systemImageName: "folder"
        )
        AppShortcut(
            intent: FindDuplicatesIntent(),
            phrases: ["Find duplicates with \(.applicationName)"],
            shortTitle: "Find Duplicates",
            systemImageName: "square.on.square"
        )
        AppShortcut(
            intent: AnalyzeFolderIntent(),
            phrases: ["Analyze folder with \(.applicationName)"],
            shortTitle: "Analyze Folder",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: SearchLibraryIntent(),
            phrases: ["Search \(.applicationName)"],
            shortTitle: "Search Library",
            systemImageName: "magnifyingglass"
        )
    }
}
