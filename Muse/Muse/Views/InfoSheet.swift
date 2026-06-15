//
//  InfoSheet.swift
//  Muse
//
//  The ⓘ modal: how the app behaves — indexing, viewing, analysis,
//  collections, tags, search, duplicates, sharing, iCloud, moods,
//  privacy. Plain-language home for the rules that otherwise live in
//  nobody's head.
//

import SwiftUI

struct InfoSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("About Muse")
                    .font(.system(size: 24, weight: .semibold))
                Spacer()
                CloseButton { isPresented = false }
            }
            .padding(.bottom, 20)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    section("What Muse is", """
                        A local-first viewer and organizer for the folders \
                        you already have. Point it at a folder — Downloads, \
                        Documents, a pile of screenshots — and browse \
                        everything in one place. Nothing is imported or \
                        copied: Muse reads your files where they live and \
                        never moves or changes them.
                        """)
                    rowDivider
                    section("Library & indexing", """
                        Add folders from the sidebar and Muse indexes them \
                        automatically — the status pills at the bottom show \
                        the progress. Drag your folders up or down to put the \
                        ones you care about on top. To keep a buried subfolder \
                        within reach, right-click it and Pin — a shortcut \
                        appears in the Pinned section at the top (top-level \
                        folders are already there, so they aren't pinnable). \
                        Your files are never modified; deleting always means \
                        moving to the Trash, and it's undoable.
                        """)
                    rowDivider
                    section("Viewing files", """
                        Muse opens almost anything in place: images, PDFs, \
                        video, audio, 3D models, fonts, Markdown, and code or \
                        text. Click an image for a full-screen hero view with \
                        zoom, pan, and a side panel of its details. Anything \
                        Muse doesn't have a dedicated viewer for falls back to \
                        Quick Look — and you can always right-click and Open \
                        With another app.
                        """)
                    rowDivider
                    section("Analysis", """
                        After indexing, Muse automatically analyzes new or \
                        changed images with Apple's on-device Vision: tags, \
                        dominant colors, dimensions, and readable text. This \
                        powers the tag chips, the Color and Shape sorts, the \
                        viewer's color swatches, and collections. There's no \
                        button to press — images already analyzed are never \
                        redone, and your own tag edits always win over the \
                        machine's.
                        """)
                    rowDivider
                    section("Collections", """
                        Groupings that span your whole library, suggested \
                        automatically from what Vision finds, plus any you \
                        build by hand in the viewer. Screenshots get their \
                        own smart collections by what they're of — recipes, \
                        receipts, places, articles, and more. Open the \
                        Collections page from the toolbar to browse them. \
                        They track your files: delete images or remove a \
                        folder and collections shrink to match — empty ones \
                        disappear. Open one to rename or delete it from its \
                        header.
                        """)
                    rowDivider
                    section("Tags", """
                        The chip row shows the tags of the folder you're \
                        viewing. Click a chip to filter; hover for its count. \
                        Right-click a chip to rename or delete the tag \
                        everywhere; add tags from an image's right-click menu \
                        or inside the viewer.
                        """)
                    rowDivider
                    section("Search", """
                        Searches the folder selected in the sidebar — names, \
                        tags, captions, and text found inside images.
                        """)
                    rowDivider
                    section("Duplicates", """
                        Find Duplicates in the File menu surfaces copies — \
                        byte-for-byte identical files, visually similar \
                        images, and matching filenames — so you can review \
                        and clear them out to the Trash.
                        """)
                    rowDivider
                    section("Sharing", """
                        Share an image straight from the viewer — AirDrop, \
                        Mail, Messages, or Save to Files. From Finder, \
                        right-click any file and choose Share → Muse to send \
                        it into your iCloud folder.
                        """)
                    rowDivider
                    section("iCloud sync", """
                        Muse can keep one folder in your iCloud Drive, synced \
                        across your Macs. Each image carries a small sidecar \
                        of its tags, colors, and analysis, so a second Mac \
                        restores everything without re-analyzing. This rides \
                        Apple's iCloud sync — Muse itself still makes no \
                        network calls.
                        """)
                    rowDivider
                    section("Background", """
                        The palette button offers Light, Dark, Auto (light by \
                        day, dark at night), and a custom color via the \
                        sliders.
                        """)
                    rowDivider
                    section("Updates", """
                        Muse is distributed directly (not via the App Store) \
                        and keeps itself up to date with Sparkle. Choose Muse ▸ \
                        Check for Updates… any time, or let it check on its own \
                        — it asks first. New versions are downloaded over HTTPS \
                        and cryptographically verified before installing.
                        """)
                    rowDivider
                    section("Open source", """
                        Muse is open source under the MIT license. The code \
                        lives at github.com/carlostarrats/Muse.
                        """)
                    rowDivider
                    section("Privacy & retention", """
                        Everything happens on this Mac. Muse collects nothing — \
                        no analytics, no telemetry; nothing about you or your \
                        files is ever uploaded or shared. Its only network use \
                        is checking for and downloading app updates (iCloud \
                        sync, if you use it, is handled by the system). If you \
                        remove a folder from the sidebar, its index data is \
                        kept for 180 days — so re-adding it restores everything \
                        instantly — then deleted automatically.
                        """)
                }
            }
        }
        .padding(28)
        .frame(width: 540, height: 640)
    }

    /// Hairline between section rows.
    private var rowDivider: some View {
        Divider()
            .padding(.vertical, 16)
    }

    /// Circular ✕, hover-brightening — same family as the app's other
    /// round controls. Esc also closes.
    private struct CloseButton: View {
        var action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.primary.opacity(hovering ? 0.16 : 0.08)))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(body)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
