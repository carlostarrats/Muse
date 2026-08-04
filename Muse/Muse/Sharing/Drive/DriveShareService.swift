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
    var layout: DriveShareLayout = .grid
    var bodyText: String = ""          // shown on essay + portfolio pages
}

/// What a share sheet is being opened FOR. A portfolio is the same publish
/// machinery with a live `manifest.json` in Drive behind it; `.portfolioUpdate`
/// rewrites that manifest in place so the URL never changes.
enum DriveShareMode: Equatable {
    case share
    case portfolioNew
    case portfolioUpdate(DriveShareRecord)
}

/// The payload `CollectionModal.driveShare` carries up to the shell.
struct DriveShareRequest: Equatable {
    var title: String
    var urls: [URL]
    var mode: DriveShareMode = .share
    var collectionID: String?
}

/// Pure pre-publish validation mirroring the page's own validator
/// (`DriveShareManifest.maxImages`/`.maxFieldLength`) — the app must never mint
/// a link its own page rejects as "unavailable". Kept standalone so it's
/// testable without the async publish flow.
enum DriveSharePublishGuard {
    static func validate(urls: [URL], form: DriveShareForm) -> DriveShareService.PublishError? {
        if urls.count > DriveShareManifest.maxImages {
            return .unshareableTooManyImages(urls.count)
        }
        for field in [form.intro, form.label, form.name, form.bodyText]
        where field.count > DriveShareManifest.maxFieldLength {
            return .fieldTooLong
        }
        return nil
    }
}

/// The binding portfolio-update order: upload-new → swap the manifest (the
/// atomic cutover) → delete-old. Reordering shows recipients a manifest whose
/// images are already gone. A pure `[Step]` so the ordering invariant itself is
/// unit-testable without a live Drive round trip.
enum DriveShareUpdateSteps {
    enum Step: Equatable { case uploadImages, swapManifest, sweepOldChildren }
    static let order: [Step] = [.uploadImages, .swapManifest, .sweepOldChildren]
}

@MainActor final class DriveShareService: ObservableObject {
    enum Phase: Equatable {
        case idle, preparing, signingIn, uploading(Int, Int), finalizing, done(String), doneUntracked(String)
        /// A portfolio update whose manifest swapped cleanly but whose sweep of
        /// the replaced images partly failed. The share is correct; the leftovers
        /// are retried by the next update's sweep. A phase rather than an
        /// `AppState.alertRequest` so the service keeps owning no AppState
        /// reference at all.
        case doneWithSweepWarning(String)
        case failed(String)
    }
    /// A per-file failure surfaced with its filename — the generic "check your
    /// connection" message hid the real cause when one image aborted a publish.
    enum PublishError: Error {
        case unshareableImage(String)
        case unshareableTooManyImages(Int)
        case fieldTooLong
    }
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

    /// Sign-in reachable before the form is filled (the signed-out explainer's
    /// button). Publish still handles the signed-out case exactly as before —
    /// this is additive, not a new gate.
    func signInDirectly() async throws { try await auth.signIn() }

