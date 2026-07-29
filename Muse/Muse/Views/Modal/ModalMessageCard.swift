//
//  ModalMessageCard.swift
//  Muse
//
//  The shared "are you sure?" / "that didn't work" card — the in-window
//  replacement for every SwiftUI `.alert` and `.confirmationDialog`.
//
//  Why they moved: a system alert is centred over the WHOLE window and dims
//  nothing, so it reads as an app-level interruption sitting on top of the
//  sidebar. Every other Muse modal is a card centred in the DETAIL column over
//  a scrim (see ModalPresenter), which keeps the sidebar uncovered and the card
//  under the user's eye. Two presentation styles for the same job looked like
//  two different apps.
//
//  Two ways in, both landing here:
//   - `AppState.alertRequest` — for anything raised from a view that CANNOT
//     present (a sidebar row, a tile, or another modal's content). The card is
//     sized from its host's geometry, so a 240pt row would present a 240pt
//     card; the payload travels up and the shell presents. Same rule as
//     `CollectionModal`.
//   - `.museAlert(isPresented:…)` — for the shell's own error flags, which
//     already live on AppState as `String?`s set by the ops layer.
//

import SwiftUI

/// A confirm-or-inform payload awaiting presentation by the shell.
///
/// Not `Equatable` — it carries the confirm action. Presentation is keyed on
/// `id`, so re-raising the same message re-presents a fresh card.
struct MuseAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirmTitle: String
    /// Reddens the confirm button — deletes and other unrecoverable actions.
    var isDestructive: Bool = false
    /// `nil` makes this a message with a single dismiss button: there is
    /// nothing to decline when the thing has already happened.
    var cancelTitle: String?
    var onConfirm: () -> Void = {}

    /// A choice: "Delete / Cancel".
    static func confirm(title: String,
                        message: String,
                        confirmTitle: String,
                        destructive: Bool = true,
                        onConfirm: @escaping () -> Void) -> MuseAlert {
        MuseAlert(title: title, message: message, confirmTitle: confirmTitle,
                  isDestructive: destructive,
                  cancelTitle: String(localized: "Cancel"),
                  onConfirm: onConfirm)
    }

    /// A statement: "that failed / OK".
    static func message(title: String, message: String) -> MuseAlert {
        MuseAlert(title: title, message: message,
                  confirmTitle: String(localized: "OK"),
                  cancelTitle: nil)
    }
}

// Alerts raised from more than one place, defined once so the two surfaces
// can't drift apart in wording.
extension MuseAlert {
    /// Delete a collection — offered by the sidebar row, the Collections-page
    /// card, and the in-collection header.
    static func deleteCollection(named name: String,
                                 onConfirm: @escaping () -> Void) -> MuseAlert {
        .confirm(title: String(localized: "Delete “\(name)”?"),
                 message: String(localized: "The collection is removed everywhere. Your images stay on disk."),
                 confirmTitle: String(localized: "Delete"),
                 onConfirm: onConfirm)
    }

    /// PDF save failed — from the sidebar row's menu and the share button.
    static var pdfExportFailed: MuseAlert {
        .message(title: String(localized: "Couldn’t Export the PDF"),
                 message: String(localized: "The PDF couldn’t be prepared — some images may be unreadable — or the location couldn’t be written. Check the images and that the location is writable with enough free space."))
    }
}

/// The card itself: title, body copy, and one or two buttons.
///
/// Naturally sized — no inner `ScrollView`, per the presenter's rules. The copy
/// is short by design; a message long enough to need scrolling belongs in a
/// purpose-built card.
struct ModalMessageCard: View {
    let alert: MuseAlert
    /// Dismiss without running the action (Cancel, the close button, the scrim
    /// and Escape all land here).
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(alert.title)
                    .font(.system(size: 20, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                SheetCloseButton { onCancel() }
            }

            Text(alert.message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            HStack {
                Spacer()
                if let cancelTitle = alert.cancelTitle {
                    ModalButton(title: cancelTitle, isCancel: true) { onCancel() }
                }
                confirmButton
            }
            .padding(.top, 22)
        }
        .padding(24)
    }

    @ViewBuilder
    private var confirmButton: some View {
        let action = {
            // Close first, then act: the action can present the NEXT card (a
            // failed delete raising its own message), and leaving this one up
            // would stack two.
            onCancel()
            alert.onConfirm()
        }
        ModalButton(title: alert.confirmTitle,
                    kind: alert.isDestructive ? .destructive : .prominent,
                    isDefault: true,
                    action: action)
    }
}

extension View {
    /// Present a message/confirm card over this view's own geometry. Attach at
    /// the SHELL, like every other modal.
    func museAlert(isPresented: Binding<Bool>,
                   palette: MoodPalette,
                   title: String,
                   message: String,
                   confirmTitle: String = String(localized: "OK"),
                   destructive: Bool = false,
                   cancelTitle: String? = nil,
                   onConfirm: @escaping () -> Void = {}) -> some View {
        museModal(isPresented: isPresented,
                  width: ModalMessageCardWidth.standard,
                  palette: palette) {
            ModalMessageCard(
                alert: MuseAlert(title: title, message: message,
                                 confirmTitle: confirmTitle,
                                 isDestructive: destructive,
                                 cancelTitle: cancelTitle,
                                 onConfirm: onConfirm),
                onCancel: { isPresented.wrappedValue = false })
        }
    }
}

/// One width for every message/prompt card, so consecutive confirmations don't
/// resize under the cursor.
enum ModalMessageCardWidth {
    static let standard: CGFloat = 400
}
