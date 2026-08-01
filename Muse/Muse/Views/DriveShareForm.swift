//
//  DriveShareForm.swift
//  Muse
//
//  The "Share Drive Link" sheet: a small form (page title · label · name ·
//  expiry, name/label remembered between shares) that, on Publish, swaps to a
//  progress view bound to DriveShareService.phase and ends on the finished
//  page link (Copy / system share).
//

import SwiftUI
import AppKit

struct DriveShareSheet: View {
    @StateObject private var service: DriveShareService
    let request: DriveShareRequest
    let onClose: () -> Void

    @State private var intro: String
    @State private var label: String = AppSettings.driveShareLabel
    @State private var name: String = AppSettings.driveShareName
    @State private var expiry = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var layout: DriveShareLayout
    @State private var bodyText: String
    @State private var authBusy = false

    init(auth: GoogleOAuth, request: DriveShareRequest, onClose: @escaping () -> Void) {
        _service = StateObject(wrappedValue: DriveShareService(auth: auth))
        self.request = request
        self.onClose = onClose
        switch request.mode {
        case .share, .portfolioNew:
            _intro = State(initialValue: "")
            _layout = State(initialValue: DriveShareLayout(rawValue: AppSettings.driveShareLayout) ?? .grid)
            _bodyText = State(initialValue: "")
        case .portfolioUpdate(let record):
            // An update pre-fills from the record so the form reads as the
            // portfolio's current state, not a blank publish.
            _intro = State(initialValue: record.introTitle ?? "")
            _layout = State(initialValue: DriveShareLayout(rawValue: record.layout ?? "grid") ?? .grid)
            _bodyText = State(initialValue: record.bodyText ?? "")
        }
    }

    private var isPortfolioMode: Bool {
        switch request.mode {
        case .share: return false
        case .portfolioNew, .portfolioUpdate: return true
        }
    }

    private var headerTitle: String {
        switch request.mode {
        case .share:           return String(localized: "Share Drive Link")
        case .portfolioNew:    return String(localized: "Publish Portfolio")
        case .portfolioUpdate: return String(localized: "Update Portfolio")
        }
    }

