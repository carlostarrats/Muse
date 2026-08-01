//
//  EditVersionsList.swift
//  Muse
//
//  Versions and snapshots for the open photo.
//
//  A version is a SWITCHABLE stack, never a parallel grid tile: identity here
//  is path-keyed, so one file physically cannot show twice. Exactly one stack
//  is current and renders everywhere; switching copies the chosen version into
//  the current row, auto-preserving what was there first.
//

import SwiftUI

struct EditVersionsList: View {
    @ObservedObject var session: EditSession
    @Environment(\.theme) private var theme
    @EnvironmentObject private var appState: AppState
    @StateObject private var store = EditStore.shared

    @State private var rows: [EditVersionRow] = []
    @State private var hasLightroomPreview = false
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingS) {
            HStack {
                Text("Versions").font(theme.labelFont).foregroundStyle(theme.textSecondary)
                Spacer()
                Menu {
                    Button("Save as Version…") { promptForName(kind: "version") }
                    Button("Save Snapshot…") { promptForName(kind: "snapshot") }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("Save a version"))
            }

            if rows.isEmpty {
                Text("No saved versions")
                    .font(theme.labelFont)
                    .foregroundStyle(theme.textSecondary)
            } else {
                ForEach(rows, id: \.id) { row in
                    versionRow(row)
                }
            }

            if !rows.filter({ $0.kind == "snapshot" }).isEmpty || hasLightroomPreview {
                Divider()
                Text("Compare against").font(theme.labelFont)
                    .foregroundStyle(theme.textSecondary)
                Button("Original") {
                    session.compareEmbeddedPreview = false
                    session.wipeAgainst = nil
                }
                    .font(theme.labelFont)
                    .buttonStyle(.plain)
                if hasLightroomPreview {
                    Button("Lightroom preview") {
                        session.wipeAgainst = nil
                        session.compareEmbeddedPreview = true
                    }
                    .font(theme.labelFont)
                    .buttonStyle(.plain)
                    if session.compareEmbeddedPreview {
                        // Lightroom applies its own base render under every
                        // slider; Muse doesn't reproduce it, so the two will
                        // differ even where the numbers match.
                        Text("Lightroom's base look is not applied — results shift.")
                            .font(theme.labelFont)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(rows.filter { $0.kind == "snapshot" }, id: \.id) { row in
                    Button(row.name) {
                        session.wipeAgainst = EditStackCodec.decode(row.stack)
                    }
                    .font(theme.labelFont)
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: store.generation) { rows = await store.versions(for: session.url) }
        .task(id: session.url) { await resolveLightroomPreview() }
    }

    /// Offered only for a Lightroom-imported stack that actually carries an
    /// embedded preview — `EmbeddedPreview` reads embedded bytes only, so a
    /// plain JPEG legitimately returns nil and the option simply isn't there.
    private func resolveLightroomPreview() async {
        guard session.draft.origin == .lightroom else {
            hasLightroomPreview = false
            return
        }
        let url = session.url
        hasLightroomPreview = await Task.detached(priority: .userInitiated) {
            EmbeddedPreview.image(for: url, maxPixel: 512) != nil
        }.value
    }

    private func versionRow(_ row: EditVersionRow) -> some View {
        HStack {
            Image(systemName: row.kind == "snapshot" ? "camera" : "clock.arrow.circlepath")
                .font(.system(size: 10))
                .foregroundStyle(theme.textSecondary)
            Text(EditVersionName.display(row.name))
                .font(theme.labelFont)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer()
            if hovered == row.id {
                Button {
                    Task { await store.deleteVersion(id: row.id, for: session.url) }
                } label: {
                    Image(systemName: "trash").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Delete Version"))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? row.id : nil }
        .onTapGesture {
            Task {
                await store.switchToVersion(row.id, for: session.url)
                // The stored stack is now the truth, and the old history is
                // about a stack this file no longer has.
                session.reseed(from: await store.stack(for: session.url))
                await session.renderDraft()
            }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(EditVersionName.display(row.name)))
        .accessibilityAction(named: Text("Delete Version")) {
            Task { await store.deleteVersion(id: row.id, for: session.url) }
        }
    }

    /// Name prompts go through the shell's `ModalPromptCard` seam like every
    /// other name prompt in the app — never a `.sheet`, never an `.alert`.
    private func promptForName(kind: String) {
        let stack = session.draft
        let url = session.url
        appState.editPromptRequest = EditNamePrompt(
            title: kind == "snapshot"
                ? String(localized: "Save Snapshot")
                : String(localized: "Save as Version"),
            message: kind == "snapshot"
                ? String(localized: "A snapshot is something to compare against later.")
                : String(localized: "A version is a saved stack you can switch back to."),
            placeholder: String(localized: "Name"),
            confirmTitle: String(localized: "Save")) { name in
                Task {
                    await EditStore.shared.saveVersion(name: name, kind: kind,
                                                       stack: stack, for: url)
                }
            }
    }
}
