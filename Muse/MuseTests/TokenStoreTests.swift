//
//  TokenStoreTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class TokenStoreTests: XCTestCase {
    func testRoundTripAndClear() {
        let store: TokenStoring = InMemoryTokenStore()
        XCTAssertNil(store.load())
        let t = DriveTokens(accessToken: "a", refreshToken: "r",
                            expiry: Date(timeIntervalSince1970: 1000))
        store.save(t)
        XCTAssertEqual(store.load(), t)
        store.clear()
        XCTAssertNil(store.load())
    }
}
