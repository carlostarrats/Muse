//
//  WelcomeOnboardingStoreTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

@MainActor
final class WelcomeOnboardingStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "com.tarrats.MuseTests.welcome.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testUnseenWithoutFolderPresentsAndSuppressesAnnouncements() {
        let effects = WelcomeOnboardingStore.launchEffects(
            hasSeen: false, hasStoredUserFolder: false)
        XCTAssertEqual(effects, .init(decision: .present,
                                      shouldFetchAnnouncements: false))
    }

    func testUnseenWithFolderSeedsSeenAndAllowsAnnouncements() {
        let effects = WelcomeOnboardingStore.launchEffects(
            hasSeen: false, hasStoredUserFolder: true)
        XCTAssertEqual(effects, .init(decision: .seedSeen,
                                      shouldFetchAnnouncements: true))
    }

    func testSeenSkipsRegardlessOfFolderAndAllowsAnnouncements() {
        XCTAssertEqual(
            WelcomeOnboardingStore.launchEffects(hasSeen: true,
                                                  hasStoredUserFolder: false),
            .init(decision: .skip, shouldFetchAnnouncements: true))
        XCTAssertEqual(
            WelcomeOnboardingStore.launchEffects(hasSeen: true,
                                                  hasStoredUserFolder: true),
            .init(decision: .skip, shouldFetchAnnouncements: true))
    }

    func testAutomaticPreparationPresentsWithoutWritingSeen() {
        let store = WelcomeOnboardingStore(defaults: defaults)
        let effects = store.prepareForLaunch(hasStoredUserFolder: false)
        XCTAssertEqual(effects.decision, .present)
        XCTAssertEqual(store.source, .automatic)
        XCTAssertTrue(store.isPresented)
        XCTAssertFalse(defaults.bool(forKey: AppSettings.welcomeOnboardingSeenKey))
    }

    func testExistingFolderSeedsPreferenceWithoutPresenting() {
        let store = WelcomeOnboardingStore(defaults: defaults)
        XCTAssertEqual(store.prepareForLaunch(hasStoredUserFolder: true).decision,
                       .seedSeen)
        XCTAssertFalse(store.isPresented)
        XCTAssertTrue(defaults.bool(forKey: AppSettings.welcomeOnboardingSeenKey))
    }

    func testAutomaticDismissalPersistsCompletion() {
        let store = WelcomeOnboardingStore(defaults: defaults)
        store.prepareForLaunch(hasStoredUserFolder: false)
        store.dismiss()
        XCTAssertFalse(store.isPresented)
        XCTAssertTrue(defaults.bool(forKey: AppSettings.welcomeOnboardingSeenKey))
    }

    func testManualPresentationAndDismissalDoNotRewritePreference() {
        defaults.set(false, forKey: AppSettings.welcomeOnboardingSeenKey)
        let store = WelcomeOnboardingStore(defaults: defaults)
        store.presentManually()
        XCTAssertEqual(store.source, .manual)
        store.dismiss()
        XCTAssertFalse(defaults.bool(forKey: AppSettings.welcomeOnboardingSeenKey))

        defaults.set(true, forKey: AppSettings.welcomeOnboardingSeenKey)
        store.presentManually()
        store.dismiss()
        XCTAssertTrue(defaults.bool(forKey: AppSettings.welcomeOnboardingSeenKey))
    }

    func testPrepareForLaunchIsIdempotentAndEffectsStayLatched() {
        let store = WelcomeOnboardingStore(defaults: defaults)
        let first = store.prepareForLaunch(hasStoredUserFolder: false)
        store.dismiss()
        let second = store.prepareForLaunch(hasStoredUserFolder: true)
        XCTAssertEqual(second, first)
        XCTAssertEqual(store.launchEffects, first)
        XCTAssertFalse(store.isPresented)
    }

    func testManualPresentationDoesNotReplaceAnActivePresentation() {
        let store = WelcomeOnboardingStore(defaults: defaults)
        store.prepareForLaunch(hasStoredUserFolder: false)
        store.presentManually()
        XCTAssertEqual(store.source, .automatic)
    }

    func testManualAvailabilityRequiresEveryOtherSurfaceToBeClosed() {
        XCTAssertTrue(WelcomePresentationRules.canPresentManually(
            appModalPresented: false, welcomePresented: false,
            viewerPresented: false, comparePresented: false))
        XCTAssertFalse(WelcomePresentationRules.canPresentManually(
            appModalPresented: true, welcomePresented: false,
            viewerPresented: false, comparePresented: false))
        XCTAssertFalse(WelcomePresentationRules.canPresentManually(
            appModalPresented: false, welcomePresented: true,
            viewerPresented: false, comparePresented: false))
        XCTAssertFalse(WelcomePresentationRules.canPresentManually(
            appModalPresented: false, welcomePresented: false,
            viewerPresented: true, comparePresented: false))
        XCTAssertFalse(WelcomePresentationRules.canPresentManually(
            appModalPresented: false, welcomePresented: false,
            viewerPresented: false, comparePresented: true))
    }

    func testEffectiveModalRuleClosesTheMirrorTimingGap() {
        XCTAssertTrue(WelcomePresentationRules.effectiveModalPresented(
            appModalPresented: false, welcomePresented: true))
        XCTAssertTrue(WelcomePresentationRules.effectiveModalPresented(
            appModalPresented: true, welcomePresented: false))
        XCTAssertFalse(WelcomePresentationRules.effectiveModalPresented(
            appModalPresented: false, welcomePresented: false))
    }

    func testDefaultsSuiteArgumentRequiresAUsableValue() {
        XCTAssertNil(WelcomeDefaultsSuiteArgument.suiteName(in: []))
        XCTAssertNil(WelcomeDefaultsSuiteArgument.suiteName(
            in: [WelcomeDefaultsSuiteArgument.flag]))
        XCTAssertNil(WelcomeDefaultsSuiteArgument.suiteName(
            in: [WelcomeDefaultsSuiteArgument.flag, "--another-flag"]))
        XCTAssertEqual(WelcomeDefaultsSuiteArgument.suiteName(
            in: ["other", WelcomeDefaultsSuiteArgument.flag, "suite.id"]),
            "suite.id")
    }

    func testEmptyStoredFoldersPreviewFlagIsExplicit() {
        XCTAssertFalse(WelcomeDefaultsSuiteArgument.usesEmptyStoredFolders(in: []))
        XCTAssertTrue(WelcomeDefaultsSuiteArgument.usesEmptyStoredFolders(
            in: [WelcomeDefaultsSuiteArgument.emptyStoredFoldersFlag]))
    }

    func testPagesHaveFixedOrderAndBounds() {
        XCTAssertEqual(WelcomeOnboardingPage.allCases,
                       [.welcome, .organize, .share])
        XCTAssertNil(WelcomeOnboardingPage.welcome.previous)
        XCTAssertEqual(WelcomeOnboardingPage.welcome.next, .organize)
        XCTAssertEqual(WelcomeOnboardingPage.organize.previous, .welcome)
        XCTAssertEqual(WelcomeOnboardingPage.organize.next, .share)
        XCTAssertEqual(WelcomeOnboardingPage.share.previous, .organize)
        XCTAssertNil(WelcomeOnboardingPage.share.next)
    }

    func testBackAndPrimaryActionsMatchTheFlow() {
        XCTAssertFalse(WelcomeOnboardingPage.welcome.hasBack)
        XCTAssertTrue(WelcomeOnboardingPage.organize.hasBack)
        XCTAssertTrue(WelcomeOnboardingPage.share.hasBack)
        XCTAssertFalse(WelcomeOnboardingPage.welcome.isLast)
        XCTAssertFalse(WelcomeOnboardingPage.organize.isLast)
        XCTAssertTrue(WelcomeOnboardingPage.share.isLast)
        XCTAssertFalse(WelcomeOnboardingPage.welcome.hasGuideLink)
        XCTAssertFalse(WelcomeOnboardingPage.organize.hasGuideLink)
        XCTAssertTrue(WelcomeOnboardingPage.share.hasGuideLink)
    }

    func testGuideURLIsTheApprovedDestination() {
        XCTAssertEqual(AppLinks.guide.absoluteString, "https://muse-photo.com/info")
    }
}
