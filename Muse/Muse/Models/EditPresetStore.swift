//
//  EditPresetStore.swift
//  Muse
//
//  Library-global looks (v21). Pattern B, like every other new store.
//
//  Presets store a stack MINUS the geometry group. A stored crop ambushes
//  every photo the preset is applied to — you asked for a look and got your
//  subject cropped out. Geometry is the ONLY exclusion; copy/paste, which is a
//  deliberate one-off, DOES offer it.
//
//  Application is copy-by-value: a stack never stores a preset reference, so
//  editing a preset later can't silently rewrite photos, and "Update Preset
//  from This Photo" stays an explicit action.
//

import Foundation

@MainActor
final class EditPresetStore: ObservableObject {
    static let shared = EditPresetStore()

    @Published private(set) var presets: [EditPresetRow] = []

    init() {}

    func load() async {
        guard let queue = Database.shared.dbQueue else { return }
        presets = (try? await queue.read { db in
            try EditPresetRow.fetchAll(db, sql:
                "SELECT * FROM edit_presets ORDER BY name COLLATE NOCASE")
        }) ?? []
    }

    func create(name: String, stack: EditStack) async {
        guard let queue = Database.shared.dbQueue else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let row = EditPresetRow(id: UUID().uuidString, name: name,
                                stack: Self.presetJSON(from: stack),
                                created_at: now, updated_at: now)
        try? await queue.write { db in var r = row; try r.insert(db) }
        await load()
    }

    /// Import path (Spec 06): geometry is still excluded, but the Lightroom
    /// ORIGIN is kept — this preset genuinely did come from a `.xmp`, and the
    /// badge is how the user knows the values are approximations. Returns the
    /// name actually used (a ` 2` ladder resolves collisions; `edit_presets`
    /// has no UNIQUE constraint, so this is courtesy, not correctness).
    @discardableResult
    func createImported(name: String, stack: EditStack) async -> String? {
        guard let queue = Database.shared.dbQueue else { return nil }
        var forPreset = stack
        forPreset.adjustments.removeAll { if case .geometry = $0 { true } else { false } }
        guard let json = try? EditStackCodec.encode(forPreset.normalized()) else { return nil }
        let existing = Set(presets.map { $0.name.lowercased() })
        let unique = Self.uniqueName(name, existing: existing)
        let now = Int64(Date().timeIntervalSince1970)
        let row = EditPresetRow(id: UUID().uuidString, name: unique, stack: json,
                                created_at: now, updated_at: now)
        do {
            try await queue.write { db in var r = row; try r.insert(db) }
        } catch {
            return nil
        }
        await load()
        return unique
    }

    /// "Name" → "Name 2" → "Name 3"…, case-insensitively.
    nonisolated static func uniqueName(_ base: String, existing: Set<String>) -> String {
        guard existing.contains(base.lowercased()) else { return base }
        var index = 2
        while existing.contains("\(base) \(index)".lowercased()) { index += 1 }
        return "\(base) \(index)"
    }

    func update(id: String, from stack: EditStack) async {
        guard let queue = Database.shared.dbQueue else { return }
        try? await queue.write { db in
            try db.execute(sql: "UPDATE edit_presets SET stack = ?, updated_at = ? WHERE id = ?",
                           arguments: [Self.presetJSON(from: stack),
                                       Int64(Date().timeIntervalSince1970), id])
        }
        await load()
    }

    func rename(id: String, to name: String) async {
        guard let queue = Database.shared.dbQueue else { return }
        try? await queue.write { db in
            try db.execute(sql: "UPDATE edit_presets SET name = ? WHERE id = ?",
                           arguments: [name, id])
        }
        await load()
    }

    func delete(id: String) async {
        guard let queue = Database.shared.dbQueue else { return }
        try? await queue.write { db in
            try db.execute(sql: "DELETE FROM edit_presets WHERE id = ?", arguments: [id])
        }
        await load()
    }

    /// The geometry exclusion, in one place — both write paths go through it.
    /// Origin is stripped here too: a preset is a look you now own, not a claim
    /// that every photo you apply it to came from Lightroom.
    nonisolated static func presetJSON(from stack: EditStack) -> String {
        var forPreset = stack
        forPreset.adjustments.removeAll { if case .geometry = $0 { true } else { false } }
        forPreset.origin = nil
        return (try? EditStackCodec.encode(forPreset.normalized())) ?? "{}"
    }
}

/// Copy/paste buffer — IN-MEMORY only. Never `NSPasteboard` (an edit stack is
/// not something another app can meaningfully receive, and putting it there
/// would clobber whatever the user actually copied), never persisted.
@MainActor
final class EditClipboard: ObservableObject {
    static let shared = EditClipboard()
    private init() {}

    @Published var stack: EditStack?
    @Published var groups: Set<AdjustmentGroup> = []

    var hasContent: Bool { stack != nil && !groups.isEmpty }

    func copy(_ stack: EditStack, groups: Set<AdjustmentGroup>) {
        self.stack = stack
        self.groups = groups
    }

    /// Apply the clipboard onto a target stack. Copy-by-value; a group absent
    /// in the source CLEARS it in the target.
    func apply(onto target: EditStack) -> EditStack {
        guard let stack else { return target }
        return EditTransfer.apply(groups: groups, from: stack, onto: target)
    }
}
