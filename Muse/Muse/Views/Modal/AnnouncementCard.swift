//
//  AnnouncementCard.swift
//  Muse
//
//  The announcements channel's one piece of UI. Shaped like ModalMessageCard
//  (same width, same padding, same button row) rather than reusing it, because
//  the optional "Learn More" link is a third button state MuseAlert doesn't
//  model.
//
//  Everything here is REMOTE text. It renders as plain `Text` — never markdown,
//  never attributed, never HTML — and the strings arrived already sanitized and
//  length-capped by `AnnouncementFeed.parse`, whose url field is https-only.
//

import SwiftUI
import AppKit

struct AnnouncementCard: View {
    let announcement: Announcement
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(announcement.title)
                    .font(.system(size: 20, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                SheetCloseButton { onDismiss() }
            }

            Text(announcement.body)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            HStack {
                Spacer()
                if let link = announcement.url.flatMap({ URL(string: $0) }),
                   link.scheme == "https" {
                    // Re-checked at the point of use, not just at parse: the
                    // one thing this card can do to the user's machine is open
                    // a URL, so the scheme guard lives next to the open.
                    ModalButton(title: String(localized: "Learn More")) {
                        NSWorkspace.shared.open(link)
                        onDismiss()
                    }
                }
                ModalButton(title: String(localized: "Dismiss"),
                            kind: .prominent, isDefault: true) {
                    onDismiss()
                }
            }
            .padding(.top, 22)
        }
        .padding(24)
    }
}
