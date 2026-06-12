//
//  InfoSheet.swift
//  Muse
//
//  The ⓘ modal: how the app behaves — indexing, Analyze, collections,
//  tags, search, moods, privacy. Plain-language home for the rules that
//  otherwise live in nobody's head.
//

import SwiftUI

struct InfoSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("About Muse")
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                CloseButton { isPresented = false }
            }
            .padding(.bottom, 14)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    section("Library & indexing", """
                        Add folders from the sidebar; Muse indexes them \
                        automatically (the progress bar at the bottom). Your \
                        files are never modified — deleting always means \
                        moving to the Trash, undoable.
                        """)
                    section("Analysis", """
                        After indexing, Muse automatically analyzes new or \
                        changed images with Apple's on-device Vision: tags, \
                        dominant colors, dimensions, and readable text. This \
                        powers the tag chips, the Color and Shape sorts, the \
                        viewer's color swatches, and collections. Images \
                        already analyzed are never redone, and your own tag \
                        edits always win over the machine's.
                        """)
                    section("Collections", """
                        Groupings that span your whole library, suggested \
                        after Analyze (plus any you build by hand in the \
                        viewer). They track your files: delete images or \
                        remove a folder and collections shrink to match — \
                        empty ones disappear. Open one to rename or delete \
                        it from the header.
                        """)
                    section("Tags", """
                        The chip row shows the tags of the folder you're \
                        viewing. Click a chip to filter; hover for its count. \
                        Right-click a chip to rename or delete the tag \
                        everywhere; add tags from an image's right-click menu \
                        or inside the viewer.
                        """)
                    section("Search", """
                        Searches the folder selected in the sidebar — names, \
                        tags, captions, and text found inside images.
                        """)
                    section("Background", """
                        The palette button offers Light, Dark, Auto (light by \
                        day, dark at night), and a custom color via the \
                        sliders.
                        """)
                    section("Privacy & retention", """
                        Everything happens on this Mac. Muse has no network \
                        access — nothing is uploaded, collected, or shared. \
                        If you remove a folder from the sidebar, its index \
                        data is kept for 180 days (so re-adding it restores \
                        everything instantly), then deleted automatically.
                        """)
                }
            }
        }
        .padding(20)
        .frame(width: 440, height: 480)
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
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(body)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
