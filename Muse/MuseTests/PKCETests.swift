//
//  PKCETests.swift
//  MuseTests
//

import XCTest
import CryptoKit
@testable import Muse

final class PKCETests: XCTestCase {
    func testVerifierIsBase64URLAndLongEnough() {
        let v = PKCE.verifier()
        XCTAssertGreaterThanOrEqual(v.count, 43)
        XCTAssertLessThanOrEqual(v.count, 128)
        XCTAssertNil(v.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testChallengeIsS256OfVerifier() {
        let v = "test-verifier-fixed-string-1234567890abcd"
        let expected = Data(SHA256.hash(data: Data(v.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(PKCE.challenge(for: v), expected)
    }

    func testStateIsNonEmptyAndUnique() {
        XCTAssertNotEqual(PKCE.randomState(), PKCE.randomState())
        XCTAssertFalse(PKCE.randomState().isEmpty)
    }
}
