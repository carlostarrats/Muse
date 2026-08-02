//
//  EditVersionsList.swift
//  Muse
//
//  Snapshots for the open photo.
//
//  ONE concept. This shipped as "Versions" and "Snapshots", which were the same
//  row in the same table with a different `kind` string — identical storage,
//  identical scope, and identical behaviour on click. Two names for one feature
//  is a question the user has to answer every time they look at it, so there is
//  one now: a snapshot. Restore it, or compare against it. The `kind` column
//  stays (append-only schema); everything new is written as "snapshot" and old
//  "version" rows list beside them, indistinguishable — because they always
//  were.
//
//  A snapshot is a SWITCHABLE stack, never a parallel grid tile: identity here
//  is path-keyed, so one file physically cannot show twice. Exactly one stack
//  is current and renders everywhere; restoring copies the chosen snapshot into
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
    @State private var saveHovering = false
    @State private var trashHovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingS) {
            HStack(alignment: .top) {
                Text("Saves your current editing state")
                    .font(theme.labelFont)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { promptForName(kind: "snapshot") } label: {
                    Text("Save")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, 10)
                        .frame(height: 18)
                        .background(Capsule(style: .continuous)
                            .fill(saveHovering ? theme.panelRaisedHover : theme.panelRaised))
                }
                .buttonStyle(.plain)
                .onHover { saveHovering = $0 }
                .accessibilityLabel(Text("Save a snapshot"))
            }

            // The same "Original" entry the Styles lists carry: the photo with
            // no edits on it. Only once something is saved — with an empty list
            // there is nothing to choose between, so a lone "Original" row is
            // just a Reset button wearing a costume.
            if !rows.isEmpty {
                originalRow
                ForEach(rows, id: \.id) { row in versionRow(row) }
            }

            // The compare picker used to sit here listing Original + every
            // snapshot — the same names the list above already shows, with the
            // same click. Only the LIGHTROOM preview isn't reachable from a
            // row, so that's all this offers now, and only when the file
            // actually carries one.
            if hasLightroomPreview {
                Divider()
                comparePicker
            }
        }
        .task(id: store.generation) { rows = await store.versions(for: session.url) }
        .task(id: session.url) { await resolveLightroomPreview() }
    }

    /// One control that says what the canvas is comparing against, instead of
    /// a loose list of names under a bare "Compare against" line — which read
    /// as three unrelated pieces of text.
    private var comparePicker: some View {
        HStack(spacing: 6) {
            Text("Compare against")
                .font(theme.labelFont)
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: 0)
            Menu {
                Button {
                    session.compareEmbeddedPreview = false
                    session.wipeAgainst = nil
                } label: { Text("Original") }
                if hasLightroomPreview {
                    Button {
                        session.wipeAgainst = nil
                        session.compareEmbeddedPreview = true
                    } label: { Text("Lightroom preview") }
                }
            } label: {
                Text(compareLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 18)
            .background(Capsule(style: .continuous).fill(theme.panelRaised))
            .accessibilityLabel(Text("Compare against"))
            .accessibilityValue(Text(compareLabel))
        }
        .padding(.top, 2)
    }

    /// The photo with no edits. Selected when that's where the photo already
    /// is, so it reads as a state and not just a button.
    private var originalRow: some View {
        let isOriginal = session.draft.normalized().isNeutral
        return HStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.system(size: 10))
                .foregroundStyle(isOriginal ? theme.selectionInk : theme.textSecondary)
            Text("Original")
                .font(theme.labelFont)
                .foregroundStyle(isOriginal ? theme.selectionInk : theme.textPrimary)
            Spacer(minLength: 0)
            if isOriginal {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.selectionInk)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isOriginal ? theme.selectionFill
                  : (hovered == "original" ? theme.panelRaised : .clear)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? "original" : nil }
        .onTapGesture { session.resetAll() }
        .accessibilityAddTraits(isOriginal ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(Text("Original"))
        .accessibilityHint(Text("Remove every edit from this photo"))
        // The trash column's width, so the rows line up under each other.
        .padding(.trailing, 30)
    }

    /// When a snapshot was taken: 24-hour time today, the date after that.
    /// Explicit `HH:mm` rather than a locale time style — 24-hour is the ask,
    /// and a locale-driven style would render 1:45 PM on most Macs.
    private func stamp(_ epoch: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        }
        return formatter.string(from: date)
    }

    /// The snapshot the canvas is currently comparing against.
    private func isCompareTarget(_ row: EditVersionRow) -> Bool {
        guard !session.compareEmbeddedPreview,
              let against = session.wipeAgainst else { return false }
        return EditStackCodec.decode(row.stack) == against
    }

    private func toggleCompare(_ row: EditVersionRow) {
        session.compareEmbeddedPreview = false
        // Choosing the current target again clears it, so this is a toggle
        // rather than a one-way trip.
        session.wipeAgainst = isCompareTarget(row) ? nil : EditStackCodec.decode(row.stack)
    }

    private func restore(_ row: EditVersionRow) {
        Task {
            await store.switchToVersion(row.id, for: session.url)
            // The stored stack is now the truth, and the old history is about a
            // stack this file no longer has.
            session.reseed(from: await store.stack(for: session.url))
            await session.renderDraft()
        }
    }

    private var compareLabel: String {
        if session.compareEmbeddedPreview { return String(localized: "Lightroom preview") }
        guard let against = session.wipeAgainst else { return String(localized: "Original") }
        if let match = rows.first(where: { EditStackCodec.decode($0.stack) == against }) {
            return EditVersionName.display(match.name)
        }
        return String(localized: "Original")
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
        HStack(spacing: 4) {
            // The RESTORE half. It used to run the full width, so the row's
            // hover fill sat under the trash and the two actions looked like
            // one control.
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(isCompareTarget(row) ? theme.selectionInk : theme.textSecondary)
                Text(EditVersionName.display(row.name))
                    .font(theme.labelFont)
                    .foregroundStyle(isCompareTarget(row) ? theme.selectionInk : theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // When it was saved. Today → 24-hour time; older → the date.
                // No "Comparing" label: the fill already says which one is
                // selected, and a word there read as an action in progress.
                Text(stamp(row.created_at))
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(isCompareTarget(row) ? theme.selectionInk
                                                          : theme.textSecondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isCompareTarget(row) ? theme.selectionFill
                      : (hovered == row.id ? theme.panelRaised : .clear)))
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? row.id : nil }
            // Click RESTORES. Comparing is the secondary act, in the menu — one
            // list, two verbs, neither of them a second concept.
            .onTapGesture { restore(row) }
            .contextMenu {
                Button { restore(row) } label: { Text("Restore These Settings") }
                Button { toggleCompare(row) } label: {
                    Text(isCompareTarget(row) ? "Stop Comparing" : "Compare Against This")
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(EditVersionName.display(row.name)))
            .accessibilityHint(Text("Restore these settings"))
            .accessibilityAction(named: Text("Compare Against This")) { toggleCompare(row) }

            // The DELETE half: its own target, its own fill, and a red RESOLVED
            // against this backdrop — a white glyph on a pale red wash was
            // unreadable on the light ones.
            Button {
                Task { await store.deleteVersion(id: row.id, for: session.url) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(trashHovered == row.id ? theme.dangerInk : theme.textPrimary)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(trashHovered == row.id ? theme.dangerFill : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { trashHovered = $0 ? row.id : nil }
            .help(Text("Delete"))
            .accessibilityLabel(Text("Delete Snapshot"))
        }
    }

    /// Name prompts go through the shell's `ModalPromptCard` seam like every
    /// other name prompt in the app — never a `.sheet`, never an `.alert`.
    private func promptForName(kind: String) {
        let stack = session.draft
        let url = session.url
        appState.editPromptRequest = EditNamePrompt(
            title: String(localized: "Save Snapshot"),
            message: String(localized: "Saves your edits as they are now, so you can bring them back later."),
            placeholder: String(localized: "Name"),
            confirmTitle: String(localized: "Save")) { name in
                Task {
                    await EditStore.shared.saveVersion(name: name, kind: kind,
                                                       stack: stack, for: url)
                }
            }
    }
}
