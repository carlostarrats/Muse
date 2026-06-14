import Foundation
import AppKit

/// Trash with undo. Files are NEVER unlinked — they're moved to the user Trash
/// and we record where they landed so we can move them back.
///
/// IMPORTANT: this uses `NSWorkspace.recycle`, NOT `FileManager.trashItem`. In
/// the App Sandbox, `trashItem` fails with `afpAccessDenied` (NSCocoaError 513)
/// even when we hold a security-scoped bookmark on the parent folder — moving
/// into `~/.Trash` needs privileges the sandbox won't grant a direct file op.
/// `NSWorkspace.recycle` delegates to the privileged Finder service and works.
enum TrashManager {
    struct Ticket {
        var originalURL: URL
        var trashedURL: URL
    }

    static func trash(_ url: URL) async throws -> Ticket {
        let trashed: URL = try await withCheckedThrowingContinuation { cont in
            NSWorkspace.shared.recycle([url]) { newURLs, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let t = newURLs[url] {
                    cont.resume(returning: t)
                } else {
                    cont.resume(throwing: CocoaError(.fileWriteUnknown))
                }
            }
        }
        return Ticket(originalURL: url, trashedURL: trashed)
    }

    static func undo(_ ticket: Ticket) throws {
        try FileManager.default.moveItem(at: ticket.trashedURL, to: ticket.originalURL)
    }
}
