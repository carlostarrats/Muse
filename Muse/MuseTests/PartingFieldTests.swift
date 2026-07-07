import XCTest
@testable import Muse

final class PartingFieldTests: XCTestCase {
    // 160pt square tiles on a simple lattice around a clicked tile at origin.
    private func tile(x: CGFloat, y: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: 160, height: 160)
    }

    // The clicked tile itself never moves or shrinks — it's the flight source.
    func testClickedTileStaysPut() {
        let clicked = tile(x: 300, y: 500)
        XCTAssertEqual(PartingField.displacement(for: clicked, clicked: clicked),
                       .identity)
    }

    // A tile directly to the right eases further right, not vertically.
    func testRightNeighborPushesRight() {
        let clicked = tile(x: 0, y: 0)
        let d = PartingField.displacement(for: tile(x: 200, y: 0), clicked: clicked)
        XCTAssertGreaterThan(d.offset.width, 0)
        XCTAssertEqual(d.offset.height, 0, accuracy: 0.001)
    }

    // A tile directly above (smaller y) eases further up.
    func testTopNeighborPushesUp() {
        let clicked = tile(x: 0, y: 0)
        let d = PartingField.displacement(for: tile(x: 0, y: -200), clicked: clicked)
        XCTAssertLessThan(d.offset.height, 0)
        XCTAssertEqual(d.offset.width, 0, accuracy: 0.001)
    }

    // The push points exactly away from the clicked center: the offset is
    // parallel to the center-to-center delta (zero cross product), pointing
    // away (positive dot product).
    func testPushIsRadial() {
        let clicked = tile(x: 100, y: 900)
        let other = tile(x: 700, y: 250)
        let off = PartingField.displacement(for: other, clicked: clicked).offset
        let dx = other.midX - clicked.midX
        let dy = other.midY - clicked.midY
        XCTAssertEqual(dx * off.height - dy * off.width, 0, accuracy: 0.01)
        XCTAssertGreaterThan(dx * off.width + dy * off.height, 0)
    }

    // The push is local to the hero: a near neighbor clears out meaningfully,
    // a far tile barely moves.
    func testPushIsLocalToHero() {
        let clicked = tile(x: -80, y: -80)   // center at (0,0)
        func push(_ d: CGFloat) -> CGFloat {
            PartingField.displacement(for: tile(x: d - 80, y: -80),
                                      clicked: clicked).offset.width
        }
        XCTAssertGreaterThan(push(250), 40)
        XCTAssertLessThan(push(900), 8)
        XCTAssertGreaterThan(push(250), push(900) * 5)
    }

    // The size ripple: near tiles shrink hard (~0.91), mid tiles less, and
    // the far corners are almost untouched — the gradient the reference
    // shows, not a uniform scale.
    func testShrinkRipplesOutward() {
        let clicked = tile(x: -80, y: -80)   // center at (0,0)
        func scale(_ d: CGFloat) -> CGFloat {
            PartingField.displacement(for: tile(x: d - 80, y: -80),
                                      clicked: clicked).scale
        }
        XCTAssertEqual(scale(200), 0.91, accuracy: 0.02)
        XCTAssertLessThan(scale(200), scale(500))
        XCTAssertLessThan(scale(500), scale(1200))
        XCTAssertGreaterThan(scale(1700), 0.99)   // far corner ~unchanged
        // Every scale stays within the sane band.
        for d: CGFloat in [1, 200, 500, 1200, 2400] {
            XCTAssertLessThan(scale(d), 1.0001)
            XCTAssertGreaterThanOrEqual(scale(d), 1 - PartingField.maxShrink - 0.001)
        }
    }

    // The ripple propagates: delay grows with distance from zero, capped so
    // far corners still land inside the ~0.3s envelope.
    func testOpenDelayPropagatesOutwardAndCaps() {
        XCTAssertEqual(PartingField.openDelay(distance: 0), 0)
        let near = PartingField.openDelay(distance: 200)
        let far = PartingField.openDelay(distance: 1000)
        XCTAssertGreaterThan(far, near)
        XCTAssertEqual(PartingField.openDelay(distance: 1500), 0.1, accuracy: 0.0001)
        XCTAssertEqual(PartingField.openDelay(distance: 9000), 0.1, accuracy: 0.0001)
    }

    // Grid-mode damping: strength scales the push linearly and the shrink's
    // deviation from 1 linearly — same motion, reduced amplitude.
    func testStrengthDampsBothComponents() {
        let clicked = tile(x: 0, y: 0)
        let other = tile(x: 300, y: 200)
        let full = PartingField.displacement(for: other, clicked: clicked)
        let damped = PartingField.displacement(for: other, clicked: clicked,
                                               strength: PartingField.gridModeStrength)
        let k = PartingField.gridModeStrength
        XCTAssertEqual(damped.offset.width, full.offset.width * k, accuracy: 0.001)
        XCTAssertEqual(damped.offset.height, full.offset.height * k, accuracy: 0.001)
        XCTAssertEqual(1 - damped.scale, (1 - full.scale) * k, accuracy: 0.001)
        XCTAssertEqual(damped.distance, full.distance, accuracy: 0.001)
    }

    // Mirror-symmetric: opposite sides part oppositely with equal strength.
    func testSymmetricPush() {
        let clicked = tile(x: 0, y: 0)
        let right = PartingField.displacement(for: tile(x: 400, y: 0), clicked: clicked)
        let left = PartingField.displacement(for: tile(x: -400, y: 0), clicked: clicked)
        XCTAssertEqual(right.offset.width, -left.offset.width, accuracy: 0.001)
        XCTAssertEqual(right.offset.height, left.offset.height, accuracy: 0.001)
        XCTAssertEqual(right.scale, left.scale, accuracy: 0.001)
    }
}
