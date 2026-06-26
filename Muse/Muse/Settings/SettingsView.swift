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
    @AppStorage(AppSettings.autoTagKey) private var autoTag = true
    @AppStorage(AppSettings.autoCollectionsKey) private var autoCollections = true
    @AppStorage(AppSettings.showFileNamesKey) private var showFileNames = false
    @AppStorage(AppSettings.showCollectionsInSidebarKey) private var showCollectionsInSidebar = false
    @State private var authBusy = false

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
                Text("Applies to folders added from now on. Tags and collections "
                     + "you already have are kept. You can still analyze a folder "
                     + "or build your own collections by hand at any time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show file names", isOn: $showFileNames)
            } header: {
                Text("Grid")
            } footer: {
                Text("Show each file's name beneath its thumbnail in the grid.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show Collections in the Sidebar", isOn: $showCollectionsInSidebar)
            } header: {
                Text("Sidebar")
            } footer: {
                Text("Show your collections as a collapsible section beneath the "
                     + "folders, with their own sort order.")
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
                        Button("Sign Out") { Task { await runAuth { await googleAuth.signOut() } } }
                    } else {
                        Button("Sign In") { Task { await runAuth { try? await googleAuth.signIn() } } }
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

    /// Run a sign-in/out action with the busy spinner shown.
    private func runAuth(_ action: () async -> Void) async {
        authBusy = true
        await action()
        authBusy = false
    }
}

#Preview {
    SettingsView(isPresented: .constant(true))
        .environmentObject(GoogleOAuth())
}
