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
    let title: String
    let urls: [URL]
    let onClose: () -> Void

    @State private var intro: String = ""
    @State private var label: String = AppSettings.driveShareLabel
    @State private var name: String = AppSettings.driveShareName
    @State private var expiry = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()

    init(auth: GoogleOAuth, title: String, urls: [URL], onClose: @escaping () -> Void) {
        _service = StateObject(wrappedValue: DriveShareService(auth: auth))
        self.title = title
        self.urls = urls
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Share Drive Link").font(.system(size: 24, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                SheetCloseButton { onClose() }
            }
            .padding(.bottom, 20)

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
                doneView(url)
            case .failed(let message):
                failedView(message)
            }
        }
        .padding(28)
        .frame(width: 460)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            field(String(localized: "Page Title"), text: $intro,
                  prompt: String(localized: "Project Name"))
            field(String(localized: "Label"), text: $label,
                  prompt: String(localized: "e.g. Sent by"))
            field(String(localized: "Name"), text: $name,
                  prompt: String(localized: "Your Name"))
            VStack(alignment: .leading, spacing: 4) {
                Text("Expires").font(.system(size: 12)).foregroundStyle(.secondary)
                DatePicker("", selection: $expiry, in: Date()..., displayedComponents: .date)
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(Text("Expires"))
            }

            HStack {
                Spacer()
                HoverButton(title: String(localized: "Publish"), prominent: true, isDefault: true) {
                    // Today's date is automatic (used only in the Drive folder
                    // name, never shown on the page) — one less field for the user.
                    let form = DriveShareForm(intro: intro, label: label, name: name,
                                              date: Date(), expiry: expiry)
                    service.publish(form: form, title: title, urls: urls)
                }
                .disabled(intro.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 6)
        }
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

    private func doneView(_ url: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your share is live.").font(.system(size: 15, weight: .semibold))
            Text(url).font(.system(size: 12)).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            HStack {
                HoverButton(title: String(localized: "Copy Link")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
                HoverButton(title: String(localized: "Share…")) { shareLink(url) }
                Spacer()
                HoverButton(title: String(localized: "Done"), prominent: true, isDefault: true) { onClose() }
            }
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.icloud").font(.system(size: 26)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message).multilineTextAlignment(.center)
            HoverButton(title: String(localized: "Done"), prominent: true, isDefault: true) { onClose() }
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

/// A flat button with a clear hover highlight (the default macOS buttons read
/// as inert here). Prominent = accent fill; isDefault = Return triggers it.
private struct HoverButton: View {
    let title: String
    var prominent: Bool = false
    var isDefault: Bool = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(fill))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(isDefault ? .defaultAction : nil)
        .onHover { hovering = isEnabled && $0 }
    }

    private var fill: Color {
        if prominent { return Color.accentColor.opacity(hovering ? 0.85 : 1) }
        return Color.primary.opacity(hovering ? 0.18 : 0.08)
    }
}
