//
//  SidebarRows.swift
//  Muse
//
//  Small sidebar subviews: StarRow, AddFolderPillButton, SectionHeader, AddPillButton.
//  Extracted verbatim from SidebarView.swift in the 2026-06-20 code-health
//  refactor (file moves only; `private` types became internal so they can live
//  in their own files). Behavior unchanged.
//

import SwiftUI
import AppKit

// MARK: - Starred row

/// A starred-folder shortcut, styled to match the folder tree rows.
struct StarRow: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.sidebarReordering) private var isReordering
    let star: StarStore.StarredFolder

    @State private var isHovered = false

    var body: some View {
        // spacing 0 + explicit leading padding, matching the folder tree's row
        // geometry so the pin icon lands on the shared icon column (see the
        // invariant on SidebarView.chevronSlotWidth). A pinned folder is never
        // expandable, so the chevron slot is always an invisible placeholder.
        HStack(spacing: 0) {
            Image(systemName: "chevron.right")
                .font(.system(size: SidebarView.chevronGlyphSize, weight: .semibold))
                .opacity(0)
                .frame(width: SidebarView.chevronSlotWidth, alignment: .trailing)
                .accessibilityHidden(true)

            Image(systemName: "pin.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.leading, SidebarView.chevronToIconGap)
                .accessibilityHidden(true)

            Text(star.displayName)
                .font(.system(size: 13))
                .lineLimit(1)
                .padding(.leading, 8)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: SidebarView.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isHovered && !isReordering ? SidebarView.rowHoverFillOpacity : 0))
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
struct AddFolderPillButton: View {
    var action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label("Add Folder", systemImage: "plus")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 16)
                .frame(height: 28)
                // Without this, the tap/hover region hugs the glyphs' actual
                // ink (icon + text runs) rather than the full label box —
                // the padding gaps read as visually part of the pill but
                // were dead space to the pointer.
                .contentShape(Rectangle())
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
        .help("Add Folder")
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


// MARK: - Section header

/// A gray uppercase section label with a trailing circular collapse/expand
/// button — the +/× toggle from the hero viewer, tuned for the light sidebar.
/// `+` when collapsed, rotates 45°→`×` when expanded; same spring motion.
struct SectionHeader<Accessory: View>: View {
    let title: String
    @Binding var collapsed: Bool
    /// Sits immediately after the title — the section's sort control. Inline
    /// rather than on its own row below: a full "Sort: Manual" line read as a
    /// list item, competing with the folders under it.
    @ViewBuilder var accessory: () -> Accessory
    @State private var hovering = false

    init(title: String, collapsed: Binding<Bool>,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self._collapsed = collapsed
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                // Expose the new sidebar sections to VoiceOver's heading rotor so
                // the FOLDERS / COLLECTIONS structure is navigable.
                .accessibilityAddTraits(.isHeader)
            accessory()
            Spacer()
            Button {
                // `collapsed` is a plain @State binding, so withAnimation spins
                // the +/× AND animates the section content show/hide together —
                // the hero modal's expand/collapse feel.
                withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                    collapsed.toggle()
                }
            } label: {
                Image(systemName: collapsed ? "plus" : "minus")   // + collapsed, − expanded
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary.opacity(hovering ? 1.0 : 0.8))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(hovering ? 0.16 : 0.08)))
                    .contentTransition(.identity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? String(localized: "Expand \(title.capitalized)")
                                          : String(localized: "Collapse \(title.capitalized)"))
            .onHover { hovering = $0 }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}


// MARK: - Compact add pill (two-up bottom bar)

/// Icon-only "+ <glyph>" capsule for the two-up bottom bar (Add Folder / Add
/// Collection). Mirrors AddFolderPillButton's fill so the two read as a set.
struct AddPillButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                Image(systemName: systemImage)
            }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            // Without this, the tap/hover region hugs the two small glyphs
            // centered in the middle of the capsule rather than the full
            // stretched (`maxWidth: .infinity`) width — most of the visible
            // pill was dead space to the pointer.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background { Capsule(style: .continuous).fill(fillColor) }
        .foregroundStyle(textColor)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .help(label)
        .accessibilityLabel(label)
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

// MARK: - Section sort control

/// The sort control that lives beside a sidebar section's title (FOLDERS /
/// COLLECTIONS). Icon-only, using the SAME glyph as the grid's toolbar sort
/// menu so "sort" reads identically in both places.
///
/// It turns ACCENT when the section is in Manual order — manual is the one mode
/// where the on-screen order is something the user arranged by hand rather than
/// a rule, so it's worth signalling at a glance. Every other mode uses the
/// header's own secondary color, so the control recedes into the label.
struct SectionSortMenu<Mode: Hashable & Identifiable>: View {
    let modes: [Mode]
    let label: (Mode) -> String
    let current: Mode
    /// True when `current` is the manual/hand-arranged mode.
    let isManual: Bool
    let accessibilityTitle: String
    let select: (Mode) -> Void

    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(modes) { mode in
                Button { select(mode) } label: {
                    if mode == current {
                        Label(NSLocalizedString(label(mode), comment: "Sidebar sort mode"),
                              systemImage: "checkmark")
                    } else {
                        Text(NSLocalizedString(label(mode), comment: "Sidebar sort mode"))
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.and.down.text.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isManual ? AnyShapeStyle(Color.accentColor)
                                          : AnyShapeStyle(.secondary))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0)))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(accessibilityTitle)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(NSLocalizedString(label(current), comment: "Sidebar sort mode"))
    }
}
