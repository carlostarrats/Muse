//
//  InfoSheet.swift
//  Muse
//
//  The ⓘ modal: a short answer to "what is this app", the eight questions
//  people actually ask, and a way out to the full guide.
//
//  It used to be seventeen sections of prose covering every feature — a manual
//  in a modal, which is the one place nobody reads a manual. Worse, it went
//  stale: it described the app as it was before the editor, export, import and
//  semantic search existed, and nobody noticed because nobody read it.
//
//  So the detail moved to muse-photo.com/info, where a tree and a search box
//  make a fact findable, and what stays here is what a user needs OFFLINE and
//  RIGHT NOW. The test for adding something back: would a person ask this in
//  the first five minutes, with no network? If not, it belongs on the web.
//
//  The eight answers are COLLAPSED by default, so the card opens as a scannable
//  list of questions rather than a page of prose — you read the one you came
//  for. Expanded-by-default was the thing that made the old modal unreadable at
//  a glance, and eight open answers would have reproduced it at a shorter
//  length.
//
//  Deliberately silent on pricing, licensing, distribution and updates.
//

import SwiftUI

struct InfoSheet: View {
    @Binding var isPresented: Bool

    /// The full guide. Also reachable from the site's header on every page.
    private static let guideURL = URL(string: "https://muse-photo.com/info")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Muse FAQs")
                    .font(.system(size: 24, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                SheetCloseButton { isPresented = false }
            }
            .padding(.bottom, 18)

            Text("""
                A local-first viewer and organizer for the folders you \
                already have. Point Muse at a folder and browse \
                everything in one place — nothing is imported, copied, \
                or moved. Your files stay exactly where they are, \
                exactly as they are.
                """)
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)

