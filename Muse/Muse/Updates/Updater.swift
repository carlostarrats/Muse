//
//  Updater.swift
//  Muse
//
//  Sparkle-backed self-update for the DIRECT-DISTRIBUTION build (Developer
//  ID + notarized, hosted on GitHub Releases). This is NOT a Mac App Store
//  feature — App Store apps update through the store and may not bundle
//  Sparkle. Muse ships outside the store, so it carries its own updater.
//
//  The updater fetches a signed appcast feed (SUFeedURL in Info.plist) over
//  HTTPS and verifies every download against the embedded EdDSA public key
//  (SUPublicEDKey). This is the ONLY network access the app makes — see the
//  network policy note in CLAUDE.md / README.
//

import SwiftUI
import Sparkle

/// Owns the single `SPUStandardUpdaterController` for the app's lifetime.
/// `startingUpdater: true` kicks off the background scheduler immediately,
/// honoring the user's "automatically check for updates" choice (Sparkle
/// shows the first-run permission prompt itself).
final class UpdaterController: ObservableObject {
    let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }
}

/// Publishes `canCheckForUpdates` so the menu item disables itself while a
/// check/download is already in flight (mirrors Sparkle's SwiftUI sample).
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// The "Check for Updates…" command. Invoking it runs a USER-INITIATED check:
/// Sparkle shows its standard modal — "You're up to date" when current, or an
/// update sheet (version, release notes, Install / Skip / Later) when one is
/// available — exactly the flow other Mac apps use.
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button(action: updater.checkForUpdates) {
            Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
