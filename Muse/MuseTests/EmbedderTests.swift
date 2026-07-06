import XCTest
@testable import Muse

final class EmbedderTests: XCTestCase {
    func testCosine() {
        XCTAssertEqual(VectorMath.cosine([1, 0], [1, 0]), 1.0, accuracy: 1e-6)
        XCTAssertEqual(VectorMath.cosine([1, 0], [0, 1]), 0.0, accuracy: 1e-6)
        XCTAssertEqual(VectorMath.cosine([1, 0], [-1, 0]), -1.0, accuracy: 1e-6)
        XCTAssertEqual(VectorMath.cosine([], []), 0.0, accuracy: 1e-6)
    }
    func testCosineVectorizedMatchesDoubleReference() {
        let a: [Float] = [0.2, 0.5, -0.3, 0.9]
        let b: [Float] = [0.7, -0.1, 0.4, 0.2]
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += Double(a[i]) * Double(b[i])
            na  += Double(a[i]) * Double(a[i])
            nb  += Double(b[i]) * Double(b[i])
        }
        let expected = dot / (na.squareRoot() * nb.squareRoot())
        XCTAssertEqual(VectorMath.cosine(a, b), expected, accuracy: 1e-6)
        // Non-equal-length and empty guards still hold.
        XCTAssertEqual(VectorMath.cosine([1, 2, 3], [1, 2]), 0.0, accuracy: 1e-6)
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
