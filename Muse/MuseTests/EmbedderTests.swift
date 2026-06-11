import XCTest
@testable import Muse

final class EmbedderTests: XCTestCase {
    func testCosine() {
        XCTAssertEqual(VectorMath.cosine([1, 0], [1, 0]), 1.0, accuracy: 1e-6)
        XCTAssertEqual(VectorMath.cosine([1, 0], [0, 1]), 0.0, accuracy: 1e-6)
        XCTAssertEqual(VectorMath.cosine([1, 0], [-1, 0]), -1.0, accuracy: 1e-6)
        XCTAssertEqual(VectorMath.cosine([], []), 0.0, accuracy: 1e-6)
    }
    func testDataRoundtrip() {
        let v: [Float] = [0.25, -1.5, 3.125]
        XCTAssertEqual(VectorMath.fromData(VectorMath.toData(v)), v)
    }
    func testEmbedderSemanticNeighborhood() throws {
        guard let e = SentenceEmbedder.makeIfAvailable() else {
            throw XCTSkip("NL sentence embedding asset unavailable on this machine")
        }
        let soccer = e.embed("soccer")!
        let football = e.embed("football stadium ball")!
        let teapot = e.embed("antique porcelain teapot")!
        let near = VectorMath.cosine(soccer, football)
        let far = VectorMath.cosine(soccer, teapot)
        print("EmbedderTests: dimension=\(e.dimension) cosine(soccer,football)=\(near) cosine(soccer,teapot)=\(far)")
        XCTAssertGreaterThan(near, far)
    }
}
