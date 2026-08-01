//
//  OpenWithForkCard.swift
//  Muse
//
//  Handing a file with Muse edits to an external app is ambiguous, so the app
//  asks rather than guessing.
//
//  Without this, "Open With → Pixelmator" opens the ORIGINAL — the user's
//  adjustments are simply absent, and the obvious conclusion is that Muse
//  discarded them. Both answers are legitimate (retouch the original; carry
//  the look into the external edit), so both are offered.
//

import SwiftUI

/// A pending fork decision, hoisted to the shell like every other modal
/// request — an in-window card is sized from its host's geometry, and a
/// context menu has none.
struct OpenWithForkRequest: Identifiable {
    let id = UUID()
    let fileURL: URL
    /// nil = the default app (a plain double-click / "Open").
    let appURL: URL?
}

/// A pending name prompt raised from inside the editor.
struct EditNamePrompt: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var placeholder: String
    var confirmTitle: String
    var initialText: String = ""
    var onCommit: (String) -> Void
}

struct OpenWithForkCard: View {
    let request: OpenWithForkRequest
    let onDismiss: () -> Void
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("This photo has Muse edits")
                .font(.system(size: 20, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("""
                Muse edits are not part of the file itself. Open a copy with the \
                adjustments applied, or open the original untouched.
                """)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            HStack(spacing: 10) {
                Spacer()
                ModalButton(title: String(localized: "Cancel"), kind: .normal) { onDismiss() }
                ModalButton(title: String(localized: "Edit Original"), kind: .normal) {
                    onDismiss()
                    open(request.fileURL)
                }
                ModalButton(title: String(localized: "Edit a Copy"), kind: .prominent) {
                    onDismiss()
                    editACopy()
                }
            }
            .padding(.top, 20)
        }
    }

    private func editACopy() {
        let request = request
        Task {
            do {
                let copyURL = try await EditCopyFlow.run(originalURL: request.fileURL)
                await appState.reloadCurrentFiles()
                open(copyURL)
            } catch {
                appState.alertRequest = .message(
                    title: String(localized: "Couldn't create the copy"),
                    message: String(localized: """
                        Muse couldn't render an edited copy of this photo. The original \
                        is unchanged.
                        """))
            }
        }
    }

    private func open(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        if let appURL = request.appURL {
            NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                    configuration: configuration) { _, _ in }
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
