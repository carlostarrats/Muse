//
//  DriveShareService.swift
//  Muse
//
//  Orchestrates a Drive publish: ensure sign-in → ensure Muse root → create the
//  share folder → upload images → make + upload the print PDF → set link-
//  sharing → assemble the page URL (manifest in the fragment) → record it.
//  Network happens ONLY here and in the sweeper, always behind a user action.
//

import Foundation
import UniformTypeIdentifiers

struct DriveShareForm {
    var intro: String
    var label: String
    var name: String
    var date: Date
    var expiry: Date
}

@MainActor final class DriveShareService: ObservableObject {
    enum Phase: Equatable {
        case idle, signingIn, uploading(Int, Int), finalizing, done(String), failed(String)
    }
    @Published private(set) var phase: Phase = .idle

    private let auth: GoogleOAuth
    private let client: DriveClient
    private let store: DriveShareStore
    private var task: Task<Void, Never>?

    init(auth: GoogleOAuth, store: DriveShareStore = .default) {
        self.auth = auth
        self.client = DriveClient(auth: auth)
        self.store = store
    }

    var isSignedIn: Bool { auth.isSignedIn }
    func reset() { cancel(); phase = .idle }
    func cancel() { task?.cancel(); task = nil }

    func publish(form: DriveShareForm, title: String, urls: [URL]) {
        guard urls.isEmpty == false else {
            phase = .failed(String(localized: "This collection has no images to share.")); return
        }
        task = Task { await run(form: form, title: title, urls: urls) }
    }

    private func run(form: DriveShareForm, title: String, urls: [URL]) async {
        do {
            if auth.isSignedIn == false {
                phase = .signingIn
                try await auth.signIn()
            }
            // Ensure the tidy top-level Muse folder.
            let root = try await client.ensureMuseRoot(existingID: AppSettings.driveRootFolderID)
            AppSettings.driveRootFolderID = root

            let iso = DateFormatter.driveDay
            let folderName = "\(title) — \(iso.string(from: form.date))"
            let folderID = try await client.createFolder(name: folderName, parent: root)

            do {
                phase = .uploading(0, urls.count)
                var imageIDs: [String] = []
                for (i, url) in urls.enumerated() {
                    if Task.isCancelled { try? await client.deleteFolder(id: folderID); return }
                    let mime = Self.mimeType(for: url)
                    let id = try await client.uploadFile(url: url, name: url.lastPathComponent,
                                                         mime: mime, parent: folderID)
                    imageIDs.append(id)
                    phase = .uploading(i + 1, urls.count)
                }

                phase = .finalizing
                // Print-quality PDF from ORIGINALS (existing exporter), uploaded too.
                var pdfID: String?
                if let pdf = await CollectionPDFExporter.makePDF(
                    urls: urls, title: title, count: urls.count, columns: 4,
                    layoutAspect: nil, tileBackdrop: nil, tagLabels: [],
                    pageSize: PaperSize.default.size) {
                    pdfID = try? await client.uploadFile(url: pdf, name: "\(title).pdf",
                                                         mime: "application/pdf", parent: folderID)
                }

                try await client.setAnyoneReader(fileID: folderID)

                let manifest = DriveShareManifest(
                    intro: form.intro, label: form.label, name: form.name,
                    date: iso.string(from: form.date), expiry: iso.string(from: form.expiry),
                    imageIDs: imageIDs, pdfID: pdfID)
                let pageURL = manifest.pageURL(base: DriveConfig.shareBaseURL)

                store.add(DriveShareRecord(id: UUID().uuidString, collectionName: title,
                                           folderID: folderID, pageURL: pageURL,
                                           itemCount: imageIDs.count, createdAt: Date(),
                                           expiry: form.expiry))
                // Remember the form text for next time.
                AppSettings.driveShareName = form.name
                AppSettings.driveShareLabel = form.label
                phase = .done(pageURL)
            } catch {
                // Any failure after the folder exists → delete it so we never
                // orphan an untracked folder in the user's Drive, then surface.
                try? await client.deleteFolder(id: folderID)
                throw error
            }
        } catch is CancellationError {
            phase = .idle
        } catch DriveAuthError.cancelled {
            phase = .idle
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case DriveAuthError.notSignedIn, DriveAuthError.refreshFailed:
            return String(localized: "Couldn't sign in to Google. Please try again.")
        case DriveClient.DriveError.http(let code) where code == 403:
            return String(localized: "Google Drive is full or the request was denied.")
        default:
            return String(localized: "Couldn't publish to Google Drive. Check your connection and try again.")
        }
    }

    private static func mimeType(for url: URL) -> String {
        if let t = UTType(filenameExtension: url.pathExtension), let m = t.preferredMIMEType { return m }
        return "application/octet-stream"
    }
}

extension DateFormatter {
    static let driveDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
}
