import XCTest
@testable import Muse

final class IntelligenceRegistryTests: XCTestCase {
    func testV1ProvidersRegistered() {
        let r = IntelligenceRegistry.shared
        XCTAssertFalse(r.tagger.modelVersion.isEmpty)
        XCTAssertFalse(r.clusterer.modelVersion.isEmpty)
        XCTAssertFalse(r.namer.modelVersion.isEmpty)
        if let e = r.embedder { XCTAssertGreaterThan(e.dimension, 0) }
    }
}
