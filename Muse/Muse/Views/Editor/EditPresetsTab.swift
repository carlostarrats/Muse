//
//  EditPresetsTab.swift
//  Muse
//
//  The Looks tab: user presets, plus the copy/paste affordances.
//
//  Spec 05 replaces these rows with a live-thumbnail browser; the STORE and
//  the copy-by-value semantics stay, so that's a view change, not a data one.
//

import SwiftUI

struct EditPresetsTab: View {
    @ObservedObject var session: EditSession
    @Environment(\.theme) private var theme
    @EnvironmentObject private var appState: AppState
    @StateObject private var store = EditPresetStore.shared
    @StateObject private var clipboard = EditClipboard.shared

    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingS) {
            HStack {
                Text("Presets").font(theme.labelFont).foregroundStyle(theme.textSecondary)
                Spacer()
                Button {
                    promptForPresetName()
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Save as New Preset"))
            }

            if store.presets.isEmpty {
                Text("No presets yet")
                    .font(theme.labelFont)
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(store.presets) { preset in
                    presetRow(preset)
                }
            }

            Divider()

            Button {
                // Auto-select the groups this photo actually uses. A wall of
                // unchecked boxes is the alternative, and nobody reads it.
                clipboard.copy(session.draft,
                               groups: EditTransfer.adjustedGroups(of: session.draft))
            } label: { Text("Copy Adjustments") }
                .font(theme.labelFont)
                .buttonStyle(.plain)
                .keyboardShortcut("c", modifiers: [.command, .option])

            Button {
                session.draft = clipboard.apply(onto: session.draft)
                // ONE history push for the whole paste, not one per group.
                session.commitGesture()
            } label: { Text("Paste Adjustments") }
                .font(theme.labelFont)
                .buttonStyle(.plain)
                .disabled(!clipboard.hasContent)
                .keyboardShortcut("v", modifiers: [.command, .option])
        }
        .task { await store.load() }
    }

    private func presetRow(_ preset: EditPresetRow) -> some View {
        HStack {
            Text(preset.name)
                .font(theme.labelFont)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer()
            if hovered == preset.id {
                Button {
                    Task { await store.update(id: preset.id, from: session.draft) }
                } label: { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10)) }
                    .buttonStyle(.plain)
                    .help(Text("Update Preset from This Photo"))
                    .accessibilityLabel(Text("Update Preset from This Photo"))
                Button {
                    Task { await store.delete(id: preset.id) }
                } label: { Image(systemName: "trash").font(.system(size: 10)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Delete Preset"))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? preset.id : nil }
        .onTapGesture { apply(preset) }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(preset.name))
    }

    private func apply(_ preset: EditPresetRow) {
        guard let stack = EditStackCodec.decode(preset.stack) else { return }
        session.draft = EditTransfer.apply(groups: EditTransfer.adjustedGroups(of: stack),
                                           from: stack, onto: session.draft)
        session.commitGesture()
    }

    private func promptForPresetName() {
        let stack = session.draft
        appState.editPromptRequest = EditNamePrompt(
            title: String(localized: "Save as New Preset"),
            message: String(localized: "The crop and rotation are not saved with a preset."),
            placeholder: String(localized: "Preset name"),
            confirmTitle: String(localized: "Save")) { name in
                Task { await EditPresetStore.shared.create(name: name, stack: stack) }
            }
    }
}

/// The eyedropper toggle beside Temperature.
struct WBEyedropperButton: View {
    @ObservedObject var session: EditSession
    @Environment(\.theme) private var theme
    @State private var armed = false

    var body: some View {
        Button {
            armed.toggle()
            session.eyedropperArmed = armed
        } label: {
            Image(systemName: "eyedropper")
                .foregroundStyle(armed ? theme.controlAccent : theme.textSecondary)
        }
        .buttonStyle(.plain)
        .help(Text("Click a neutral gray area to set white balance"))
        .accessibilityLabel(Text("White balance eyedropper"))
        .onChange(of: session.eyedropperArmed) { _, value in armed = value }
    }
}
