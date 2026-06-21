import XCTest
@testable import Muse

final class GridFilterTests: XCTestCase {

    // Fixed "now": Wed 2026-06-17 12:00:00 local. Mid-week, mid-month, mid-year.
    private func fixedNow() -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 17; c.hour = 12; c.minute = 0; c.second = 0
        return Calendar.current.date(from: c)!
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h
        return Calendar.current.date(from: c)!
    }

    // MARK: - KindFacet mapping

    func testKindFacetBucketing() {
        XCTAssertEqual(KindFacet(from: .image), .image)
        XCTAssertEqual(KindFacet(from: .raw), .image)
        XCTAssertEqual(KindFacet(from: .psd), .image)
        XCTAssertEqual(KindFacet(from: .svg), .image)
        XCTAssertEqual(KindFacet(from: .video), .video)
        XCTAssertEqual(KindFacet(from: .pdf), .pdf)
        XCTAssertEqual(KindFacet(from: .text), .document)
        XCTAssertEqual(KindFacet(from: .markdown), .document)
        XCTAssertEqual(KindFacet(from: .code), .document)
        XCTAssertEqual(KindFacet(from: .office), .document)
        XCTAssertEqual(KindFacet(from: .audio), .audio)
        XCTAssertEqual(KindFacet(from: .folder), .folder)
        XCTAssertEqual(KindFacet(from: .model3d), .other)
        XCTAssertEqual(KindFacet(from: .font), .other)
        XCTAssertEqual(KindFacet(from: .archive), .other)
        XCTAssertEqual(KindFacet(from: .unknown), .other)
    }

    func testFolderMatchedOnlyByKindFacet() {
        let now = fixedNow()
        // No kind constraint: a folder shows even with date+size set, and even
        // with a nil size/modified (date/size never apply to a folder).
        XCTAssertTrue(GridFilter(kinds: [], date: .today, size: .over100MB)
            .matches(kind: .folder, sizeBytes: nil, modified: nil, now: now))
        // Folders explicitly included: shown regardless of date/size.
        XCTAssertTrue(GridFilter(kinds: [.folder], date: .year, size: .under1MB)
            .matches(kind: .folder, sizeBytes: nil, modified: nil, now: now))
        // Folders excluded (a kind set without .folder): hidden.
        XCTAssertFalse(GridFilter(kinds: [.image], date: .any, size: .any)
            .matches(kind: .folder, sizeBytes: 5, modified: now, now: now))
        // Unchecking just Folders (every other facet present) hides folders but
        // keeps files of the checked kinds.
        let allButFolder = GridFilter(kinds: [.image, .video, .pdf, .document, .audio, .other],
                                      date: .any, size: .any)
        XCTAssertFalse(allButFolder.matches(kind: .folder, sizeBytes: nil, modified: nil, now: now))
        XCTAssertTrue(allButFolder.matches(kind: .image, sizeBytes: 5, modified: now, now: now))
    }

    // MARK: - isActive

    func testNoneIsInactive() {
        XCTAssertFalse(GridFilter.none.isActive)
        XCTAssertEqual(GridFilter.none.kinds, [])
        XCTAssertEqual(GridFilter.none.date, .any)
        XCTAssertEqual(GridFilter.none.size, .any)
    }

    func testIsActiveWhenAnyFacetSet() {
        XCTAssertTrue(GridFilter(kinds: [.image], date: .any, size: .any).isActive)
        XCTAssertTrue(GridFilter(kinds: [], date: .today, size: .any).isActive)
        XCTAssertTrue(GridFilter(kinds: [], date: .any, size: .over100MB).isActive)
    }

    // MARK: - Kind matching

    func testEmptyKindsMatchesEverything() {
        let f = GridFilter.none
        let now = fixedNow()
        XCTAssertTrue(f.matches(kind: .image, sizeBytes: 5, modified: now, now: now))
        XCTAssertTrue(f.matches(kind: .folder, sizeBytes: 5, modified: now, now: now))
    }

    func testKindConstraintNarrows() {
        let f = GridFilter(kinds: [.pdf], date: .any, size: .any)
        let now = fixedNow()
        XCTAssertTrue(f.matches(kind: .pdf, sizeBytes: 5, modified: now, now: now))
        XCTAssertFalse(f.matches(kind: .image, sizeBytes: 5, modified: now, now: now))
        XCTAssertTrue(GridFilter(kinds: [.image, .video], date: .any, size: .any)
            .matches(kind: .video, sizeBytes: 5, modified: now, now: now))
    }

    // MARK: - Date windows (modified date, against fixedNow)

    func testDateAnyMatchesAnyDateAndNilModified() {
        let f = GridFilter(kinds: [], date: .any, size: .any)
        let now = fixedNow()
        XCTAssertTrue(f.matches(kind: .image, sizeBytes: 5, modified: date(1999, 1, 1), now: now))
        XCTAssertTrue(f.matches(kind: .image, sizeBytes: 5, modified: nil, now: now))
    }

    func testDateToday() {
        let f = GridFilter(kinds: [], date: .today, size: .any)
        let now = fixedNow()
        XCTAssertTrue(f.matches(kind: .image, sizeBytes: 5, modified: date(2026, 6, 17, 0), now: now))
        XCTAssertTrue(f.matches(kind: .image, sizeBytes: 5, modified: date(2026, 6, 17, 23), now: now))
        XCTAssertFalse(f.matches(kind: .image, sizeBytes: 5, modified: date(2026, 6, 16, 23), now: now))
    }

    func testDateThisWeek() {
        let f = GridFilter(kinds: [], date: .week, size: .any)
        let now = fixedNow()
        // Something earlier this same week matches; last week does not.
        XCTAssertTrue(f.matches(kind: .image, sizeBytes: 5, modified: now, now: now))
        XCTAssertFalse(f.matches(kind: .image, sizeBytes: 5, modified: date(2026, 6, 1), now: now))
    }

    func testDateThisMonth() {
        let f = GridFilter(kinds: [], date: .month, size: .any)
        let now = fixedNow()
        XCTAssertTrue(f.matches(kind: .image, sizeBytes: 5, modified: date(2026, 6, 1, 0), now: now))
        XCTAssertFalse(f.matches(kind: .image, sizeBytes: 5, modified: date(2026, 5, 31, 23), now: now))
    }

    func testDateThisYear() {
        let f = GridFilter(kinds: [], date: .year, size: .any)
        let now = fixedNow()
        XCTAssertTrue(f.matches(kind: .image, sizeBytes: 5, modified: date(2026, 1, 1, 0), now: now))
        XCTAssertFalse(f.matches(kind: .image, sizeBytes: 5, modified: date(2025, 12, 31, 23), now: now))
    }

    func testDateConstraintRejectsNilModified() {
        let now = fixedNow()
        for facet in [DateFacet.today, .week, .month, .year] {
            let f = GridFilter(kinds: [], date: facet, size: .any)
            XCTAssertFalse(f.matches(kind: .image, sizeBytes: 5, modified: nil, now: now),
                           "\(facet) must reject a nil modified date")
        }
    }

    // MARK: - Size buckets (decimal MB = 1_000_000 bytes)

    func testSizeBuckets() {
        let now = fixedNow()
        func f(_ s: SizeFacet) -> GridFilter { GridFilter(kinds: [], date: .any, size: s) }

        // < 1 MB
        XCTAssertTrue(f(.under1MB).matches(kind: .image, sizeBytes: 999_999, modified: now, now: now))
        XCTAssertFalse(f(.under1MB).matches(kind: .image, sizeBytes: 1_000_000, modified: now, now: now))
        // 1–10 MB
        XCTAssertTrue(f(.mb1to10).matches(kind: .image, sizeBytes: 1_000_000, modified: now, now: now))
        XCTAssertTrue(f(.mb1to10).matches(kind: .image, sizeBytes: 9_999_999, modified: now, now: now))
        XCTAssertFalse(f(.mb1to10).matches(kind: .image, sizeBytes: 10_000_000, modified: now, now: now))
        // 10–100 MB
        XCTAssertTrue(f(.mb10to100).matches(kind: .image, sizeBytes: 10_000_000, modified: now, now: now))
        XCTAssertFalse(f(.mb10to100).matches(kind: .image, sizeBytes: 100_000_000, modified: now, now: now))
        // > 100 MB
        XCTAssertTrue(f(.over100MB).matches(kind: .image, sizeBytes: 100_000_000, modified: now, now: now))
        XCTAssertFalse(f(.over100MB).matches(kind: .image, sizeBytes: 99_999_999, modified: now, now: now))
    }

    func testSizeConstraintRejectsNilSize() {
        let now = fixedNow()
        for facet in [SizeFacet.under1MB, .mb1to10, .mb10to100, .over100MB] {
            let f = GridFilter(kinds: [], date: .any, size: facet)
            XCTAssertFalse(f.matches(kind: .image, sizeBytes: nil, modified: now, now: now),
                           "\(facet) must reject a nil size")
        }
        // .any tolerates nil size.
        XCTAssertTrue(GridFilter(kinds: [], date: .any, size: .any)
            .matches(kind: .image, sizeBytes: nil, modified: now, now: now))
    }

    // MARK: - Combined facets

    func testAllThreeFacetsTogether() {
        let f = GridFilter(kinds: [.image], date: .month, size: .mb1to10)
        let now = fixedNow()
        // matches all three
        XCTAssertTrue(f.matches(kind: .image, sizeBytes: 5_000_000, modified: date(2026, 6, 10), now: now))
        // wrong kind
        XCTAssertFalse(f.matches(kind: .pdf, sizeBytes: 5_000_000, modified: date(2026, 6, 10), now: now))
        // wrong size
        XCTAssertFalse(f.matches(kind: .image, sizeBytes: 50_000_000, modified: date(2026, 6, 10), now: now))
        // wrong date
        XCTAssertFalse(f.matches(kind: .image, sizeBytes: 5_000_000, modified: date(2026, 4, 1), now: now))
    }

    // MARK: - resolve / Codable round-trip

    func testResolveDefaultsToNone() {
        XCTAssertEqual(GridFilter.resolve(nil), .none)
        XCTAssertEqual(GridFilter.resolve("not json"), .none)
    }

    func testCodableRoundTripViaResolve() throws {
        let original = GridFilter(kinds: [.image, .pdf], date: .week, size: .mb10to100)
        let data = try JSONEncoder().encode(original)
        let json = String(data: data, encoding: .utf8)
        XCTAssertEqual(GridFilter.resolve(json), original)
    }
}
