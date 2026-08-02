//
//  ExportPresetStore.swift
//  Muse
//
//  Saved export settings. Defaults-backed rather than a table: a preset here is
//  a working preference like the editor backdrop, not library data, so it needs
//  no migration and has no business in a backup.
//
//  A corrupt blob degrades to an empty list rather than throwing. Someone whose
//  presets can't decode should still be able to export — losing the shortcuts is
//  recoverable, being unable to get a file out is not.
//

import Foundation

struct SavedExportPreset: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var name: String
    var settings: ExportSettings

    init(id: UUID = UUID(), name: String, settings: ExportSettings) {
        self.id = id
        self.name = name
        self.settings = settings
    }
}

@MainActor
final class ExportPresetStore: ObservableObject {
    static let shared = ExportPresetStore()

    @Published private(set) var presets: [SavedExportPreset] = []

    init() { reload() }

    func reload() {
        guard let data = AppSettings.exportPresets,
              let decoded = try? JSONDecoder().decode([SavedExportPreset].self, from: data)
        else {
            presets = []
            return
        }
        presets = Self.sorted(decoded)
    }

    /// No name-uniqueness rule: two presets may share a name and stay distinct
    /// by id. Renaming is right there if the duplicate bothers you, and
    /// silently appending " 2" to something you just typed is worse.
    func save(name: String, settings: ExportSettings) {
        presets = Self.sorted(presets + [SavedExportPreset(name: name, settings: settings)])
        persist()
    }

    func delete(id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    func rename(id: UUID, to name: String) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].name = name
        presets = Self.sorted(presets)
        persist()
    }

    private func persist() {
        AppSettings.exportPresets = try? JSONEncoder().encode(presets)
    }

    private static func sorted(_ list: [SavedExportPreset]) -> [SavedExportPreset] {
        list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
