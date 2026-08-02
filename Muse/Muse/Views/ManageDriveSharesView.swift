//
//  ManageDriveSharesView.swift
//  Muse
//
//  "Manage Drive Shares" (View menu) — lists live Drive shares Muse has made;
//  open the page link, or Delete now (unpublish = delete the Drive folder
//  immediately). Styled like the ⓘ About modal (InfoSheet).
//

import SwiftUI
import AppKit

/// Which date the Manage list sorts on, and in which direction. Not persisted —
/// the view resets to Expires · Earliest on each open (see `sortKey`/`sortOrder`).
enum DriveShareSortKey: String { case expires, created }
enum DriveShareSortOrder: String { case soonest, latest }

struct ManageDriveSharesView: View {
    @EnvironmentObject private var appState: AppState

    /// Closes the CARD. Never `@Environment(\.dismiss)`: modals stopped being
    /// sheets, so there is no presentation for it to dismiss — it walked up and
    /// closed the WINDOW instead, which quit the app (owner-reported: "pressing
    /// x on the modals is closing the whole app").
    private func dismiss() { appState.driveSharesShown = false }
    @EnvironmentObject private var googleAuth: GoogleOAuth
    private let store = DriveShareStore.default
    @State private var records: [DriveShareRecord] = []
    @State private var deleting: Set<String> = []
    @State private var didPrune = false
    // Always open on "Expires · Earliest" so the soonest-to-expire shares are at
    // the top every time (not persisted — resets on each open).
    @State private var sortKey: DriveShareSortKey = .expires
    @State private var sortOrder: DriveShareSortOrder = .soonest
    /// "Now" for the expired test, stamped once when the card opens — a `Date()`
    /// read in the body would change on every unrelated re-render (and a modal is
    /// never open long enough for a row to cross its expiry mid-session).
    @State private var openedAt = Date()

