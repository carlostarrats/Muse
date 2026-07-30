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
                .frame(width: SidebarView.chevronSlotWidth, alignment: .leading)
                .accessibilityHidden(true)

            Image(systemName: "pin.fill")
                .font(.system(size: SidebarView.rootIconSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.leading, SidebarView.chevronToIconGap)
                .accessibilityHidden(true)

            Text(star.displayName)
                .font(.system(size: 13))
                .lineLimit(1)
                .padding(.leading, SidebarView.iconToTextGap)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, SidebarView.rowHorizontalPadding)
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
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
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
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary.opacity(hovering ? 1.0 : 0.8))
                    .frame(width: 16, height: 16)
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

/// "+ <glyph> <label>" capsule for the two-up bottom bar (Add Folder / Add
/// Collection): a quiet neutral pill, since these are secondary actions sitting
/// under the whole sidebar rather than the primary thing on screen.
///
/// NOTE: `AddFolderPillButton` — the single full-width CTA shown on an empty
/// library — deliberately keeps its high-contrast fill. There it IS the primary
/// action and the only control on screen, so the two are not meant to match.
struct AddPillButton: View {
    let systemImage: String
    /// Full action name — the tooltip and the VoiceOver label ("Add Folder").
    let label: String
    /// Short form drawn inside the pill ("Folder"), where the + already says
    /// "add" and repeating it wastes the width the label needs.
    let shortLabel: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            // spacing 0 + explicit gaps so the +/icon pair can be tightened on
            // its own: they read as one mark, while the label keeps its own
            // breathing room.
            HStack(spacing: 0) {
                // The + is a modifier on the kind glyph, not a peer of it, so it
                // reads better a size down. At equal size the two competed and
                // the pair looked heavy.
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.leading, 3)
                // Always drawn, and allowed to TRUNCATE rather than be dropped:
                // at the sidebar's 220pt minimum "Collection" doesn't fit, and a
                // half-word with an ellipsis still says what the button is where
                // a bare glyph doesn't. No `fixedSize` for the same reason — it
                // would refuse to compress and push the pill out of bounds.
                Text(shortLabel)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 5)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            // Without this, the tap/hover region hugs the glyphs centered in the
            // middle of the capsule rather than the full stretched
            // (`maxWidth: .infinity`) width — most of the visible pill was dead
            // space to the pointer.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background { Capsule(style: .continuous).fill(fillColor) }
        // A shade off full strength: black read too hard against the pale pill,
        // but much lighter and it stopped looking like a control. An opacity
        // rather than a fixed grey so it inverts with the appearance.
        .foregroundStyle(Color.primary.opacity(0.85))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .help(label)
        .accessibilityLabel(label)
    }

    /// A soft neutral wash rather than the near-black/near-white slab this used
    /// to be: at the bottom of a quiet sidebar, a full-contrast pill read as the
    /// loudest thing on screen for what is a secondary action. `Color.primary`
    /// inverts with the appearance, so one expression covers both, and it sits
    /// in the same family as the section headers' toggle and the row hover fill.
    private var fillColor: Color {
        Color.primary.opacity(isHovered ? 0.14 : 0.07)
    }
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
/// The sort glyph, sized by an NSImage SYMBOL CONFIGURATION rather than a
/// SwiftUI `.font`. `.menuStyle(.borderlessButton)` repaints its label — it
/// overrode the font exactly the way it overrode `foregroundStyle` (verified:
/// shrinking the font left the drawn glyph unchanged and only its frame moved).
/// A configured NSImage carries its own intrinsic size, which the style can't
/// override; `isTemplate` keeps it tintable so the Manual-mode accent applies.
///
/// Lives outside `SectionSortMenu` because that type is generic and Swift has
/// no static stored properties in a generic type.
enum SidebarSortGlyph {
    static let pointSize: CGFloat = 11

    static let image: Image = {
        let name = "arrow.up.and.down.text.horizontal"
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            return Image(systemName: name)
        }
        img.isTemplate = true
        return Image(nsImage: img)
    }()
}

struct SectionSortMenu<Mode: Hashable & Identifiable>: View {
    let modes: [Mode]
    /// Already-LOCALIZED display name for a mode (`FolderSortMode.label` and
    /// friends return `String(localized:)` values). Do NOT run these through
    /// `NSLocalizedString` again — that looks the translated text up as if it
    /// were a key, which only appears to work because the lookup falls back to
    /// the string it was handed.
    let label: (Mode) -> String
    let current: Mode
    /// True when `current` is the manual/hand-arranged mode.
    let isManual: Bool
    let accessibilityTitle: String
    let select: (Mode) -> Void

    @State private var hovering = false

    /// Accent ONLY while the section is hand-arranged — manual is the one mode
    /// where the on-screen order is something the user built rather than a rule.
    /// Every other mode uses the header's own secondary grey so the control
    /// recedes into the label beside it.
    private var glyphColor: Color {
        isManual ? SidebarView.selectedLabelColor : .secondary
    }


    var body: some View {
        Menu {
            ForEach(modes) { mode in
                Button { select(mode) } label: {
                    if mode == current {
                        Label(label(mode), systemImage: "checkmark")
                    } else {
                        Text(label(mode))
                    }
                }
            }
        } label: {
            SidebarSortGlyph.image
                .frame(width: 15, height: 15)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0)))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // On the MENU, not just its label image: a menu style paints its own
        // label content, so a font/foregroundStyle applied INSIDE the label is
        // overridden — the control never turned accent in Manual, and a font
        // set on the Image left the glyph full-size (only its frame shrank).
        // The 14pt frame is a HIT TARGET around a deliberately small glyph.
        .font(.system(size: 7, weight: .semibold))
        .foregroundStyle(glyphColor)
        .tint(glyphColor)
        .onHover { hovering = $0 }
        .help(accessibilityTitle)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(label(current))
    }
}
