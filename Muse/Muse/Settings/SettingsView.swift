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
    @State private var authBusy = false

    /// Live iCloud folder state, driving the Show-iCloud toggle's enabled state
    /// and footer note.
    private var iCloudPresence: ICloudSidebarVisibility.Presence {
        ICloudSidebarVisibility.presence(
            configured: appState.iCloudFolderURL != nil,
            recursiveFileCount: appState.iCloudFolderURL
                .flatMap { appState.folderStats.stat(for: $0)?.recursiveFileCount })
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

            settingsForm
        }
        // Match the Info modal's width, but size the height to the content so
        // every section is visible without a tall, mostly-empty sheet.
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
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
            } header: {
                Text("Grid")
            } footer: {
                Text("Show each file's name beneath its thumbnail in the grid. Star ratings still show inside a collection and in the viewer.")
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
                        HoverButton(title: String(localized: "Sign Out")) {
                            Task { await runAuth { await googleAuth.signOut() } }
                        }
                    } else {
                        HoverButton(title: String(localized: "Sign In")) {
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
