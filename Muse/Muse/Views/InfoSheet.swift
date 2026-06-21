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
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                SheetCloseButton { isPresented = false }
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
                    section("Library & folders", """
                        Add folders from the sidebar with the Add Folder \
                        button — Muse indexes them automatically (the status \
                        pills at the bottom show progress). Drag folders up or \
                        down to reorder them. Right-click a folder to make a \
                        New Subfolder, Rename it, Reveal it in Finder, or — \
                        for a buried subfolder — Pin it to the top. Right-click \
                        a top-level folder to Remove it from Muse. Your files \
                        are never modified; deleting means moving to the Trash, \
                        and it's undoable.
                        """)
                    rowDivider
                    section("Viewing & selecting", """
                        Muse opens almost anything in place: images, PDFs, \
                        video, audio, fonts, Markdown, and code or text. Click \
                        an image for a full-screen view with zoom, pan, and a \
                        details panel; its Share button also offers Open With. \
                        Select images in the grid with a click, ⌘-click, or \
                        Shift-click, then right-click for actions — move to a \
                        folder, add to a collection, add a tag, share, or Open \
                        With. Anything without a dedicated viewer falls back to \
                        Quick Look.
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
                    section("Search & sort", """
                        Search by name, tags, captions, and text found inside \
                        images. The magnifier menu scopes the search to the \
                        current folder or your whole library. Sort by date, \
                        name, size, color, or shape, and use the arrow beside \
                        the sort menu to flip the direction.
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
                        Share an image from the viewer — AirDrop, Mail, \
                        Messages, or Save to Files — or share a whole \
                        collection as a PDF from its header. From Finder, \
                        right-click any file and choose Share → Muse to send it \
                        into your iCloud folder.
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
                    section("Back Up & Restore", """
                        Muse keeps your collections, tags, and folder list on \
                        this Mac — not inside your files. Before moving to a new \
                        Mac, choose Muse ▸ Back Up Muse… to save one backup file; \
                        keep it somewhere safe and carry it over with your files. \
                        On the new Mac, choose Muse ▸ Restore from Backup…, point \
                        Muse at your folders, and it reconnects everything by \
                        matching each file's contents — even if you renamed or \
                        rearranged them. Collections with no files on the new Mac \
                        simply don't appear; nothing is ever left broken.
                        """)
                    rowDivider
                    section("Grid & appearance", """
                        Set the grid density with the slider at the bottom \
                        right, and turn on file names under tiles in Settings. \
                        The palette button sets the background: Light, Dark, \
                        Auto (light by day, dark at night), or a custom color.
                        """)
                    rowDivider
                    section("Settings", """
                        Muse organizes automatically, but you're in control: in \
                        Settings (⌘,) you can turn off automatic tagging or \
                        automatic collections. Existing tags and collections \
                        stay; only future automatic work is paused, and the \
                        manual commands still work.
                        """)
                    rowDivider
                    section("Updates", """
                        Muse is distributed directly (not via the App Store) \
                        and keeps itself up to date with Sparkle. It checks \
                        quietly in the background, or choose Muse ▸ Check for \
                        Updates… any time. New versions are downloaded over \
                        HTTPS and cryptographically verified before installing.
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
        .frame(width: 600, height: 720)
    }

    /// Hairline between section rows.
    private var rowDivider: some View {
        Divider()
            .padding(.vertical, 16)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                // Each section title is a heading so VoiceOver's heading rotor can
                // jump between the ~17 About sections instead of linear reading.
                .accessibilityAddTraits(.isHeader)
            Text(body)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
