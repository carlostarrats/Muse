//
//  SidebarView.swift
//  Muse
//
//  Multi-root folder tree (Q1, Q26). Roots are listed as top-level items;
//  each is a lazy-loading hierarchical tree. Clicking a folder selects it as
//  the active folder (Q2 Adobe Bridge style); the chevron expands/collapses
//  to reveal subfolders. Styled after Lineform's custom file browser —
//  chevron disclosure, folder icons, and rounded hover fills — rather than a
//  native List, so rows get consistent hover feedback.
//

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    /// Low-opacity fill used behind a hovered row, matching Lineform.
    static let rowHoverFillOpacity = 0.08

    /// Opaque card surface (Lineform's near-white / dark values) so the
    /// sidebar reads as one continuous card rather than a translucent panel.
    private var cardColor: Color {
        Color(nsColor: NSColor(
            calibratedWhite: colorScheme == .dark ? 0.18 : 0.988, alpha: 1
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            if appState.rootNodes.isEmpty && appState.stars.starred.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if !appState.stars.starred.isEmpty {
                            sectionHeader("Pinned")
                            ForEach(appState.stars.starred) { star in
                                StarRow(star: star)
                            }
                        }

                        ForEach(appState.rootNodes) { root in
                            FolderTreeNode(node: root, depth: 0)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                }
                .scrollContentBackground(.hidden)
            }

            AddFolderPillButton { appState.pickAndAddRoot() }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 220)
        // One continuous card: the opaque surface flows up behind the title
        // bar and curves with the window's top corner, like Lineform.
        .background(cardColor.ignoresSafeArea())
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("No files imported yet.")
                .font(.system(size: 13, weight: .semibold))
            Text("Get Started.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Folder tree node

/// One folder row plus its (lazily loaded) subfolders. Tapping the label
/// selects the folder; tapping the chevron expands/collapses it.
private struct FolderTreeNode: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var node: FolderNode
    let depth: Int

    @State private var isHovered = false

    private var hasChildren: Bool { !node.children.isEmpty }

    private var isSelected: Bool { appState.selectedFolder?.id == node.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row
            if node.isExpanded {
                ForEach(node.children) { child in
                    FolderTreeNode(node: child, depth: depth + 1)
                }
            }
        }
        // Load one level ahead so the disclosure chevron can appear for
        // folders that actually contain subfolders.
        .onAppear { node.loadChildrenIfNeeded() }
    }

    private var row: some View {
        HStack(spacing: 8) {
            // Disclosure: a real button so it captures its own taps,
            // independent of the row's selection tap. Leaves keep an
            // invisible placeholder so labels stay aligned.
            if hasChildren {
                Button(action: toggleExpand) {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0)
                    .frame(width: 10)
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor)
                                                : AnyShapeStyle(.primary))
                    .frame(width: 18)

                Text(node.displayName)
                    .font(.system(size: 13, weight: node.isRoot ? .medium : .regular))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor)
                                                : AnyShapeStyle(.primary))
                    .lineLimit(1)

                Spacer(minLength: 0)

                // Small trailing indicator when the folder is pinned.
                if appState.stars.isStarred(node.url) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { appState.select(folder: node) }
        }
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowFill)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .contextMenu {
            Button(appState.stars.isStarred(node.url) ? "Unpin" : "Pin") {
                appState.toggleStar(folder: node)
            }
            if node.isRoot {
                if let r = appState.bookmarks.roots.first(where: {
                    appState.bookmarks.url(for: $0) == node.url
                }) {
                    Divider()
                    Button("Remove Folder") { appState.removeRoot(r) }
                }
            }
        }
    }

    private var rowFill: Color {
        if isSelected {
            return Color.accentColor.opacity(0.14)
        }
        return Color.primary.opacity(isHovered ? SidebarView.rowHoverFillOpacity : 0)
    }

    private func toggleExpand() {
        node.loadChildrenIfNeeded()
        node.isExpanded.toggle()
    }
}

// MARK: - Starred row

/// A starred-folder shortcut, styled to match the folder tree rows.
private struct StarRow: View {
    @EnvironmentObject var appState: AppState
    let star: StarStore.StarredFolder

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .opacity(0)
                .frame(width: 10)

            Image(systemName: "pin.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(star.displayName)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? SidebarView.rowHoverFillOpacity : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture { appState.openStarred(star) }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .contextMenu {
            Button("Unpin") {
                appState.stars.unstar(folder: URL(fileURLWithPath: star.path))
            }
        }
    }
}

// MARK: - Add Folder pill

/// Centered high-contrast pill, styled after Lineform's action buttons —
/// dark pill / light text in light mode, reversed in dark mode, with a
/// hover brighten.
private struct AddFolderPillButton: View {
    var action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label("Add Folder", systemImage: "plus")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 16)
                .frame(height: 28)
        }
        .buttonStyle(.plain)
        .background {
            Capsule(style: .continuous).fill(fillColor)
        }
        .foregroundStyle(textColor)
        .frame(maxWidth: .infinity, alignment: .center)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
    }

    private var fillColor: Color {
        Color(nsColor: NSColor(calibratedWhite: usesDark
            ? (isHovered ? 1.0 : 0.92)
            : (isHovered ? 0.12 : 0.20),
            alpha: 1))
    }

    private var textColor: Color {
        Color(nsColor: NSColor(calibratedWhite: usesDark ? 0.10 : 1.0, alpha: 1))
    }

    private var usesDark: Bool { colorScheme == .dark }
}
