//
//  DuplicatesView.swift
//  Muse
//
//  Review pane for found duplicate groups. Shows side-by-side
//  thumbnails per group, indicates suggested keeper, lets the user
//  check files to delete (move to Trash via NSWorkspace.recycle).
//

import SwiftUI
import AppKit

struct DuplicatesView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool

    @State private var selected: Set<URL> = []
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Duplicates")
                    .font(.system(size: 24, weight: .semibold))
                Text("(\(DuplicateFinder.shared.groups.count) groups)")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
                if DuplicateFinder.shared.isRunning {
                    HStack(spacing: 6) {
                        ProgressView(value: DuplicateFinder.shared.progress)
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

            if DuplicateFinder.shared.groups.isEmpty && !DuplicateFinder.shared.isRunning {
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
                        ForEach(Array(DuplicateFinder.shared.groups.enumerated()),
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
                    memberCard(member)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func memberCard(_ member: DuplicateGroup.Member) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .top) {
                AsyncThumbnail(url: member.url, size: 140)
                    .frame(width: 140, height: 140)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                if member.isSuggestedKeeper {
                    Text("KEEP")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.green, in: Capsule())
                        .padding(.top, 8)
                }
            }
            Text(member.url.lastPathComponent)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 140)
            Text(formatBytes(member.sizeBytes) + (member.width.map { ", \($0)×\(member.height ?? 0)" } ?? ""))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Toggle("Delete", isOn: Binding(
                get: { selected.contains(member.url) },
                set: { v in
                    if v { selected.insert(member.url) }
                    else { selected.remove(member.url) }
                }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            .disabled(member.isSuggestedKeeper) // can't delete the suggested keeper
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

private struct AsyncThumbnail: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    // Fill the square so the KEEP badge sits on the image,
                    // not in a letterbox gap above it.
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .task(id: url) {
            image = await ThumbnailCache.shared.thumbnail(
                for: url,
                size: CGSize(width: size, height: size)
            )
        }
    }
}