    private var publishButtonTitle: String {
        switch request.mode {
        case .share:           return String(localized: "Publish")
        case .portfolioNew:    return String(localized: "Publish Portfolio")
        case .portfolioUpdate: return String(localized: "Update Portfolio")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(headerTitle).font(.system(size: 24, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                SheetCloseButton { onClose() }
            }
            .padding(.bottom, 20)

            ModalScroll {
            // Additive, never a gate: Publish itself still handles the
            // signed-out case exactly as before (.signingIn mid-run). This just
            // says what publishing does BEFORE the user commits to it.
            if service.isSignedIn == false, service.phase == .idle {
                signedOutExplainer
                    .padding(.bottom, 16)
            }
            switch service.phase {
            case .idle:
                form
            case .preparing:
                progress(String(localized: "Preparing…"))
            case .signingIn:
                progress(String(localized: "Signing in to Google…"))
            case .uploading(let i, let n):
                progress(String(localized: "Uploading \(i) of \(n)…"), value: n == 0 ? 0 : Double(i) / Double(n))
            case .finalizing:
                progress(String(localized: "Finishing…"))
            case .done(let url):
                doneView(url, tracked: true)
            case .doneUntracked(let url):
                doneView(url, tracked: false)
            case .doneWithSweepWarning(let url):
                doneView(url, tracked: true, sweepWarning: true)
            case .failed(let message):
                failedView(message)
            }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(28)
        // Width and the height cap come from the modal presenter.
        // Closing the sheet by ANY path must abort an in-flight publish —
        // otherwise the upload continues headless, setAnyoneReader fires, and
        // the collection goes public with the link rendered into a dismissed
        // sheet the user never sees. cancel() after .done is a no-op (the task
        // already finished), so the live share from a normal Done is untouched.
        .onDisappear { service.cancel() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            field(String(localized: "Page Title"), text: $intro,
                  prompt: String(localized: "Project Name"))
            layoutPicker
            // The intro paragraph is the essay layout's header, and a portfolio
            // always wants one (it reads as a small site) — otherwise it's noise.
            if isPortfolioMode || layout == .essay {
                introField
            }
            field(String(localized: "Label"), text: $label,
                  prompt: String(localized: "e.g. Sent by"))
            field(String(localized: "Name"), text: $name,
                  prompt: String(localized: "Your Name"))
            if isPortfolioMode == false {
                expiryRow
            } else if case .portfolioUpdate = request.mode {
                Text("Updating replaces the portfolio's images and text. The link stays the same.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("A portfolio doesn't expire. You can update it later at the same link.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                ModalButton(title: publishButtonTitle, kind: .prominent, isDefault: true) {
                    // Today's date is automatic (used only in the Drive folder
                    // name, never shown on the page) — one less field for the user.
                    let form = DriveShareForm(intro: intro, label: label, name: name,
                                              date: Date(), expiry: expiry,
                                              layout: layout, bodyText: bodyText)
                    AppSettings.driveShareLayout = layout.rawValue
                    switch request.mode {
                    case .share:
                        service.publish(form: form, title: request.title, urls: request.urls)
                    case .portfolioNew:
                        service.publishPortfolio(form: form, title: request.title,
                                                 collectionID: request.collectionID, urls: request.urls)
                    case .portfolioUpdate(let record):
                        service.updatePortfolio(record: record, form: form, urls: request.urls)
                    }
                }
                .disabled(intro.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 6)
        }
    }

    /// The shipped Expires block, extracted so a portfolio form can leave it out
    /// (a portfolio never expires). No behavior change.
    private var expiryRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            (Text("Expires").foregroundStyle(.secondary)
             + Text(verbatim: "  ")
             + Text("(click date to customize)").foregroundStyle(Color.accentColor))
                .font(.system(size: 12))
            DatePicker("", selection: $expiry, in: Date()..., displayedComponents: .date)
                .datePickerStyle(.field)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(Text("Expires"))
        }
    }

    private var layoutPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Layout").font(.system(size: 12)).foregroundStyle(.secondary)
            Picker("", selection: $layout) {
                Text("Grid").tag(DriveShareLayout.grid)
                Text("Contact Sheet").tag(DriveShareLayout.sheet)
                Text("Essay").tag(DriveShareLayout.essay)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(Text("Layout"))
        }
    }

    private var introField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Intro").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(String(localized: "A short paragraph about this collection…"),
                      text: $bodyText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
        }
    }

    private var signedOutExplainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your photos, your Drive.")
                .font(.system(size: 13, weight: .semibold))
            Text("Publishing uploads the selected images to your own Google Drive and creates a private web page link. Muse's developer never sees or receives your photos. Location and camera metadata are removed from every uploaded image.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if DriveConfig.consentScreenVerified == false {
                Text("Google may show an “unverified app” step while Muse's verification is in review — choose Advanced → Continue to proceed.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if authBusy {
                    ProgressView().controlSize(.small)
                } else {
                    ModalButton(title: String(localized: "Continue with Google"), kind: .prominent) {
                        Task { await runExplainerAuth() }
                    }
                }
                Spacer()
            }
            Text("Recipients view web-sized images. To give someone the original files, share them from your own Google Drive.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    /// Mirrors SettingsView.runAuth's re-entrancy guard (that one is private to
    /// its own file; both are tiny and neither should import the other's view
    /// internals).
    private func runExplainerAuth() async {
        guard authBusy == false else { return }
        authBusy = true
        try? await service.signInDirectly()
        authBusy = false
    }

    private func field(_ caption: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func progress(_ message: String, value: Double? = nil) -> some View {
        VStack(spacing: 14) {
            if let value { ProgressView(value: value).frame(width: 240) }
            else { ProgressView().controlSize(.large) }
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func doneView(_ url: String, tracked: Bool, sweepWarning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your share is live.").font(.system(size: 15, weight: .semibold))
            if sweepWarning {
                // The manifest swapped cleanly, so the page is correct — only
                // the leftover Drive files failed to delete, and the next
                // update's sweep retries them.
                Text("Some previous images couldn't be removed from Drive. They'll be cleaned up the next time you update.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !tracked, isPortfolioMode {
                Label(String(localized: "Muse couldn't save this portfolio locally — it can never be updated from here. Copy the link now."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !tracked {
                // The folder is public, but Muse couldn't record it locally, so
                // "Manage Drive Shares" can never unpublish it. Keep this warning
                // (and the link) on screen until the user dismisses — a toast
                // would vanish before they copy the only handle they'll get.
                Label(String(localized: "Muse couldn't add this to your share list — copy the link now, or you won't be able to manage or unpublish it from Muse later."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(url).font(.system(size: 12)).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            HStack {
                ModalButton(title: String(localized: "Copy Link")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
                ModalButton(title: String(localized: "Share…")) { shareLink(url) }
                Spacer()
                ModalButton(title: String(localized: "Done"), kind: .prominent, isDefault: true) { onClose() }
            }
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.icloud").font(.system(size: 26)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message).multilineTextAlignment(.center)
            ModalButton(title: String(localized: "Done"), kind: .prominent, isDefault: true) { onClose() }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 16)
    }

    private func shareLink(_ url: String) {
        // Share a "View Collection" hyperlink (attributed string) rather than the
        // raw URL: the page payload lives in the URL fragment, which Mail's
        // auto-linker breaks on — so the bare URL ends up only partly clickable
        // and lands on "not available". An attributed link keeps the WHOLE url
        // intact behind clean anchor text that's fully clickable.
        guard let contentView = NSApp.keyWindow?.contentView,
              let link = URL(string: url) else { return }
        let text = NSMutableAttributedString(string: String(localized: "View Collection"))
        text.addAttribute(.link, value: link, range: NSRange(location: 0, length: text.length))
        let picker = NSSharingServicePicker(items: [text])
        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
    }
}

