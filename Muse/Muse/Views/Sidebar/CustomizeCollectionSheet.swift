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

    // Draft state, seeded from the stored appearance. Icon holds the symbol
    // NAME (default icon = default look); color holds the token or nil.
    @State private var draftIcon: String
    @State private var draftColor: String?

    // Hover feedback (one cell at a time, so two shared slots suffice).
    // The Default color cell hovers under a sentinel that can't collide
    // with a real token.
    @State private var hoveredColor: String?
    @State private var hoveredSymbol: String?
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
        // nil stored icon → show the kind-appropriate default (funnel vs stack).
        _draftIcon = State(initialValue: loaded.collection.icon.flatMap {
            CollectionAppearance.isValidSymbol($0) ? $0 : nil
        } ?? def)
        _draftColor = State(initialValue: loaded.collection.color)
    }

    private var isDefault: Bool {
        draftIcon == defaultIcon && draftColor == nil
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

            // A visible caption so the row replica reads as a PREVIEW, not a
            // stray second copy of the sidebar row (owner feedback).
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
            .padding(.bottom, 36)

            HStack {
                Button("Reset to Default") {
                    withAnimation(.easeOut(duration: 0.15)) {
                        draftIcon = defaultIcon
                        draftColor = nil
                    }
                }
                .disabled(isDefault)
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Update") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 480)
    }

    // MARK: - Preview

    /// An accurate replica of the sidebar row — same chevron placeholder,
    /// icon slot, name, and count metrics as CollectionSidebarRow — rendered
    /// with the DRAFT appearance on a sidebar-like backdrop.
    private var preview: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .opacity(0)
                .frame(width: 10)

            Image(systemName: draftIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CollectionAppearance.color(for: draftColor)
                                    .map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                .frame(width: 18)

            Text(loaded.collection.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            Text("\(loaded.aliveCount)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
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
        }
    }

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

    // MARK: - Save

    /// Persist the draft (default look stores nil/nil, keeping the DB clean)
    /// and reload the engine so the sidebar row repaints immediately.
    private func save() {
        let icon = draftIcon == defaultIcon ? nil : draftIcon
        let color = draftColor
        let id = loaded.collection.id
        onClose()
        Task { @MainActor in
            guard let q = Database.shared.dbQueue else { return }
            try? await CollectionStore.setAppearance(queue: q, id: id, icon: icon, color: color)
            await CollectionsEngine.shared.reload()
        }
    }
}
