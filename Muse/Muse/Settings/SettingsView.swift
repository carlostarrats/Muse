//
//  SettingsView.swift
//  Muse
//
//  The Preferences window (app menu → Settings…, ⌘,). Holds the automatic-
//  organization opt-outs. Both default ON; turning one off only affects
//  folders processed afterward — nothing already done is removed or redone,
//  and the manual paths (Analyze / Regenerate Tags, hand-made collections)
//  keep working. The accessors live in AppSettings (read by the pipeline).
//

import SwiftUI

struct SettingsView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var googleAuth: GoogleOAuth
    @EnvironmentObject private var appState: AppState
    @AppStorage(AppSettings.autoTagKey) private var autoTag = true
    @AppStorage(AppSettings.autoCollectionsKey) private var autoCollections = true
    @AppStorage(AppSettings.showFileNamesKey) private var showFileNames = false
    @AppStorage(AppSettings.showStarsOnGridKey) private var showStarsOnGrid = true
    @AppStorage(AppSettings.showCollectionsInSidebarKey) private var showCollectionsInSidebar = true
    @AppStorage(AppSettings.showICloudFolderInSidebarKey) private var showICloudFolder = true
    @AppStorage(AppSettings.gridSpacingKey) private var gridSpacing =
        AppSettings.defaultGridSpacing
    @AppStorage(AppSettings.gridCornerRadiusKey) private var gridCornerRadius =
        AppSettings.defaultGridCornerRadius
    @State private var authBusy = false

    /// A labelled slider with its current value in points on the right — the
    /// shape the grid's two continuous settings share.
    ///
    /// The label and the readout are folded INTO the slider's own accessibility
    /// (label + value) and hidden as separate elements. Combining the HStack
    /// instead would merge the slider into a plain group and strip its
    /// adjustable trait, leaving VoiceOver able to read the setting but not
    /// change it.
    /// One labeled slider as a `GridRow`, so every slider in the same `Grid`
    /// gets the SAME track length.
    ///
    /// As plain `HStack`s each slider started after its own title, so "Spacing"
    /// and "Corner Radius" produced visibly different track widths. A fixed
    /// width on the title would equalize them but truncate a longer localized
    /// label (French runs ~1.3× English); a Grid's first column sizes itself to
    /// the widest label in the group, which holds in every language.
    private func measuredSlider(title: String,
                                value: Binding<Double>,
                                range: ClosedRange<Double>,
                                clamp: @escaping (Double) -> Double) -> some View {
        let points = Int(clamp(value.wrappedValue))
        return GridRow {
            Text(title)
                .gridColumnAlignment(.leading)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { clamp(value.wrappedValue) },
                                  set: { value.wrappedValue = clamp($0.rounded()) }),
                   in: range, step: 1)
                .accessibilityLabel(title)
                .accessibilityValue(Text("\(points) pt"))
            Text("\(points) pt")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    /// Live iCloud folder state, driving the Show-iCloud toggle's enabled state
    /// and footer note.
    private var iCloudPresence: ICloudSidebarVisibility.Presence {
        ICloudSidebarVisibility.presence(
            configured: appState.iCloudFolderURL != nil,
            recursiveFileCount: appState.iCloudFolderURL
                .flatMap { appState.folderStats.stat(for: $0)?.knownRecursiveFileCount })
    }

    /// Footer note beneath the Show-iCloud toggle — explains the disabled/hidden
    /// state in each iCloud presence case.
    @ViewBuilder private var iCloudFooterNote: some View {
        switch iCloudPresence {
        case .hasFiles:
            Text("The iCloud folder contains files, so it can't be hidden.")
        case .notConfigured:
            Text("iCloud isn't set up, so the folder isn't in the sidebar. It'll appear here when iCloud is available.")
        case .empty, .unknown:
            Text("Hide the empty iCloud folder from the sidebar. It reappears automatically if files are added.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.system(size: 24, weight: .semibold))
                Spacer()
                SheetCloseButton { isPresented = false }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 4)

            // A Form is greedy vertically — it filled the card's whole height
            // cap regardless of how many rows it had. Pinned to its natural
            // height; the modal presenter adds a scroller if the card outgrows
            // the window.
            settingsForm
                .fixedSize(horizontal: false, vertical: true)
        }
        // Width and the height cap come from the modal presenter.
    }

    private var settingsForm: some View {
        Form {
            Section {
                Toggle("Automatically tag new images", isOn: $autoTag)
                Toggle("Automatically organize into collections", isOn: $autoCollections)
            } header: {
                Text("Automatic organization")
            } footer: {
                Text("Applies to folders added from now on. Tags and collections you already have are kept. You can still analyze a folder or build your own collections by hand at any time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show file names", isOn: $showFileNames)
                Toggle("Show star ratings", isOn: $showStarsOnGrid)
                // One Grid around both: it's what makes the two tracks the same
                // length (see measuredSlider).
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    measuredSlider(
                        title: String(localized: "Spacing"),
                        value: $gridSpacing,
                        range: AppSettings.gridSpacingRange,
                        clamp: AppSettings.clampGridSpacing)
                    measuredSlider(
                        title: String(localized: "Corner Radius"),
                        value: $gridCornerRadius,
                        range: AppSettings.gridCornerRadiusRange,
                        clamp: AppSettings.clampGridCornerRadius)
                }
            } header: {
                Text("Grid")
            } footer: {
                Text("Show each file's name beneath its thumbnail in the grid. Star ratings still show inside a collection and in the viewer. Rounded corners carry into the viewer, so a photo keeps its shape when you open it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show Collections in the Sidebar", isOn: $showCollectionsInSidebar)
                Toggle("Show iCloud Folder in the Sidebar", isOn: $showICloudFolder)
                    .disabled(ICloudSidebarVisibility.toggleDisabled(iCloudPresence))
            } header: {
                Text("Sidebar")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Show your collections as a collapsible section beneath the folders, with their own sort order.")
                    iCloudFooterNote
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text(googleAuth.isSignedIn
                         ? String(localized: "Signed in to Google")
                         : String(localized: "Not signed in"))
                    Spacer()
                    if authBusy {
                        ProgressView().controlSize(.small)
                    } else if googleAuth.isSignedIn {
                        ModalButton(title: String(localized: "Sign Out")) {
                            Task { await runAuth { await googleAuth.signOut() } }
                        }
                    } else {
                        ModalButton(title: String(localized: "Sign In")) {
                            Task { await runAuth { try? await googleAuth.signIn() } }
                        }
                    }
                }
            } header: {
                Text("Google Drive")
            } footer: {
                Text("Sign in to publish a collection as a shareable Drive web page. Sign out to switch to a different Google account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// Run a sign-in/out action with the busy spinner shown. Guards against a
    /// double-tap starting two flows (two browser prompts) before the button
    /// swaps to the spinner.
    private func runAuth(_ action: () async -> Void) async {
        guard !authBusy else { return }
        authBusy = true
        await action()
        authBusy = false
    }
}

#Preview {
    SettingsView(isPresented: .constant(true))
        .environmentObject(GoogleOAuth())
        .environmentObject(AppState())
}
