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
                    .font(.title3.weight(.semibold))
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
                Button("Close") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

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
                    VStack(spacing: 24) {
                        ForEach(DuplicateFinder.shared.groups) { group in
                            groupCard(group)
                        }
                    }
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
    private func groupCard(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: badgeIcon(group.reason))
                    .foregroundStyle(badgeColor(group.reason))
                Text(group.reason.displayName)
                    .font(.subheadline.weight(.medium))
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(group.members.count) files")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(group.members, id: \.url) { member in
                        memberCard(member)
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func memberCard(_ member: DuplicateGroup.Member) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
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
                        .padding(6)
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

    private func badgeIcon(_ r: DuplicateGroup.Reason) -> String {
        switch r {
        case .byteExact: return "equal.circle"
        case .visual:    return "eye.circle"
        case .filename:  return "textformat.abc"
        }
    }

    private func badgeColor(_ r: DuplicateGroup.Reason) -> Color {
        switch r {
        case .byteExact: return .green
        case .visual:    return .blue
        case .filename:  return .orange
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
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            image = await ThumbnailCache.shared.thumbnail(
                for: url,
                size: CGSize(width: size, height: size)
            )
        }
    }
}
