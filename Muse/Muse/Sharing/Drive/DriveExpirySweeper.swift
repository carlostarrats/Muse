//
//  DriveExpirySweeper.swift
//  Muse
//
//  Muse-local expiry: on launch, hard-delete any Drive share folder past its
//  expiry (the folder Muse created — drive.file covers it), then drop the
//  record. No backend. Runs ONLY if there are expired records AND a token —
//  otherwise zero network.
//

import Foundation

@MainActor enum DriveExpirySweeper {
    static func sweep(auth: GoogleOAuth, store: DriveShareStore = .default) async {
        let due = DriveExpiry.expired(store.all(), now: Date())
        guard due.isEmpty == false, auth.isSignedIn else { return }
        let client = DriveClient(auth: auth)
        for record in due {
            do { try await client.deleteFolder(id: record.folderID); store.remove(id: record.id) }
            catch { /* leave the record; retry next launch */ }
        }
    }
}
