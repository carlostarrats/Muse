//
//  CustomizeCollectionSheet.swift
//  Muse
//
//  The right-click "Change Symbol & Color…" modal for a sidebar collection
//  (feat/next-128): a live preview of the row up top, 27 round color
//  swatches (+ Default) on the left, the curated symbol grid on the right,
//  and Cancel / Reset to Default / Update. Nothing persists until Update —
//  Reset only clears the DRAFT back to the default look.
//

import SwiftUI

struct CustomizeCollectionSheet: View {
    let loaded: CollectionStore.Loaded
    let onClose: () -> Void

    /// Which icon kind the picker is showing. An icon is EITHER an SF Symbol or
    /// an emoji, so the two grids are tabs rather than one mixed grid: they're
    /// different visual languages, and the color picker only applies to one.
    private enum IconTab: Hashable { case symbols, emoji }

    // Draft state, seeded from the stored appearance. Nothing persists until
    // Update.
    //
    // The symbol, emoji and color drafts are all held SIMULTANEOUSLY and
    // independently of the active tab, so flipping to Emoji and back restores
    // the symbol and color you had rather than silently discarding them. Only
    // `save()` collapses them down to what actually gets stored.
    @State private var iconTab: IconTab
    /// The symbol draft — always a valid SF Symbol name (default = default look).
    @State private var draftIcon: String
    /// The emoji draft. Empty when none has been chosen yet.
    @State private var draftEmoji: String
    /// The color token draft, or nil for the default look.
    @State private var draftColor: String?

    // Hover feedback (one cell at a time, so two shared slots suffice).
    // The Default color cell hovers under a sentinel that can't collide
    // with a real token.
    @State private var hoveredColor: String?
    @State private var hoveredSymbol: String?
    @State private var hoveredEmoji: String?
    private static let defaultColorHoverID = "__default__"

    /// This collection's "default" glyph — the smart funnel for a smart
    /// collection, the classic stack otherwise — so the preview and Reset match
    /// what the sidebar shows for it.
    private let defaultIcon: String

    init(loaded: CollectionStore.Loaded, onClose: @escaping () -> Void) {
        self.loaded = loaded
        self.onClose = onClose
        let isSmart = loaded.collection.smart_rules != nil
        let def = isSmart ? CollectionAppearance.smartDefaultIcon : CollectionAppearance.defaultIcon
        self.defaultIcon = def
        // Open on whichever tab matches what's stored, and seed only that
        // tab's draft from it. nil / unrenderable → the kind-appropriate
        // default symbol (funnel vs stack) on the Symbols tab.
        switch CollectionAppearance.resolve(loaded.collection.icon, default: def) {
        case .emoji(let e):
            _iconTab = State(initialValue: .emoji)
            _draftIcon = State(initialValue: def)
            _draftEmoji = State(initialValue: e)
        case .symbol(let name):
            _iconTab = State(initialValue: .symbols)
            _draftIcon = State(initialValue: name)
            _draftEmoji = State(initialValue: "")
        }
        _draftColor = State(initialValue: loaded.collection.color)
    }

    /// The emoji draft, only if it's actually renderable.
    private var validEmoji: String? {
        CollectionAppearance.isValidEmoji(draftEmoji) ? draftEmoji : nil
    }

    /// What the preview draws — and, on Update, what gets stored. On the Emoji
    /// tab an incomplete draft falls back to the symbol side so the preview is
    /// never blank.
    private var effectiveIcon: CollectionAppearance.Icon {
        if iconTab == .emoji, let e = validEmoji { return .emoji(e) }
        return .symbol(draftIcon)
    }

    /// An emoji carries its own colors, so the color token doesn't apply to it.
    private var effectiveColor: String? {
        if case .emoji = effectiveIcon { return nil }
        return draftColor
    }

    private var isDefault: Bool {
        if case .emoji = effectiveIcon { return false }
        return draftIcon == defaultIcon && draftColor == nil
    }

