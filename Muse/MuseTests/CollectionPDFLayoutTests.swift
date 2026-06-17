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
}
