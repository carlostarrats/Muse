//
//  DuplicatesView.swift
//  Muse
//
//  Review pane for found duplicate groups. Each duplicate is a grid-style tile;
//  marking one for delete draws a blue ring (the green KEEP badge tracks whatever
//  survives). Groups open with the finder's non-keeper copies pre-marked, fully
//  overridable, and a group can never be fully deleted — the delete rules live in
//  DuplicateDeleteRules. Selected files move to Trash via NSWorkspace.recycle.
//

import SwiftUI
import AppKit

struct DuplicatesView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool

    @ObservedObject private var finder = DuplicateFinder.shared

    // URLs marked for delete. Each group opens with its non-keeper duplicates
    // pre-marked (a smart default the user can freely override). The green KEEP
    // badge tracks survivors — any tile NOT in this set reads as "kept".
    @State private var selected: Set<URL> = []
    @State private var seededGroups: Set<UUID> = []
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Duplicates")
                    .font(.system(size: 24, weight: .semibold))
                Text("(\(finder.groups.count) groups)")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
                if finder.isRunning {
                    HStack(spacing: 6) {
                        ProgressView(value: finder.progress)
                            .progressViewStyle(.linear)
                            .frame(width: 100)
                        Text("Scanning…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                CloseXButton { isPresented = false }
            }
            .padding(16)

            if finder.groups.isEmpty && !finder.isRunning {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No duplicates found in this folder.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(finder.groups.enumerated()),
                                id: \.element.id) { index, group in
                            if index > 0 {
                                Divider().padding(.horizontal, 16)
                            }
                            groupRow(group)
                        }
                    }
                    // One light panel for the whole list; rows sit on it,
                    // separated by hairlines (no per-group grey cards). A faint
                    // primary tint reads as light grey on the white modal and a
                    // soft lift in dark mode — controlBackgroundColor is white in
                    // light mode and would vanish against the modal.
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .padding(20)
                }
            }

            Divider()

            HStack {
                Text("\(selected.count) selected for delete")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Delete Selected to Trash") {
                    showDeleteConfirmation = true
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { seedDefaults() }
        .onChange(of: finder.groups) { _, _ in seedDefaults() }
        .confirmationDialog(
            "Move \(selected.count) file\(selected.count == 1 ? "" : "s") to Trash?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                deleteSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files will be moved to the Trash and can be restored from there.")
        }
    }

    @ViewBuilder
    private func groupRow(_ group: DuplicateGroup) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(group.members, id: \.url) { member in
                    memberCard(
                        member,
                        isLocked: DuplicateDeleteRules.isLocked(
                            member.url,
                            groupsContaining: groupsContaining(member.url),
                            selected: selected
                        )
                    )
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func memberCard(_ member: DuplicateGroup.Member, isLocked: Bool) -> some View {
        VStack(spacing: 6) {
            DuplicateImageTile(
                member: member,
                isSelected: selected.contains(member.url),
                isLocked: isLocked,
                onToggle: { toggleDelete(member.url) }
            )
            Text(member.url.lastPathComponent)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: DuplicateImageTile.tileSize)
            Text(formatBytes(member.sizeBytes) + (member.width.map { ", \($0)×\(member.height ?? 0)" } ?? ""))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            // Second way to set the same delete state — clicking the tile and
            // ticking this checkbox stay in sync. Disabled only when this is the
            // locked last survivor of a 3+ copy group.
            Toggle("Delete", isOn: Binding(
                get: { selected.contains(member.url) },
                set: { v in
                    if v { select(member.url) }
                    else { selected.remove(member.url) }
                }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            .disabled(isLocked)
        }
    }

    /// Toggle a copy's delete state. Deselecting is always allowed; selecting
    /// goes through the rules so a group can never be fully deleted (two-copy
    /// groups swap, 3+ copy last survivors are locked). See DuplicateDeleteRules.
    private func toggleDelete(_ url: URL) {
        if selected.contains(url) { selected.remove(url) }
        else { select(url) }
    }

    private func select(_ url: URL) {
        selected = DuplicateDeleteRules.selecting(
            url, groupsContaining: groupsContaining(url), selected: selected
        )
    }

    /// Every group's member URLs for the groups `url` belongs to. A file can be
    /// in more than one group (byte-exact + filename + visual), so the delete
    /// rules must keep all of them non-empty, not just the first.
    private func groupsContaining(_ url: URL) -> [[URL]] {
        finder.groups
            .filter { $0.members.contains { $0.url == url } }
            .map { $0.members.map(\.url) }
    }

    /// Pre-mark each group's non-keeper duplicates for delete the first time we
    /// see it (groups stream in during a scan), reconcile across overlapping
    /// groups so none is left fully selected, then drop any stale selections from
    /// a previous scan. User edits persist: a group is seeded exactly once.
    private func seedDefaults() {
        for group in finder.groups where !seededGroups.contains(group.id) {
            seededGroups.insert(group.id)
            let members = group.members.map { (url: $0.url, isSuggestedKeeper: $0.isSuggestedKeeper) }
            selected.formUnion(DuplicateDeleteRules.seed(members: members))
        }
        let allGroups = finder.groups.map { $0.members.map(\.url) }
        selected = DuplicateDeleteRules.rescued(selected, groups: allGroups)
        if !selected.isEmpty {
            selected.formIntersection(Set(allGroups.flatMap { $0 }))
        }
    }

    private func formatBytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private func deleteSelected() {
        let urls = Array(selected)
        Task.detached(priority: .userInitiated) {
            for url in urls {
                NSWorkspace.shared.recycle([url], completionHandler: nil)
            }
        }
        selected.removeAll()
        // The shown groups still reference the now-trashed files and don't
        // re-derive here, so leaving the modal open looks like nothing
        // happened. Close it — the files are on their way to the Trash.
        isPresented = false
    }
}

/// Circular ✕, hover-brightening — identical to the InfoSheet close button so
/// all of Muse's modals share the same header chrome. Esc also closes.
private struct CloseXButton: View {
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

/// One duplicate as a grid-style tile. The image FITS (never crops) on a square
/// whose backdrop is transparent, so letterbox gaps and the selection inset show
/// the modal's grey card behind the tile; marking it for delete insets the image
/// and draws a blue ring at the outer edge — no tint, so the picture stays fully
/// visible. The green KEEP
/// badge shows on whatever is being kept (any tile not marked for delete). All
/// colors are fixed, independent of the app's mood palette, because this is a
/// modal. A reveal-in-Finder button sits top-trailing; clicking the tile toggles
/// its delete state (kept in sync with the Delete checkbox below it).
private struct DuplicateImageTile: View {
    let member: DuplicateGroup.Member
    let isSelected: Bool        // marked for delete
    let isLocked: Bool          // last surviving copy — can't be deleted here
    let onToggle: () -> Void

    @State private var hovering = false

    static let tileSize: CGFloat = 140
    // Match a grid tile / the Image Layout modal's selection feel.
    private static let selectionInset: CGFloat = 10
    private static let ringWidth: CGFloat = 2.5
    private static let ringCorner: CGFloat = 8
    private static let hoverVeilOpacity = 0.2

    private var isKept: Bool { !isSelected }
    // System accent (fixed blue), NOT the mood-adaptive grid accent — a modal
    // shouldn't shift its selection color with the background palette.
    private var blue: Color { Color.accentColor }

    var body: some View {
        ZStack {
            // Transparent backdrop, square frame. Letterbox gaps and the
            // selection inset reveal the modal's grey card sitting behind the
            // tile (not white) — exactly matching it, since nothing opaque is
            // drawn in the gap.
            Rectangle()
                .fill(Color.clear)

            // Image — fit, no crop. Shrinks inward when marked for delete so the
            // ring frames it, mirroring a grid tile's selection.
            AsyncThumbnail(url: member.url, size: Self.tileSize)
                .padding(isSelected ? Self.selectionInset : 0)

            // Hover darken — only on tiles that can still be toggled (not the
            // already-selected one, not the locked last survivor).
            Rectangle()
                .fill(Color.black)
                .opacity((hovering && !isSelected && !isLocked) ? Self.hoverVeilOpacity : 0)
                .allowsHitTesting(false)

            // Blue delete ring at the outer edge — NO tint over the image.
            if isSelected {
                RoundedRectangle(cornerRadius: Self.ringCorner, style: .continuous)
                    .strokeBorder(blue, lineWidth: Self.ringWidth)
            }
        }
        .frame(width: Self.tileSize, height: Self.tileSize)
        .clipShape(Rectangle())
        .overlay(alignment: .topLeading) {
            if isKept {
                Text("KEEP")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.green, in: Capsule())
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            RevealInFinderButton(url: member.url).padding(8)
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isLocked { onToggle() } }
        .onHover { hovering = $0 }
        .help(isLocked ? "At least one copy must be kept" : "")
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .animation(.easeOut(duration: 0.18), value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(member.url.lastPathComponent)
        .accessibilityValue(isSelected ? "Marked for delete" : (isLocked ? "Kept — last copy, can't delete" : "Kept"))
        .accessibilityAddTraits(.isButton)
        // VoiceOver parity with the click: activating the tile toggles delete
        // (no-op when locked), the same as the Delete checkbox below it.
        .accessibilityAction { if !isLocked { onToggle() } }
    }
}

/// Small reveal-in-Finder control on a tile — a frosted circle that brightens on
/// hover. Opens Finder with the file selected so it can be inspected full-size.
private struct RevealInFinderButton: View {
    let url: URL
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.thinMaterial))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Reveal in Finder")
    }
}

private struct AsyncThumbnail: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    // Fit, no crop — the whole image shows inside the tile;
                    // the grey backdrop fills any letterbox gap.
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            image = await ThumbnailCache.shared.thumbnail(
                for: url,
                size: CGSize(width: size, height: size)
            )
        }
    }
}