    func publish(form: DriveShareForm, title: String, urls: [URL]) {
        guard urls.isEmpty == false else {
            phase = .failed(String(localized: "This collection has no images to share.")); return
        }
        if let guardError = DriveSharePublishGuard.validate(urls: urls, form: form) {
            phase = .failed(Self.message(for: guardError)); return
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
                        // Everything that leaves the app renders through
                        // OutputRender first (identity today).
                        let out = try OutputRender.forOutput(url)
                        // Collect the render as soon as it is uploaded — a
                        // large edited publish otherwise leaves one full-res
                        // temp per image for the 24h launch sweep to find.
                        defer { OutputRender.discard(out) }
                        id = try await client.uploadFile(out, name: url.lastPathComponent,
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
                    imageIDs: imageIDs, filenames: filenames, pdfID: nil,
                    // nil when grid / empty keeps a plain share's fragment the
                    // exact shape it had before Spec 07.
                    layout: form.layout == .grid ? nil : form.layout.rawValue,
                    bodyText: form.bodyText.isEmpty ? nil : form.bodyText)
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
        case PublishError.unshareableTooManyImages(let count):
            return String(localized: "Shares are limited to 1,000 images. This view has \(count).")
        case PublishError.fieldTooLong:
            return String(localized: "One of the share's text fields is too long.")
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

// MARK: - Portfolio mode
//
// A portfolio share = a Drive folder (images + manifest.json) + a page URL whose
// fragment carries the manifest file's id AND a full inline snapshot. The
// Drive-hosted manifest is the live truth; the page fetches it and falls back to
// the snapshot on any failure. Updates rewrite that manifest via files.update,
// so the file id — and therefore the URL — never changes. There is no
// server-side share state anywhere: it all lives in the user's own Drive.

extension DriveShareService {
    func publishPortfolio(form: DriveShareForm, title: String, collectionID: String?, urls: [URL]) {
        guard urls.isEmpty == false else {
            phase = .failed(String(localized: "This collection has no images to share.")); return
        }
        if let guardError = DriveSharePublishGuard.validate(urls: urls, form: form) {
            phase = .failed(Self.message(for: guardError)); return
        }
        cancel()
        runGeneration += 1
        let gen = runGeneration
        phase = .preparing
        task = Task { await runPortfolio(form: form, title: title, collectionID: collectionID,
                                         urls: urls, generation: gen) }
    }

    private func runPortfolio(form: DriveShareForm, title: String, collectionID: String?,
                              urls: [URL], generation: Int) async {
        do {
            if auth.isSignedIn == false {
                setPhase(.signingIn, ifCurrent: generation)
                try await auth.signIn()
            }
            let root = try await client.ensureMuseRoot(existingID: AppSettings.driveRootFolderID)
            AppSettings.driveRootFolderID = root

            let folderID = try await client.createFolder(name: "\(title) — Portfolio", parent: root)

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
                        let out = try OutputRender.forOutput(url)
                        // Collect the render as soon as it is uploaded — a
                        // large edited publish otherwise leaves one full-res
                        // temp per image for the 24h launch sweep to find.
                        defer { OutputRender.discard(out) }
                        id = try await client.uploadFile(out, name: url.lastPathComponent,
                                                         mime: mime, parent: folderID)
                    } catch is ImageMetadataStripper.StripError {
                        throw PublishError.unshareableImage(url.lastPathComponent)
                    }
                    imageIDs.append(id)
                    filenames.append(url.lastPathComponent)
                    setPhase(.uploading(i + 1, urls.count), ifCurrent: generation)
                }

                // The LIVE manifest carries no `m` of its own (exactly one
                // fetch, never a chain) and no expiry — a portfolio doesn't
                // expire, which is the whole point of the mode.
                let liveManifest = DriveShareManifest(
                    intro: form.intro, label: form.label, name: form.name,
                    date: DateFormatter.driveDay.string(from: form.date), expiry: "",
                    imageIDs: imageIDs, filenames: filenames, pdfID: nil,
                    layout: form.layout == .grid ? nil : form.layout.rawValue,
                    bodyText: form.bodyText.isEmpty ? nil : form.bodyText)
                let manifestID = try await client.uploadManifest(liveManifest.jsonData(), parent: folderID)

                setPhase(.finalizing, ifCurrent: generation)
                // Children inherit the folder's permission — the shipped single
                // permission call. manifest.json becomes world-readable the same
                // way, which the page fetch needs and which leaks nothing the
                // fragment didn't already carry.
                try await client.setAnyoneReader(fileID: folderID)

                var fragmentManifest = liveManifest
                fragmentManifest.manifestID = manifestID
                let pageURL = fragmentManifest.pageURL(base: DriveConfig.shareBaseURL)

                let tracked = store.add(DriveShareRecord(
                    id: UUID().uuidString, collectionName: title, folderID: folderID,
                    pageURL: pageURL, itemCount: imageIDs.count, createdAt: Date(),
                    expiry: DriveShareRecord.neverExpires, kind: "portfolio",
                    manifestFileID: manifestID, collectionID: collectionID,
                    layout: fragmentManifest.layout, introTitle: form.intro,
                    bodyText: form.bodyText))

                AppSettings.driveShareName = form.name
                AppSettings.driveShareLabel = form.label

                setPhase(tracked ? .done(pageURL) : .doneUntracked(pageURL), ifCurrent: generation)
            } catch {
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

    func updatePortfolio(record: DriveShareRecord, form: DriveShareForm, urls: [URL]) {
        guard urls.isEmpty == false else {
            phase = .failed(String(localized: "This collection has no images to share.")); return
        }
        if let guardError = DriveSharePublishGuard.validate(urls: urls, form: form) {
            phase = .failed(Self.message(for: guardError)); return
        }
        cancel()
        runGeneration += 1
        let gen = runGeneration
        phase = .preparing
        task = Task { await runPortfolioUpdate(record: record, form: form, urls: urls, generation: gen) }
    }

    private func runPortfolioUpdate(record: DriveShareRecord, form: DriveShareForm,
                                    urls: [URL], generation: Int) async {
        do {
            if auth.isSignedIn == false {
                setPhase(.signingIn, ifCurrent: generation)
                try await auth.signIn()
            }
            guard let manifestFileID = record.manifestFileID else {
                setPhase(.failed(String(localized: "This portfolio can't be updated — publish a new one.")),
                         ifCurrent: generation)
                return
            }
            // A 404 on the folder is terminal: the drive.file account-switch
            // orphan doctrine applies to portfolios too.
            let stillExists = (try? await client.folderExists(id: record.folderID)) ?? false
            guard stillExists else {
                setPhase(.failed(String(localized: "This portfolio no longer exists — publish a new one.")),
                         ifCurrent: generation)
                return
            }

            // Step 1 (DriveShareUpdateSteps.order): uploadImages. Until the swap
            // below, the live page still serves the OLD set — a failure here
            // damages nothing, so the rollback is just deleting what we uploaded.
            setPhase(.uploading(0, urls.count), ifCurrent: generation)
            var imageIDs: [String] = []
            var filenames: [String] = []
            for (i, url) in urls.enumerated() {
                if Task.isCancelled {
                    await Self.rollback(imageIDs, client: client)
                    setPhase(.idle, ifCurrent: generation)
                    return
                }
                let mime = Self.mimeType(for: url)
                do {
                    let out = try OutputRender.forOutput(url)
                    defer { OutputRender.discard(out) }
                    let id = try await client.uploadFile(out, name: url.lastPathComponent,
                                                         mime: mime, parent: record.folderID)
                    imageIDs.append(id)
                    filenames.append(url.lastPathComponent)
                } catch is ImageMetadataStripper.StripError {
                    await Self.rollback(imageIDs, client: client)
                    setPhase(.failed(Self.message(for: PublishError.unshareableImage(url.lastPathComponent))),
                             ifCurrent: generation)
                    return
                } catch {
                    await Self.rollback(imageIDs, client: client)
                    setPhase(.failed(Self.message(for: error)), ifCurrent: generation)
                    return
                }
                setPhase(.uploading(i + 1, urls.count), ifCurrent: generation)
            }

            // Step 2: swapManifest — the ATOMIC cutover.
            setPhase(.finalizing, ifCurrent: generation)
            let newManifest = DriveShareManifest(
                intro: form.intro, label: form.label, name: form.name,
                date: DateFormatter.driveDay.string(from: form.date), expiry: "",
                imageIDs: imageIDs, filenames: filenames, pdfID: nil,
                layout: form.layout == .grid ? nil : form.layout.rawValue,
                bodyText: form.bodyText.isEmpty ? nil : form.bodyText)
            do {
                try await client.updateManifest(id: manifestFileID, json: newManifest.jsonData())
            } catch {
                await Self.rollback(imageIDs, client: client)
                setPhase(.failed(Self.message(for: error)), ifCurrent: generation)
                return
            }

            // Step 3: sweepOldChildren — list-driven; per-file delete failures
            // are NON-fatal and are retried by the next update's sweep.
            var sweepFailed = false
            let keep = Set(imageIDs + [manifestFileID])
            if let children = try? await client.listChildren(of: record.folderID) {
                for child in children where keep.contains(child.id) == false {
                    do { try await client.deleteFolder(id: child.id) }
                    catch { sweepFailed = true }
                }
            }

            var updated = record
            updated.itemCount = imageIDs.count
            updated.layout = newManifest.layout
            updated.introTitle = form.intro
            updated.bodyText = form.bodyText
            store.add(updated)   // upserts by folderID — same pageURL/manifestFileID/createdAt

            AppSettings.driveShareName = form.name
            AppSettings.driveShareLabel = form.label

            setPhase(sweepFailed ? .doneWithSweepWarning(record.pageURL) : .done(record.pageURL),
                     ifCurrent: generation)
        } catch is CancellationError {
            setPhase(.idle, ifCurrent: generation)
        } catch DriveAuthError.cancelled {
            setPhase(.idle, ifCurrent: generation)
        } catch {
            setPhase(.failed(Self.message(for: error)), ifCurrent: generation)
        }
    }

    /// Delete just-uploaded files after a failed update. Runs in a fresh
    /// unstructured Task for the same reason `cleanupFolder` does: a cancelled
    /// task's URLSession throws before reaching the network.
    private static func rollback(_ ids: [String], client: DriveClient) async {
        guard ids.isEmpty == false else { return }
        await Task { for id in ids { try? await client.deleteFolder(id: id) } }.value
    }
}

extension DateFormatter {
    static let driveDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
}
