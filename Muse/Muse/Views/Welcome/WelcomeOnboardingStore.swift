//
//  WelcomeOnboardingStore.swift
//  Muse
//
//  First-run welcome lifecycle. The store owns presentation and persistence;
//  the view owns only which of its three pages is visible.
//

import Foundation

@MainActor
final class WelcomeOnboardingStore: ObservableObject {
    enum Source: Equatable {
        case automatic
        case manual
    }

    enum LaunchDecision: Equatable {
        case present
        case seedSeen
        case skip
    }

    struct LaunchEffects: Equatable {
        let decision: LaunchDecision
        let shouldFetchAnnouncements: Bool
    }

    @Published private(set) var source: Source?

    var isPresented: Bool { source != nil }
    private(set) var launchEffects: LaunchEffects?

    private let defaults: UserDefaults
    private var didPrepareForLaunch = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    nonisolated static func launchEffects(hasSeen: Bool,
                                          hasStoredUserFolder: Bool) -> LaunchEffects {
        if hasSeen {
            return LaunchEffects(decision: .skip, shouldFetchAnnouncements: true)
        }
        if hasStoredUserFolder {
            return LaunchEffects(decision: .seedSeen, shouldFetchAnnouncements: true)
        }
        return LaunchEffects(decision: .present, shouldFetchAnnouncements: false)
    }

    @discardableResult
    func prepareForLaunch(hasStoredUserFolder: Bool) -> LaunchEffects {
        if didPrepareForLaunch, let launchEffects { return launchEffects }

        let effects = Self.launchEffects(
            hasSeen: defaults.bool(forKey: AppSettings.welcomeOnboardingSeenKey),
            hasStoredUserFolder: hasStoredUserFolder)
        didPrepareForLaunch = true
        launchEffects = effects

        switch effects.decision {
        case .present:
            source = .automatic
        case .seedSeen:
            defaults.set(true, forKey: AppSettings.welcomeOnboardingSeenKey)
        case .skip:
            break
        }
        return effects
    }

    func presentManually() {
        guard source == nil else { return }
        source = .manual
    }

    func dismiss() {
        guard let source else { return }
        if source == .automatic {
            defaults.set(true, forKey: AppSettings.welcomeOnboardingSeenKey)
        }
        self.source = nil
    }
}

/// Shared modal policy for the Help command and the grid/Escape gate. Keeping
/// this pure prevents the menu and shell from growing slightly different rules.
nonisolated enum WelcomePresentationRules {
    static func canPresentManually(appModalPresented: Bool,
                                   welcomePresented: Bool,
                                   viewerPresented: Bool,
                                   comparePresented: Bool) -> Bool {
        !appModalPresented && !welcomePresented && !viewerPresented && !comparePresented
    }

    static func effectiveModalPresented(appModalPresented: Bool,
                                        welcomePresented: Bool) -> Bool {
        appModalPresented || welcomePresented
    }
}

/// Debug launch-argument seam used by the one persistence UI test. Shipping
/// builds never consult this parser.
nonisolated enum WelcomeDefaultsSuiteArgument {
    static let flag = "--welcome-defaults-suite"
    static let emptyStoredFoldersFlag = "--welcome-empty-stored-folders"

    static func suiteName(in arguments: [String]) -> String? {
        guard let flagIndex = arguments.firstIndex(of: flag),
              arguments.indices.contains(flagIndex + 1) else { return nil }
        let value = arguments[flagIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.hasPrefix("-") ? nil : value
    }

    static func usesEmptyStoredFolders(in arguments: [String]) -> Bool {
        arguments.contains(emptyStoredFoldersFlag)
    }
}
