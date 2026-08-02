//
//  EditorPanel.swift
//  Muse
//
//  The editor's left and right columns.
//
//  They are the Preview page's info column in a different mode, not a second
//  design: same translucent cards, same small-caps headings, same ＋/− expander,
//  starting on the same line as the Preview | Edit switch. Before this they were
//  single undifferentiated tab panels, which is why everything crowded into one
//  scroll-less column and nothing said what it was.
//
//  The column runs the FULL height of the viewer and holds its top offset as
//  content padding, exactly like the Preview column. That's what lets a card
//  scroll up off the top of the window instead of being sliced off at a panel
//  edge partway down the screen.
//
//  Colours come from PanelContrast, never from a brightness guess — see there.
//

import SwiftUI

/// One scrollable column of section cards.
struct EditorPanel<Content: View, Chrome: View>: View {
    /// The CARD width. The column is this + 24, because the cards sit inside a
    /// 12pt inset — the Preview column's exact construction, so a card is the
    /// same width in both modes.
    var width: CGFloat = ViewerGeometry.columnWidth
    /// Where the first row sits.
    let topInset: CGFloat
    let ink: PanelContrast.Ink
    /// The canvas is zoomed, so the photo is running under this panel: bring
    /// up the solid backing, exactly as the Preview column does.
    var backingVisible: Bool = false
    /// Optional chrome row carried as the column's FIRST ROW — inside the
    /// scroll, exactly like the Preview column's, so it rides up with the
    /// content instead of the content being clipped underneath it.
    @ViewBuilder var chrome: () -> Chrome
    @ViewBuilder var content: Content

    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                chrome()
                    .padding(.bottom, 12)   // 14 + 12 = 26, the Preview column's
                content
            }
            .padding(12)
            // The backing wraps the CONTENT only. Applied after the top inset
            // it also painted the empty space above the first card, which read
            // as two big slabs hanging off the top of the window while zoomed.
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(ink.backing.opacity(0.94))
                    .opacity(backingVisible ? 1 : 0)
                    // In fast so it lands before the zoom finishes, out
                    // unhurried — the Preview column's own timing.
                    .animation(backingVisible ? .easeOut(duration: 0.08)
                                              : .easeOut(duration: 0.3),
                               value: backingVisible)
            )
            .padding(.top, topInset - 12)
            .padding(.bottom, 24)
        }
        .frame(width: width + 24)
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.theme, theme.onPanel(ink))
        // System controls (sliders, checkboxes) inside the cards follow the
        // backdrop, not the app's mood.
        .environment(\.colorScheme, ink.isDark ? .light : .dark)
    }
}

/// One card inside a panel: heading, ＋/− expander, springing content.
struct EditorSection<Content: View>: View {
    let title: String
    let ink: PanelContrast.Ink
    /// Optional control in the heading, left of the expander — the per-card
    /// Reset. Type-erased so callers don't need a second generic parameter for
    /// the common case of not having one.
    var accessory: AnyView? = nil
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        InfoCard(fill: ink.cardFill) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    CardLabel(text: title, color: ink.labelText)
                    Spacer()
                        // The heading is the hit target, not just the little
                        // ＋/− disc. Buttons inside it are hit-tested first, so
                        // the accessory and the disc keep their own actions.
                        .contentShape(Rectangle())
                    // Only while the card is open: a Reset on a collapsed card
                    // would throw away work the user can't see.
                    if isExpanded, let accessory { accessory }
                    PlusCircleButton(
                        size: 18,
                        rotated: isExpanded,
                        ink: ink.baseColor,
                        accessibilityLabel: isExpanded ? String(localized: "Collapse section")
                                                       : String(localized: "Expand section")
                    ) { toggle() }
                }
                .contentShape(Rectangle())
                .onTapGesture { toggle() }
                .accessibilityElement(children: .contain)
                if isExpanded {
                    content()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func toggle() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { isExpanded.toggle() }
    }
}

/// A named tool row: glyph, label, optional active state.
///
/// The tools used to be a row of bare glyphs in a small capsule under the
/// canvas — eight icons with no words, which is a quiz, not a toolbar. Each one
/// says what it does now, and they live in the left panel with everything else.
struct EditorToolRow: View {
    let systemName: String
    let label: String
    /// The tool is currently ON.
    var isActive: Bool = false
    var isEnabled: Bool = true
    /// MOMENTARY rows (press-and-hold) pass this instead of `action`: down is
    /// true, up is false, and there is no sticky state to get stuck in.
    var onPressChanged: ((Bool) -> Void)? = nil
    var action: () -> Void = {}

    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        if let onPressChanged {
            row
                .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) {
                } onPressingChanged: { onPressChanged($0) }
                .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
                // VoiceOver can't hold a button down, so activation is a
                // momentary flash of the same state.
                .accessibilityAction {
                    onPressChanged(true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { onPressChanged(false) }
                }
        } else {
            Button(action: action) { row }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityLabel(Text(label))
                .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        }
    }

    private var row: some View {
        Group {
            HStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                    // The glyph matches the label — one colour per state.
                    .foregroundStyle(isActive ? theme.selectionInk : theme.textPrimary)
                    .frame(width: 14)
                Text(label)
                    .font(theme.labelFont)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(isActive ? theme.selectionInk : theme.textPrimary)
                Spacer(minLength: 0)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                // Derived from the panel's own fill, so hover and the active
                // wash follow the backdrop the same way the type does.
                // theme.selectionFill is capped so the panel's ink still
                // clears AA on top of it — see PanelContrast.selectionAlpha.
                .fill(isActive ? theme.selectionFill
                      : (hovering && isEnabled ? theme.panelRaised : .clear)))
            .contentShape(Rectangle())
        }
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(label))
    }
}

/// A disclosure row that reads as a button: chevron, name, whole row clickable.
///
/// The system `DisclosureGroup`'s hit target is the little chevron alone, which
/// is why "Zone Sliders" felt like it didn't open.
struct EditorDisclosureRow: View {
    let label: String
    @Binding var isExpanded: Bool

    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(label)
                    .font(theme.labelFont)
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? theme.panelRaisedHover : theme.panelRaised))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(isExpanded ? "Expanded" : "Collapsed"))
    }
}

/// A small bordered button for inside a card (Reset and friends).
struct EditorSmallButton: View {
    let label: String
    var systemName: String?
    var action: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let systemName {
                    Image(systemName: systemName).font(.system(size: 8, weight: .bold))
                }
                // A touch under the panel's label font: this rides in a card
                // heading beside the 18pt ＋/− disc and has to match its height.
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule(style: .continuous)
                .fill(hovering ? theme.panelRaisedHover : theme.panelRaised))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(label))
    }
}
