import Foundation

/// Trash with undo. Files are NEVER unlinked — FileManager.trashItem moves to
/// the user Trash and reports where it landed so we can move it back.
enum TrashManager {
    struct Ticket {
        var originalURL: URL
        var trashedURL: URL
    }

    static func trash(_ url: URL) throws -> Ticket {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        guard let t = trashed as URL? else {
            throw CocoaError(.fileWriteUnknown)
        }
        return Ticket(originalURL: url, trashedURL: t)
    }

    static func undo(_ ticket: Ticket) throws {
        try FileManager.default.moveItem(at: ticket.trashedURL, to: ticket.originalURL)
    }
}
