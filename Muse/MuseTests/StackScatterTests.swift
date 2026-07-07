import XCTest
import CoreGraphics
@testable import Muse

final class StackScatterTests: XCTestCase {

    private let cell = CGSize(width: 220, height: 200)

    // MARK: - Determinism

    func testSameSeedSamePoses() {
        let a = StackScatter.cards(seed: "collection-abc", count: 6, cell: cell)
        let b = StackScatter.cards(seed: "collection-abc", count: 6, cell: cell)
        XCTAssertEqual(a, b)
    }

    func testDifferentSeedsDifferentPoses() {
        let a = StackScatter.cards(seed: "collection-abc", count: 6, cell: cell)
        let b = StackScatter.cards(seed: "collection-xyz", count: 6, cell: cell)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Counts

    func testCountMatches() {
        for n in 1...6 {
            XCTAssertEqual(StackScatter.cards(seed: "s", count: n, cell: cell).count, n)
        }
    }

    func testZeroAndNegativeCountsAreEmpty() {
        XCTAssertTrue(StackScatter.cards(seed: "s", count: 0, cell: cell).isEmpty)
        XCTAssertTrue(StackScatter.cards(seed: "s", count: -3, cell: cell).isEmpty)
    }

    // MARK: - Rest pose bounds (index 0 = top card)

    func testTopCardRestStaysNearCenter() {
        let cards = StackScatter.cards(seed: "s", count: 6, cell: cell)
        let top = cards[0].rest
        XCTAssertLessThanOrEqual(abs(top.rotationDegrees), 4.0)
        XCTAssertLessThanOrEqual(abs(top.offset.width), cell.width * 0.03)
        XCTAssertLessThanOrEqual(abs(top.offset.height), cell.height * 0.03)
    }

    func testUnderCardRestBounds() {
        // Deterministic but seed-dependent: probe several seeds.
        for seed in ["a", "b", "c", "long-collection-id-1234"] {
            let cards = StackScatter.cards(seed: seed, count: 6, cell: cell)
            let side = min(cell.width, cell.height)
            for c in cards.dropFirst() {
                let r = abs(c.rest.rotationDegrees)
                XCTAssertGreaterThanOrEqual(r, 1.0, "seed \(seed)")
                XCTAssertLessThanOrEqual(r, 8.0, "seed \(seed)")
                let mag = hypot(c.rest.offset.width, c.rest.offset.height)
                XCTAssertGreaterThanOrEqual(mag, side * 0.02, "seed \(seed)")
                XCTAssertLessThanOrEqual(mag, side * 0.12, "seed \(seed)")
            }
        }
    }

    // MARK: - Fan pose bounds

    func testFanMovesUnderCardsOutward() {
        for seed in ["a", "b", "c"] {
            let cards = StackScatter.cards(seed: seed, count: 6, cell: cell)
            let side = min(cell.width, cell.height)
            for c in cards.dropFirst() {
                let rest = hypot(c.rest.offset.width, c.rest.offset.height)
                let fan = hypot(c.fan.offset.width, c.fan.offset.height)
                XCTAssertGreaterThan(fan, rest, "seed \(seed)")
                XCTAssertGreaterThanOrEqual(fan, side * 0.15, "seed \(seed)")
                XCTAssertLessThanOrEqual(fan, side * 0.4, "seed \(seed)")
                XCTAssertLessThanOrEqual(abs(c.fan.rotationDegrees), 20.0, "seed \(seed)")
            }
        }
    }

    func testFanKeepsUnderCardDirection() {
        // A card fans out roughly along its rest direction (within a quarter
        // turn) so the spread reads as the pile loosening, not reshuffling.
        let cards = StackScatter.cards(seed: "dir", count: 6, cell: cell)
        for c in cards.dropFirst() {
            let restAngle = atan2(c.rest.offset.height, c.rest.offset.width)
            let fanAngle = atan2(c.fan.offset.height, c.fan.offset.width)
            var diff = abs(restAngle - fanAngle)
            if diff > .pi { diff = 2 * .pi - diff }
            XCTAssertLessThanOrEqual(diff, .pi / 4)
        }
    }

    func testRestScaleIsOneFanShrinks() {
        let cards = StackScatter.cards(seed: "s", count: 6, cell: cell)
        for c in cards {
            XCTAssertEqual(c.rest.scale, 1.0)
        }
        // Top card shrinks least; under-cards shrink a touch more, but never
        // so far the fan reads as the pile receding.
        XCTAssertGreaterThanOrEqual(cards[0].fan.scale, 0.9)
        for c in cards.dropFirst() {
            XCTAssertGreaterThanOrEqual(c.fan.scale, 0.75)
            XCTAssertLessThan(c.fan.scale, 1.0)
            XCTAssertLessThanOrEqual(c.fan.scale, cards[0].fan.scale)
        }
    }

    func testTopCardFanStaysNearCenter() {
        let cards = StackScatter.cards(seed: "s", count: 6, cell: cell)
        let top = cards[0].fan
        let mag = hypot(top.offset.width, top.offset.height)
        XCTAssertLessThanOrEqual(mag, min(cell.width, cell.height) * 0.12)
    }

    func testUnderCardsSpreadAcrossDirections() {
        // The five under-cards shouldn't all fan into the same quadrant: the
        // widest angular gap between neighboring fan directions stays under
        // 180°, i.e. the directions surround the pile.
        let cards = StackScatter.cards(seed: "spread", count: 6, cell: cell)
        let angles = cards.dropFirst()
            .map { atan2($0.fan.offset.height, $0.fan.offset.width) }
            .sorted()
        var maxGap: Double = 0
        for i in 0..<angles.count {
            let next = i + 1 < angles.count ? angles[i + 1] : angles[0] + 2 * .pi
            maxGap = max(maxGap, next - angles[i])
        }
        XCTAssertLessThan(maxGap, .pi)
    }

    // MARK: - Stack fill (cover-first, dedupe, repeat to depth)

    func testFillCoverFirstAndDeduped() {
        let out = StackScatter.stackPaths(cover: "/c.jpg",
                                          members: ["/a.jpg", "/c.jpg", "/b.jpg"],
                                          depth: 6)
        XCTAssertEqual(out.first, "/c.jpg")
        // 3 unique members, repeated cyclically to depth 6.
        XCTAssertEqual(out, ["/c.jpg", "/a.jpg", "/b.jpg", "/c.jpg", "/a.jpg", "/b.jpg"])
    }

    func testFillNoCoverUsesMemberOrder() {
        let out = StackScatter.stackPaths(cover: nil,
                                          members: ["/a.jpg", "/b.jpg"],
                                          depth: 6)
        XCTAssertEqual(out, ["/a.jpg", "/b.jpg", "/a.jpg", "/b.jpg", "/a.jpg", "/b.jpg"])
    }

    func testFillSingleMemberRepeats() {
        let out = StackScatter.stackPaths(cover: nil, members: ["/a.jpg"], depth: 6)
        XCTAssertEqual(out, Array(repeating: "/a.jpg", count: 6))
    }

    func testFillCapsAtDepth() {
        let members = (1...9).map { "/\($0).jpg" }
        let out = StackScatter.stackPaths(cover: nil, members: members, depth: 6)
        XCTAssertEqual(out, Array(members.prefix(6)))
    }

    func testFillEmptyIsEmpty() {
        XCTAssertTrue(StackScatter.stackPaths(cover: nil, members: [], depth: 6).isEmpty)
        // A stale cover with no members shouldn't invent a pile either.
        XCTAssertTrue(StackScatter.stackPaths(cover: "/c.jpg", members: [], depth: 6).isEmpty)
    }

    func testFillCoverNotInMembersStillTops() {
        // Cover path not present in the member page (e.g. >limit members):
        // it still goes on top, members follow.
        let out = StackScatter.stackPaths(cover: "/z.jpg",
                                          members: ["/a.jpg", "/b.jpg"],
                                          depth: 4)
        XCTAssertEqual(out, ["/z.jpg", "/a.jpg", "/b.jpg", "/z.jpg"])
    }

    // MARK: - Card fit (natural aspect within a square box)

    func testFitLandscape() {
        let s = StackScatter.fit(imageSize: CGSize(width: 400, height: 200), box: 100)
        XCTAssertEqual(s.width, 100, accuracy: 0.01)
        XCTAssertEqual(s.height, 50, accuracy: 0.01)
    }

    func testFitPortrait() {
        let s = StackScatter.fit(imageSize: CGSize(width: 200, height: 400), box: 100)
        XCTAssertEqual(s.width, 50, accuracy: 0.01)
        XCTAssertEqual(s.height, 100, accuracy: 0.01)
    }

    func testFitDegenerateFallsBackToSquare() {
        let s = StackScatter.fit(imageSize: .zero, box: 100)
        XCTAssertEqual(s.width, 100, accuracy: 0.01)
        XCTAssertEqual(s.height, 100, accuracy: 0.01)
    }
}
