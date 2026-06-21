import XCTest
@testable import Muse

final class EscapeActionTests: XCTestCase {

    // MARK: - Viewer always wins (guards the delicate hero-close path)

    func testHeroViewerOpenClosesHero() {
        let action = EscapeResolver.action(hasSelectedFile: true,
                                           selectedFileIsHero: true,
                                           searchActive: false,
                                           tagsActive: false,
                                           insideCollection: false,
                                           showingCollectionsPage: false)
        XCTAssertEqual(action, .closeHero)
    }

    func testNonHeroViewerOpenClosesViewer() {
        let action = EscapeResolver.action(hasSelectedFile: true,
                                           selectedFileIsHero: false,
                                           searchActive: false,
                                           tagsActive: false,
                                           insideCollection: false,
                                           showingCollectionsPage: false)
        XCTAssertEqual(action, .closeViewer)
    }

    func testHeroOpenInsideCollectionStillClosesHero() {
        // Viewer takes priority over any back-out so Escape never disturbs the
        // hero return flight while a collection is also open underneath it.
        let action = EscapeResolver.action(hasSelectedFile: true,
                                           selectedFileIsHero: true,
                                           searchActive: true,
                                           tagsActive: true,
                                           insideCollection: true,
                                           showingCollectionsPage: true)
        XCTAssertEqual(action, .closeHero)
    }

    func testNonHeroViewerInsideCollectionClosesViewer() {
        let action = EscapeResolver.action(hasSelectedFile: true,
                                           selectedFileIsHero: false,
                                           searchActive: false,
                                           tagsActive: false,
                                           insideCollection: true,
                                           showingCollectionsPage: true)
        XCTAssertEqual(action, .closeViewer)
    }

    // MARK: - Search is the next layer peeled (above tags/collection/page)

    func testSearchActiveClearsSearch() {
        let action = EscapeResolver.action(hasSelectedFile: false,
                                           selectedFileIsHero: false,
                                           searchActive: true,
                                           tagsActive: false,
                                           insideCollection: false,
                                           showingCollectionsPage: false)
        XCTAssertEqual(action, .clearSearch)
    }

    func testSearchInsideCollectionClearsSearchBeforeExiting() {
        // You searched WHILE inside a collection — Escape peels the most recent
        // layer (the search) first, leaving you back on the collection's members,
        // not silently dropping the collection under still-showing results.
        let action = EscapeResolver.action(hasSelectedFile: false,
                                           selectedFileIsHero: false,
                                           searchActive: true,
                                           tagsActive: false,
                                           insideCollection: true,
                                           showingCollectionsPage: true)
        XCTAssertEqual(action, .clearSearch)
    }

    // MARK: - Tag set is peeled after search, before collection

    func testTagsActiveClearsTags() {
        let action = EscapeResolver.action(hasSelectedFile: false,
                                           selectedFileIsHero: false,
                                           searchActive: false,
                                           tagsActive: true,
                                           insideCollection: false,
                                           showingCollectionsPage: false)
        XCTAssertEqual(action, .clearTags)
    }

    func testSearchBeatsTags() {
        // Search is peeled first (per the existing priority chain); tags next.
        let action = EscapeResolver.action(hasSelectedFile: false,
                                           selectedFileIsHero: false,
                                           searchActive: true,
                                           tagsActive: true,
                                           insideCollection: false,
                                           showingCollectionsPage: false)
        XCTAssertEqual(action, .clearSearch)
    }

    func testTagsBeatCollectionExit() {
        // Inside a collection with a tag set: Escape clears the tags first,
        // leaving the collection's full members; the next press exits it.
        let action = EscapeResolver.action(hasSelectedFile: false,
                                           selectedFileIsHero: false,
                                           searchActive: false,
                                           tagsActive: true,
                                           insideCollection: true,
                                           showingCollectionsPage: true)
        XCTAssertEqual(action, .clearTags)
    }

    func testViewerBeatsTags() {
        let action = EscapeResolver.action(hasSelectedFile: true,
                                           selectedFileIsHero: true,
                                           searchActive: false,
                                           tagsActive: true,
                                           insideCollection: false,
                                           showingCollectionsPage: false)
        XCTAssertEqual(action, .closeHero)
    }

    // MARK: - Back-out chain (no viewer, no active search, no tags)

    func testInsideCollectionExitsToCollectionsPage() {
        let action = EscapeResolver.action(hasSelectedFile: false,
                                           selectedFileIsHero: false,
                                           searchActive: false,
                                           tagsActive: false,
                                           insideCollection: true,
                                           showingCollectionsPage: true)
        XCTAssertEqual(action, .exitCollection)
    }

    func testCollectionsPageExitsToGrid() {
        let action = EscapeResolver.action(hasSelectedFile: false,
                                           selectedFileIsHero: false,
                                           searchActive: false,
                                           tagsActive: false,
                                           insideCollection: false,
                                           showingCollectionsPage: true)
        XCTAssertEqual(action, .exitCollectionsPage)
    }

    func testPlainGridDoesNothing() {
        let action = EscapeResolver.action(hasSelectedFile: false,
                                           selectedFileIsHero: false,
                                           searchActive: false,
                                           tagsActive: false,
                                           insideCollection: false,
                                           showingCollectionsPage: false)
        XCTAssertEqual(action, .none)
    }

    // MARK: - searchPresent glue (active results OR an in-flight typed query)

    func testSearchPresentWhenActive() {
        XCTAssertTrue(EscapeResolver.searchPresent(isSearchActive: true, queryIsEmpty: true))
    }

    func testSearchPresentWhenQueryTypedButNotYetFired() {
        // Debounce in flight: results haven't landed (isSearchActive false) but
        // the field holds text — Escape should still peel it.
        XCTAssertTrue(EscapeResolver.searchPresent(isSearchActive: false, queryIsEmpty: false))
    }

    func testSearchNotPresentWhenIdleAndEmpty() {
        XCTAssertFalse(EscapeResolver.searchPresent(isSearchActive: false, queryIsEmpty: true))
    }
}