    /// Records ordered by the chosen key/direction. "Soonest" = earliest date
    /// first (ascending); "Latest" = newest first (descending).
    private var sortedRecords: [DriveShareRecord] {
        records.sorted { a, b in
            let da = sortKey == .expires ? a.expiry : a.createdAt
            let db = sortKey == .expires ? b.expiry : b.createdAt
            return sortOrder == .soonest ? da < db : da > db
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Manage Drive Shares").font(.system(size: 24, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                SheetCloseButton { dismiss() }
            }
            .padding(.bottom, 20)

            if records.isEmpty {
                Text("No Drive shares yet.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                sortControls
                    .padding(.bottom, 16)
                columnHeaders
                    .padding(.bottom, 10)
                ModalScroll {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sortedRecords.enumerated()), id: \.element.id) { index, record in
                            if index > 0 { Divider().padding(.vertical, 16) }
                            row(record)
                        }
                    }
                }
            }
        }
        .padding(28)
        // Width and the height cap come from the modal presenter.
        // The failure message is raised to the SHELL: this view IS a modal
        // card, and a card presented from inside another card would be sized
        // by it. See MuseAlert.
        .onAppear {
            openedAt = Date()          // the card can be reopened in one session
            records = store.all()      // show what we have immediately…
            guard didPrune == false else { return }
            didPrune = true
            Task { await pruneMissing() } // …then drop any whose Drive folder is gone.
        }
    }

    /// Remove rows whose Drive folder no longer exists — the user deleted/trashed
    /// it in Google Drive directly, or it belongs to a since-switched account
    /// (drive.file can't see it → 404). Network happens only here, inside this
    /// explicit "Manage" action. Conservative: prune ONLY on a definitive
    /// not-found; any thrown error (offline / auth / 5xx) is inconclusive and the
    /// record is kept, and nothing is pruned while signed out.
    private func pruneMissing() async {
        guard googleAuth.isSignedIn else { return }
        let client = DriveClient(auth: googleAuth)
        var goneIDs: [String] = []
        for record in store.all() {
            if let exists = try? await client.folderExists(id: record.folderID), exists == false {
                goneIDs.append(record.id)
            }
        }
        guard goneIDs.isEmpty == false else { return }
        store.remove(ids: goneIDs)   // single rewrite, not one per id
        records = store.all()
    }

    private var sortControls: some View {
        HStack(spacing: 8) {
            Text("Sort by").font(.system(size: 12)).foregroundStyle(.secondary)
            Picker("", selection: $sortKey) {
                Text("Expires").tag(DriveShareSortKey.expires)
                Text("Created").tag(DriveShareSortKey.created)
            }
            .labelsHidden().fixedSize()
            .accessibilityLabel(Text("Sort by"))
            Picker("", selection: $sortOrder) {
                // "Earliest/Latest" reads naturally for both a creation date and
                // an expiry date. Earliest = ascending, Latest = descending.
                Text("Earliest").tag(DriveShareSortOrder.soonest)
                Text("Latest").tag(DriveShareSortOrder.latest)
            }
            .labelsHidden().fixedSize()
            .accessibilityLabel(Text("Sort order"))
            Spacer()
        }
    }

    /// Fixed metadata column widths. The words that used to prefix every value
    /// ("10 images | created … | expires …") now live once in `columnHeaders`,
    /// so the values themselves are short enough to sit on one line — the old
    /// flowing layout wrapped the expiry date at this card's width.
    private enum MetaColumn {
        static let count: CGFloat = 40
        // "Jun 29, 2026" measures ~84pt at 13pt; the extra room is the ~1.3×
        // budget a longer locale's date needs (fr: "29 juin 2026").
        static let date: CGFloat = 108
        static let pipe: CGFloat = 17   // glyph + its breathing room
    }

    /// One metadata line laid out on the fixed columns. Headers and values go
    /// through this same function so they can't drift out of alignment.
    private func metaColumns<A: View, B: View, C: View>(
        pipes: Bool, _ a: A, _ b: B, _ c: C
    ) -> some View {
        HStack(spacing: 0) {
            a.frame(width: MetaColumn.count, alignment: .leading)
            metaPipe(pipes)
            b.frame(width: MetaColumn.date, alignment: .leading)
            metaPipe(pipes)
            c.frame(width: MetaColumn.date, alignment: .leading)
            Spacer(minLength: 0)
        }
        // A fixed column must not wrap — a date that outgrew its width would
        // put the layout back where it started. Shrink a little first, then
        // truncate.
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .truncationMode(.tail)
    }

    /// Thin column separator between the metadata fields. Decorative — hidden
    /// from VoiceOver so the "|" glyph isn't read aloud between fields. Drawn
    /// invisibly in the header row so the columns still line up.
    private func metaPipe(_ visible: Bool) -> some View {
        Text(verbatim: "|")
            .foregroundStyle(.tertiary)
            .opacity(visible ? 1 : 0)
            .frame(width: MetaColumn.pipe)
            .accessibilityHidden(true)
    }

    /// The shared context for every row's metadata, stated once at the top.
    private var columnHeaders: some View {
        metaColumns(pipes: false,
                    Text("Images"), Text("Created"), Text("Expires"))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)   // each row states its own fields
    }

    private func row(_ record: DriveShareRecord) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(record.collectionName).font(.system(size: 15, weight: .semibold))
                    if record.isPortfolio {
                        Text("Portfolio")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                // `.formatted()` (a String) rather than "\(count)": an
                // interpolated Int in a Text literal becomes a "%lld"
                // localization key, which is a key nothing should own.
                metaColumns(pipes: true,
                            Text(record.itemCount.formatted()),
                            Text(record.createdAt.formatted(date: .abbreviated, time: .omitted)),
                            // A portfolio uses the `neverExpires` sentinel — show
                            // what it means, not the year 2100. A share that is
                            // already past its expiry says so in red: the launch
                            // sweeper hard-deletes it, but until the next launch
                            // (or while signed out/offline) the row is still here,
                            // and a bare past date read as "expires then", not
                            // "gone".
                            expiryCell(record))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            // The values are bare now (the words are in the header), so VoiceOver
            // gets an explicit sentence instead of "Shopping 10 Jun 29 Jun 29".
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isExpired(record)
                ? Text("\(record.collectionName), \(record.itemCount) images, created \(record.createdAt.formatted(date: .abbreviated, time: .omitted)), expired")
                : Text("\(record.collectionName), \(record.itemCount) images, created \(record.createdAt.formatted(date: .abbreviated, time: .omitted)), expires \(record.expiry.formatted(date: .abbreviated, time: .omitted))"))
            Spacer()
            OpenLinkButton(shareName: record.collectionName) {
                // driveShares.json is plaintext in App Support — don't hand an
                // arbitrary (possibly tampered/corrupted) scheme to NSWorkspace;
                // only open URLs that are actually ours.
                if record.pageURL.hasPrefix(DriveConfig.shareBaseURL),
                   let url = URL(string: record.pageURL) { NSWorkspace.shared.open(url) }
            }
            if deleting.contains(record.id) {
                ProgressView().controlSize(.small).frame(width: 18)
            } else {
                TrashButton(shareName: record.collectionName) { Task { await delete(record) } }
            }
        }
    }

    /// Past its expiry. Portfolios are excluded explicitly rather than relying on
    /// the 2100 sentinel outliving the app.
    private func isExpired(_ record: DriveShareRecord) -> Bool {
        !record.isPortfolio && record.expiry < openedAt
    }

    /// The Expires column: "Never" for a portfolio, a red "Expired" once the date
    /// has passed, otherwise the date.
    @ViewBuilder
    private func expiryCell(_ record: DriveShareRecord) -> some View {
        if record.isPortfolio {
            Text("Never")
        } else if isExpired(record) {
            Text("Expired").foregroundStyle(.red)
        } else {
            Text(record.expiry.formatted(date: .abbreviated, time: .omitted))
        }
    }

    private func delete(_ record: DriveShareRecord) async {
        deleting.insert(record.id)
        defer { deleting.remove(record.id) }
        let client = DriveClient(auth: googleAuth)
        // Drop the local record ONLY if the folder is definitively gone.
        // `deleteFolder` treats 404 as success (already gone), so a genuinely
        // missing folder still clears the row; but a real failure (offline / 5xx
        // / auth / token-refresh throw) must KEEP the record — the share folder
        // is public (anyone-reader) and a forgotten record can never be retried
        // or swept, leaving an orphaned live link.
        do { try await client.deleteFolder(id: record.folderID) }
        catch {
            // Keep the record (the public folder may still be live), but tell the
            // user — a silent return looks like the trash button did nothing.
            appState.alertRequest = .message(
                title: String(localized: "Couldn’t Unpublish"),
                message: String(localized: "The Drive folder couldn’t be deleted — you may be offline or signed out. The share is still live; try again, or remove it from Google Drive directly."))
            return
        }
        store.remove(id: record.id)
        records = store.all()
    }
}

/// "Open Link" — a bordered button (accent label), filled on hover. Carries the
/// share name so each row's button has a distinct VoiceOver label.
private struct OpenLinkButton: View {
    let shareName: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text("Open Link")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor.opacity(hovering ? 0.18 : 0.10)))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.accentColor.opacity(0.30)))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Open the link for \(shareName)"))
        .onHover { hovering = $0 }
    }
}

/// Trash — a bordered icon button that reddens + fills on hover. Carries the
/// share name so each row's button has a distinct VoiceOver label.
private struct TrashButton: View {
    let shareName: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 13))
                .foregroundStyle(hovering ? Color.red : Color.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(hovering ? Color.red.opacity(0.12) : Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(hovering ? Color.red.opacity(0.35) : Color.primary.opacity(0.15)))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("Unpublish — delete this share's Drive folder now")
        .accessibilityLabel(Text("Unpublish the Drive share for \(shareName)"))
        .onHover { hovering = $0 }
    }
}