            // FIXED height, so opening an answer scrolls INSIDE the list
            // instead of growing the card. The presenter sizes the card to its
            // content (ModalPresenter.card), so without this pin every
            // expand/collapse resized and re-centred the whole modal under the
            // cursor. Because the card's total height is now constant and below
            // the window cap, the presenter's own scroller stays disabled —
            // this is the only thing that scrolls, so there is no nesting.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    faq("Does Muse move or change my files?", """
                        No. Muse reads your files where they live and never \
                        writes over them. Photo edits are stored as \
                        instructions, not baked into the file, so the original \
                        is always intact. Deleting means moving to the Trash, \
                        and it's undoable.
                        """)
                    faq("Where do my tags, ratings and collections live?", """
                        In Muse's own database on this Mac — not inside your \
                        files. That's why moving to a new Mac needs a backup: \
                        Muse ▸ Back Up Muse… saves it all as one file, and \
                        Restore from Backup… reconnects it by matching each \
                        file's contents, even if you renamed things along the \
                        way.
                        """)
                    faq("Does anything get uploaded?", """
                        Not unless you ask. Muse collects nothing — no \
                        analytics, no telemetry, no accounts — and nothing \
                        about you or your files ever reaches its makers. \
                        Sharing a collection uploads to your own Google Drive, \
                        only when you press Publish, and only ever touches the \
                        files it created there.
                        """)
                    faq("What files can Muse open?", """
                        Photos and RAW, PDFs, video, audio, fonts, 3D models, \
                        Markdown, code and plain text all open in place. \
                        Anything without a dedicated viewer falls back to \
                        Quick Look, and File ▸ Open With hands a file to \
                        another app.
                        """)
                    faq("How do photos get tagged and sorted?", """
                        After indexing, Muse analyzes new images with Apple's \
                        on-device Vision — tags, dominant colors, dimensions, \
                        and any readable text. There's no button to press. \
                        Your own tag edits always win over the machine's, and \
                        you can turn the automatic work off in Settings.
                        """)
                    faq("Can I edit photos in Muse?", """
                        Yes — open a photo and switch to Edit. Tone, color, \
                        curves, crop, HSL, split toning, grain and LUTs, all \
                        non-destructive, with snapshots you can jump between. \
                        Export writes a new file and never overwrites an \
                        existing one.
                        """)
                    faq("How do I share a collection?", """
                        Open a collection and use the share button in its \
                        header. Save it as a PDF at the paper size you pick, or \
                        publish a web page through your own Google Drive that \
                        anyone can open in a browser. Every image is stripped \
                        of its metadata first, and take a link down anytime \
                        from View ▸ Manage Drive Shares…
                        """)
                    faq("What happens when I remove a folder?", """
                        Nothing on disk changes — it just leaves the sidebar. \
                        Its index data is kept for 180 days, so re-adding it \
                        restores your tags, ratings and collections instantly, \
                        then it's cleaned up automatically.
                        """)
                    // The footer scrolls WITH the questions rather than being
                    // pinned under them. Pinned, an answer opening near the
                    // bottom slid beneath the button and looked truncated; now
                    // everything below an expanded row simply moves down and is
                    // reached by scrolling.
                    HStack(spacing: 14) {
                        ModalButton(title: String(localized: "Open the Full Guide"),
                                    kind: .prominent) {
                            NSWorkspace.shared.open(Self.guideURL)
                        }
                        // Markdown links inside a Text open in the default
                        // browser on their own — no button plumbing, and they
                        // stay inline type.
                        Text("[Privacy](https://muse-photo.com/privacy) · [Terms](https://muse-photo.com/terms) · [Acknowledgements](https://muse-photo.com/acknowledgements)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 20)
                }
                .padding(.trailing, 2)   // room for the overlay scroller
            }
            .frame(height: 372)          // eight collapsed rows + the footer
        }
        .padding(28)
        // Width and the height cap come from the modal presenter.
    }

    private func faq(_ question: LocalizedStringKey, _ answer: LocalizedStringKey) -> some View {
        FAQRow(question: question, answer: answer)
    }
}

/// One collapsible question. Built by hand rather than with `DisclosureGroup`
/// because that draws AppKit's own triangle and indents its content, neither of
/// which matches the rest of the modal — and its label can't carry the row's
/// full hit area, so only the text would have been clickable.
private struct FAQRow: View {
    /// How far the question list is inset from the card's text edge.
    static let indent: CGFloat = 18
    /// Breathing room between the wash's edge and the text inside it. 8pt was
    /// too tight for a paragraph — the answer ran into the rounded corner.
    static let inset: CGFloat = 12

    let question: LocalizedStringKey
    let answer: LocalizedStringKey

    @State private var isOpen = false
    @State private var hovering = false

    /// Resting / hover / open / open-and-hover, in one ramp.
    private var fillOpacity: Double {
        if isOpen { return hovering ? 0.09 : 0.06 }
        return hovering ? 0.05 : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isOpen.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(question)
                        .font(.system(size: 13.5, weight: .medium))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        // Down = "there is more below"; flips to up when open.
                        // NOT a right-pointing chevron: that reads as navigation.
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A heading so VoiceOver's rotor can jump between the eight
            // questions, and a value so it says whether this one is open.
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(Text(isOpen ? String(localized: "Expanded")
                                            : String(localized: "Collapsed")))

            if isOpen {
                Text(answer)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        // The questions sit INDENTED under the title and the intro paragraph,
        // which stay flush at the card's text edge — the indent is what marks
        // the list as subordinate to the copy above it.
        .padding(.leading, FAQRow.indent)
        // Mirrors the wash that sits left of the question text, so the chevron
        // and the answer's line ends are inset from the wash's right edge by the
        // same amount instead of being pinned hard against it.
        .padding(.trailing, FAQRow.inset)
        .background(
            // Separation comes from a filled shape, NOT hairlines. Rules between
            // rows fought the hover wash — two overlapping ways of saying "these
            // are separate", and the last one stacked with the footer's into a
            // double line. An open row keeps a resting tint so its question and
            // answer read as one block.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(fillOpacity))
                // Sits just inside the indent and stops at the card's text edge.
                // It must NOT bleed past either edge: the scroller clips there,
                // which shears the corners off and makes a rounded wash read as
                // a square band.
                .padding(.leading, FAQRow.indent - FAQRow.inset)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: isOpen)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