    /// Update is blocked only when the Emoji tab is showing an unusable draft —
    /// committing it would store nothing and silently look like a no-op.
    private var canSave: Bool {
        iconTab != .emoji || validEmoji != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Symbol & Color")
                    .font(.system(size: 24, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                SheetCloseButton { onClose() }
            }
            .padding(.bottom, 20)

            // The preview and the two palettes scroll; the action row below
            // stays pinned so Cancel/Update are reachable however short the
            // window is.
            ModalScroll {
                VStack(alignment: .leading, spacing: 0) {
                    // A visible caption so the row replica reads as a PREVIEW,
                    // not a stray second copy of the sidebar row (owner
                    // feedback).
                    Text("Live Preview")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                    preview
                        .padding(.bottom, 20)

                    HStack(alignment: .top, spacing: 24) {
                        colorColumn
                        Divider()
                        symbolColumn
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 36)

            HStack {
                Button("Reset to Default") {
                    withAnimation(.easeOut(duration: 0.15)) {
                        iconTab = .symbols
                        draftIcon = defaultIcon
                        draftEmoji = ""
                        draftColor = nil
                    }
                }
                .disabled(isDefault)
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Update") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(28)
        // Width and the height cap come from the modal presenter.
    }

    // MARK: - Preview

    /// An accurate replica of the sidebar row — same chevron placeholder,
    /// icon slot, name, and count metrics as CollectionSidebarRow — rendered
    /// with the DRAFT appearance on a sidebar-like backdrop.
    private var preview: some View {
        // Must mirror CollectionSidebarRow's geometry EXACTLY (spacing 0 +
        // explicit leading padding, SidebarView's shared metrics) — if it
        // drifts, the "Live Preview" stops previewing the row it claims to.
        HStack(spacing: 0) {
            Image(systemName: "chevron.right")
                .font(.system(size: SidebarView.chevronGlyphSize, weight: .semibold))
                .opacity(0)
                .frame(width: SidebarView.chevronSlotWidth, alignment: .trailing)

            CollectionIconView(
                icon: effectiveIcon,
                tint: CollectionAppearance.color(for: effectiveColor)
                    .map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                .padding(.leading, SidebarView.chevronToIconGap)

            Text(loaded.collection.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 8)

            Spacer(minLength: 6)

            Text("\(loaded.aliveCount)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .frame(height: SidebarView.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(SidebarView.rowHoverFillOpacity))
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quinary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Preview: \(loaded.collection.name)"))
    }

    // MARK: - Colors

    private var colorColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            // 28 cells (Default + 27 colors) in a 7-row × 4 grid whose
            // height tracks the 6×6 symbol grid beside it (owner feedback:
            // the color column should run down to align with the symbols).
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 10), count: 4),
                      spacing: 10) {
                defaultSwatch
                ForEach(CollectionAppearance.colorTokens, id: \.token) { entry in
                    swatch(entry.token, entry.color)
                }
            }

            // An emoji is drawn by the color-glyph font, so a tint either does
            // nothing or flattens it. Rather than leave a live-looking control
            // that has no effect, the whole column goes inert with a reason.
            // The draft color is KEPT — switch back to Symbols and it returns.
            if colorDisabled {
                Text("Emoji use their own colors.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(colorDisabled)
        .opacity(colorDisabled ? 0.4 : 1)
        .animation(.easeOut(duration: 0.15), value: colorDisabled)
    }

    private var colorDisabled: Bool { iconTab == .emoji }

    /// The "no color" cell, first in the grid: the same diagonal light/dark
    /// split as the nav's Auto mood swatch, since "default" here means the
    /// icon follows the standard appearance rather than a fixed color.
    private var defaultSwatch: some View {
        Button {
            draftColor = nil
        } label: {
            Circle()
                .fill(LinearGradient(
                    stops: [
                        .init(color: Mood.paperPalette.background, location: 0.5),
                        .init(color: Mood.fallbackPalette.background, location: 0.5),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 20, height: 20)
                .overlay { Circle().strokeBorder(.quaternary, lineWidth: 1) }
                .overlay { swatchRing(selected: draftColor == nil,
                                      hovered: hoveredColor == Self.defaultColorHoverID) }
        }
        .buttonStyle(.plain)
        .onHover { hoveredColor = $0 ? Self.defaultColorHoverID : nil }
        .accessibilityLabel(String(localized: "Default color"))
        .accessibilityAddTraits(draftColor == nil ? [.isButton, .isSelected] : .isButton)
    }

    private func swatch(_ token: String, _ color: Color) -> some View {
        Button {
            draftColor = token
        } label: {
            Circle()
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay { swatchRing(selected: draftColor == token,
                                      hovered: hoveredColor == token) }
        }
        .buttonStyle(.plain)
        .onHover { hoveredColor = $0 ? token : nil }
        .accessibilityLabel(CollectionAppearance.displayName(forToken: token))
        .accessibilityAddTraits(draftColor == token ? [.isButton, .isSelected] : .isButton)
    }

    /// The swatch's outer ring, with a gap so it reads on any swatch color
    /// in both appearances: full-strength when selected, a soft preview of
    /// the same ring on hover.
    @ViewBuilder private func swatchRing(selected: Bool, hovered: Bool) -> some View {
        if selected || hovered {
            Circle()
                .strokeBorder(Color.primary.opacity(selected ? 1 : 0.35), lineWidth: 2)
                .frame(width: 28, height: 28)
        }
    }

    // MARK: - Symbols

    private var symbolColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Icon")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker("Icon kind", selection: $iconTab) {
                Text("Symbols").tag(IconTab.symbols)
                Text("Emoji").tag(IconTab.emoji)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if iconTab == .symbols {
                symbolGrid
            } else {
                emojiGrid
                emojiField
            }
        }
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 6),
                  spacing: 8) {
                // First cell = this collection's NATIVE glyph (the funnel for a
                // smart collection, the stack for a normal one), shown as an
                // ordinary symbol so there's always a plain way back to the
                // original. Excluded from the rest so it's never duplicated.
                symbolCell(defaultIcon)
                ForEach(CollectionAppearance.symbols.filter {
                    $0 != CollectionAppearance.defaultIcon && $0 != defaultIcon
                }, id: \.self) { name in
                    symbolCell(name)
                }
        }
    }

    private func symbolCell(_ name: String) -> some View {
        let selected = draftIcon == name
        let hovered = hoveredSymbol == name
        return Button {
            draftIcon = name
        } label: {
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor)
                                          : AnyShapeStyle(.primary))
                .frame(width: 30, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.16)
                                       : Color.primary.opacity(hovered ? 0.10 : 0.04))
                }
                .overlay {
                    if selected || hovered {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor
                                                   : Color.primary.opacity(0.25),
                                          lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hoveredSymbol = $0 ? name : nil }
        .accessibilityLabel(CollectionAppearance.displayName(forSymbol: name))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Emoji

    /// Same 6-wide lattice and same cell chrome as the symbol grid, so the two
    /// tabs feel like one picker rather than two.
    private var emojiGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 6),
                  spacing: 8) {
            ForEach(CollectionAppearance.emojiCatalog, id: \.self) { emoji in
                emojiCell(emoji)
            }
        }
    }

    private func emojiCell(_ emoji: String) -> some View {
        let selected = draftEmoji == emoji
        let hovered = hoveredEmoji == emoji
        return Button {
            draftEmoji = emoji
        } label: {
            Text(emoji)
                .font(.system(size: 15))
                .frame(width: 30, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.16)
                                       : Color.primary.opacity(hovered ? 0.10 : 0.04))
                }
                .overlay {
                    if selected || hovered {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor
                                                   : Color.primary.opacity(0.25),
                                          lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hoveredEmoji = $0 ? emoji : nil }
        // No English name to translate — VoiceOver speaks the emoji's own
        // system name from the character itself, which is the useful reading.
        .accessibilityLabel(String(localized: "Emoji \(emoji)"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Escape hatch past the 48-emoji catalog: type or paste any single emoji,
    /// or open the system picker. Input is trimmed to its LAST grapheme cluster
    /// so pasting a string leaves one usable character rather than an error.
    private var emojiField: some View {
        HStack(spacing: 8) {
            TextField("Any emoji", text: Binding(
                get: { draftEmoji },
                set: { draftEmoji = String($0.suffix(1)) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 90)

            Button {
                NSApp.orderFrontCharacterPalette(nil)
            } label: {
                Image(systemName: "face.smiling")
            }
            .buttonStyle(.borderless)
            .help("Open the system emoji picker")
            .accessibilityLabel("Open the system emoji picker")

            Spacer(minLength: 0)
        }
    }

    // MARK: - Save

    /// Persist the draft (default look stores nil/nil, keeping the DB clean)
    /// and reload the engine so the sidebar row repaints immediately.
    private func save() {
        let icon: String?
        let color: String?
        switch effectiveIcon {
        case .emoji(let e):
            icon = CollectionAppearance.encodeEmoji(e)
            // An emoji's color IS the emoji. Persisting a dead token would
            // resurrect it if the user later switched back to a symbol, which
            // reads as the app remembering a choice they didn't make.
            color = nil
        case .symbol(let name):
            icon = name == defaultIcon ? nil : name
            color = draftColor
        }
        let id = loaded.collection.id
        onClose()
        Task { @MainActor in
            guard let q = Database.shared.dbQueue else { return }
            try? await CollectionStore.setAppearance(queue: q, id: id, icon: icon, color: color)
            await CollectionsEngine.shared.reload()
        }
    }
}
