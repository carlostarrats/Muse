import XCTest
import CoreGraphics
@testable import Muse

final class CollectionPDFLayoutTests: XCTestCase {
    // 11x14in @ 72dpi, 0.5in margins, 3 columns, 12pt gutter, 46pt page-1 header.
    private let geo = CollectionPDFLayout.Geometry(
        pageSize: CGSize(width: 792, height: 1008),
        margin: 36, columns: 3, gutter: 12, firstPageHeaderHeight: 46)

    func testEmptyInputProducesNoPages() {
        XCTAssertTrue(CollectionPDFLayout.paginate(aspects: [], geometry: geo).isEmpty)
    }

    func testEveryImagePlacedExactlyOnce() {
        let pages = CollectionPDFLayout.paginate(
            aspects: Array(repeating: 1.0, count: 25), geometry: geo)
        let indices = pages.flatMap { $0.placements.map(\.index) }.sorted()
        XCTAssertEqual(indices, Array(0..<25))
    }

    func testManyImagesPaginateIntoMultiplePages() {
        let pages = CollectionPDFLayout.paginate(
            aspects: Array(repeating: 1.0, count: 25), geometry: geo)
        XCTAssertGreaterThan(pages.count, 1)
    }

    func testNoTileCrossesPageBounds() {
        let pages = CollectionPDFLayout.paginate(
            aspects: Array(repeating: 1.5, count: 40), geometry: geo)
        let contentBottom = geo.pageSize.height - geo.margin
        for (p, page) in pages.enumerated() {
            let top = geo.margin + (p == 0 ? geo.firstPageHeaderHeight : 0)
            for pl in page.placements {
                XCTAssertGreaterThanOrEqual(pl.rect.minY, top - 0.5)
                XCTAssertLessThanOrEqual(pl.rect.maxY, contentBottom + 0.5)
                XCTAssertGreaterThanOrEqual(pl.rect.minX, geo.margin - 0.5)
                XCTAssertLessThanOrEqual(pl.rect.maxX, geo.pageSize.width - geo.margin + 0.5)
            }
        }
    }

    func testOversizedTallImageCappedToOnePage() {
        let pages = CollectionPDFLayout.paginate(aspects: [10.0], geometry: geo)
        XCTAssertEqual(pages.count, 1)
        let pl = pages[0].placements[0]
        let avail = (geo.pageSize.height - geo.margin)
                  - (geo.margin + geo.firstPageHeaderHeight)
        XCTAssertLessThanOrEqual(pl.rect.height, avail + 0.5)
    }

    func testColumnWidthMatchesGeometry() {
        let pages = CollectionPDFLayout.paginate(aspects: [1.0], geometry: geo)
        // (792 - 72 - 12*2) / 3 = 232
        XCTAssertEqual(pages[0].placements[0].rect.width, 232, accuracy: 0.5)
    }

    // 11x14in @ 72dpi, 3 columns, 16pt caption strip below each image.
    private let captionGeo = CollectionPDFLayout.Geometry(
        pageSize: CGSize(width: 792, height: 1008),
        margin: 36, columns: 3, gutter: 12, firstPageHeaderHeight: 46,
        captionHeight: 16)

    func testCaptionHeightReservedPerTile() {
        let pages = CollectionPDFLayout.paginate(aspects: [1.0], geometry: captionGeo)
        let pl = pages[0].placements[0]
        // Image = columnWidth(232) × aspect(1); tile = image + 16pt caption.
        XCTAssertEqual(pl.rect.width, 232, accuracy: 0.5)
        XCTAssertEqual(pl.rect.height, 232 + 16, accuracy: 0.5)
    }

    func testCaptionedTilesStayWithinPageAndPlaceEveryImage() {
        let pages = CollectionPDFLayout.paginate(
            aspects: Array(repeating: 1.2, count: 30), geometry: captionGeo)
        let contentBottom = captionGeo.pageSize.height - captionGeo.margin
        for (p, page) in pages.enumerated() {
            let top = captionGeo.margin + (p == 0 ? captionGeo.firstPageHeaderHeight : 0)
            for pl in page.placements {
                XCTAssertGreaterThanOrEqual(pl.rect.minY, top - 0.5)
                XCTAssertLessThanOrEqual(pl.rect.maxY, contentBottom + 0.5)
            }
        }
        let indices = pages.flatMap { $0.placements.map(\.index) }.sorted()
        XCTAssertEqual(indices, Array(0..<30))
    }

