//
//  DriveShareService.swift
//  Muse
//
//  Orchestrates a Drive publish: ensure sign-in → ensure Muse root → create the
//  share folder → upload images → set link-sharing → assemble the page URL
//  (manifest in the fragment) → record it. The recipient's PDF is the printed
//  page, so nothing is generated/uploaded here.
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
        case idle, preparing, signingIn, uploading(Int, Int), finalizing, done(String), doneUntracked(String), failed(String)
    }
    /// A per-file failure surfaced with its filename — the generic "check your
    /// connection" message hid the real cause when one image aborted a publish.
    enum PublishError: Error { case unshareableImage(String) }
    @Published private(set) var phase: Phase = .idle

    private let auth: GoogleOAuth
    private let client: DriveClient
    private let store: DriveShareStore
    private var task: Task<Void, Never>?
    /// Monotonic id of the CURRENT publish. A cancelled run keeps executing
    /// until its next await throws, and its terminal `phase` writes (.idle /
    /// .failed) would otherwise land AFTER a re-publish set .preparing —
    /// clobbering the live run's UI. Every phase write goes through
    /// `setPhase(_:ifCurrent:)`, which drops writes from superseded runs.
    private var runGeneration = 0

    private func setPhase(_ p: Phase, ifCurrent generation: Int) {
        if generation == runGeneration { phase = p }
    }

    init(auth: GoogleOAuth, store: DriveShareStore = .default) {
        self.auth = auth
        self.client = DriveClient(auth: auth)
        self.store = store
    }

    var isSignedIn: Bool { auth.isSignedIn }
    func reset() { cancel(); runGeneration += 1; phase = .idle }
    func cancel() { task?.cancel(); task = nil }

    func publish(form: DriveShareForm, title: String, urls: [URL]) {
        guard urls.isEmpty == false else {
            phase = .failed(String(localized: "This collection has no images to share.")); return
        }
        // Cancel any in-flight publish and leave .idle synchronously so the form
        // is replaced immediately — a second Publish click can't start a 2nd run.
        cancel()
        runGeneration += 1
        let gen = runGeneration
        phase = .preparing
        task = Task { await run(form: form, title: title, urls: urls, generation: gen) }
    }

    private func run(form: DriveShareForm, title: String, urls: [URL], generation: Int) async {
        do {
            if auth.isSignedIn == false {
                setPhase(.signingIn, ifCurrent: generation)
                try await auth.signIn()
            }
            // Ensure the tidy top-level Muse folder.
            let root = try await client.ensureMuseRoot(existingID: AppSettings.driveRootFolderID)
            AppSettings.driveRootFolderID = root

            let iso = DateFormatter.driveDay
            let folderName = "\(title) — \(iso.string(from: form.date))"
            let folderID = try await client.createFolder(name: folderName, parent: root)

            do {
                setPhase(.uploading(0, urls.count), ifCurrent: generation)
                var imageIDs: [String] = []
                var filenames: [String] = []
                for (i, url) in urls.enumerated() {
                    if Task.isCancelled {
                        await cleanupFolder(folderID)
                        setPhase(.idle, ifCurrent: generation)
                        return
                    }
                    let mime = Self.mimeType(for: url)
                    let id: String
                    do {
                        id = try await client.uploadFile(url: url, name: url.lastPathComponent,
                                                         mime: mime, parent: folderID)
                    } catch is ImageMetadataStripper.StripError {
                        throw PublishError.unshareableImage(url.lastPathComponent)
                    }
                    imageIDs.append(id)
                    filenames.append(url.lastPathComponent)
                    setPhase(.uploading(i + 1, urls.count), ifCurrent: generation)
                }

                setPhase(.finalizing, ifCurrent: generation)
                try await client.setAnyoneReader(fileID: folderID)

                // No app-side PDF: the share page prints itself (a clean
                // reflection of the image grid) so the RECIPIENT picks the
                // paper size in their own print dialog — what the spec asked for.
                let manifest = DriveShareManifest(
                    intro: form.intro, label: form.label, name: form.name,
                    date: iso.string(from: form.date), expiry: iso.string(from: form.expiry),
                    imageIDs: imageIDs, filenames: filenames, pdfID: nil)
                let pageURL = manifest.pageURL(base: DriveConfig.shareBaseURL)

                let tracked = store.add(DriveShareRecord(id: UUID().uuidString, collectionName: title,
                                           folderID: folderID, pageURL: pageURL,
                                           itemCount: imageIDs.count, createdAt: Date(),
                                           expiry: form.expiry))
                // Remember the form text for next time.
                AppSettings.driveShareName = form.name
                AppSettings.driveShareLabel = form.label
                // The share is live + public either way; if the local record
                // didn't persist, warn so the user copies the link now (Manage
                // can't see an untracked folder to unpublish it later).
                setPhase(tracked ? .done(pageURL) : .doneUntracked(pageURL),
                         ifCurrent: generation)
            } catch {
                // Any failure after the folder exists → delete it so we never
                // orphan an untracked folder in the user's Drive, then surface.
                await cleanupFolder(folderID)
                throw error
            }
        } catch is CancellationError {
            setPhase(.idle, ifCurrent: generation)
        } catch DriveAuthError.cancelled {
            setPhase(.idle, ifCurrent: generation)
        } catch {
            setPhase(.failed(Self.message(for: error)), ifCurrent: generation)
        }
    }

    /// Deletes the just-created share folder from a context that may already be
    /// CANCELLED (sheet closed / a second Publish). URLSession calls inside a
    /// cancelled task throw CancellationError before reaching the network, so a
    /// direct `client.deleteFolder` here silently never deletes anything — the
    /// DELETE must run in a fresh unstructured Task that doesn't inherit the
    /// cancellation. Awaited so the cleanup still completes before we return.
    private func cleanupFolder(_ folderID: String) async {
        let client = self.client
        await Task { try? await client.deleteFolder(id: folderID) }.value
    }

    private static func message(for error: Error) -> String {
        switch error {
        case PublishError.unshareableImage(let name):
            return String(localized: "\"\(name)\" couldn't be prepared for sharing. Remove it from the collection and try again.")
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