    // MARK: - Rows pagination

    /// Rows mode on paper: one height per row, natural widths, rows justified
    /// to the content width, and no row ever split across a page break.
    func testRowsPaginationJustifiesFullRowsToContentWidth() {
        let g = CollectionPDFLayout.Geometry(
            pageSize: CGSize(width: 792, height: 1008), margin: 36, columns: 4,
            gutter: 12, firstPageHeaderHeight: 120, captionHeight: 0)
        let aspects = [CGFloat](repeating: 1, count: 16)
        let pages = CollectionPDFLayout.paginateRows(aspects: aspects, geometry: g)
        XCTAssertFalse(pages.isEmpty)

        let contentWidth: CGFloat = 792 - 36 * 2
        // Group placements by y across the document; every row but the last
        // must span the content width.
        let all = pages.flatMap(\.placements)
        let rows = Dictionary(grouping: all) { ($0.rect.minY * 10).rounded() }
        let lastRowKey = rows.keys.max()
        for (key, placements) in rows where key != lastRowKey {
            let widths = placements.reduce(CGFloat(0)) { $0 + $1.rect.width }
            let gaps = CGFloat(placements.count - 1) * 12
            XCTAssertEqual(widths + gaps, contentWidth, accuracy: 1.0)
        }
    }

    func testRowsPaginationKeepsRowsWhole() {
        let g = CollectionPDFLayout.Geometry(
            pageSize: CGSize(width: 792, height: 1008), margin: 36, columns: 3,
            gutter: 12, firstPageHeaderHeight: 120, captionHeight: 16)
        let aspects = (0..<40).map { CGFloat(0.6 + Double($0 % 5) * 0.2) }
        let pages = CollectionPDFLayout.paginateRows(aspects: aspects, geometry: g)
        XCTAssertGreaterThan(pages.count, 1, "40 images should need several pages")
        // No index appears twice, and every index appears once.
        let indices = pages.flatMap { $0.placements.map(\.index) }.sorted()
        XCTAssertEqual(indices, Array(0..<40))
        // Every placement fits inside its page's content box.
        for page in pages {
            for p in page.placements {
                XCTAssertGreaterThanOrEqual(p.rect.minY, 36 - 0.5)
                XCTAssertLessThanOrEqual(p.rect.maxY, 1008 - 36 + 0.5)
                XCTAssertGreaterThanOrEqual(p.rect.minX, 36 - 0.5)
                XCTAssertLessThanOrEqual(p.rect.maxX, 792 - 36 + 0.5)
            }
        }
    }

    func testRowsPaginationEmptyInput() {
        let g = CollectionPDFLayout.Geometry(
            pageSize: CGSize(width: 792, height: 1008), margin: 36, columns: 4,
            gutter: 12, firstPageHeaderHeight: 120)
        XCTAssertTrue(CollectionPDFLayout.paginateRows(aspects: [], geometry: g).isEmpty)
    }

    func testRowsPaginationReservesTheFirstPageHeader() {
        let g = CollectionPDFLayout.Geometry(
            pageSize: CGSize(width: 792, height: 1008), margin: 36, columns: 4,
            gutter: 12, firstPageHeaderHeight: 120)
        let pages = CollectionPDFLayout.paginateRows(
            aspects: [CGFloat](repeating: 1, count: 30), geometry: g)
        let firstTop = pages[0].placements.map(\.rect.minY).min() ?? 0
        XCTAssertGreaterThanOrEqual(firstTop, 36 + 120 - 0.5)
        if pages.count > 1 {
            let secondTop = pages[1].placements.map(\.rect.minY).min() ?? 0
            XCTAssertEqual(secondTop, 36, accuracy: 0.5)
        }
    }
}
