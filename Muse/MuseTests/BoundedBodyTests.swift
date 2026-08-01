//
//  BoundedBodyTests.swift
//  MuseTests
//
//  The point of BoundedBody is that the ceiling applies WHILE reading, not
//  after — so the interesting cases are the ones a post-hoc `data.count` check
//  would also pass: a body that lies about its length, and one that declares no
//  length at all. A stub URLProtocol serves the bytes so no network is touched.
//

import XCTest
@testable import Muse

/// Serves a canned body for whatever is requested. `declaredLength` controls
/// the Content-Length header independently of the real byte count, so a lying
/// server can be modelled.
final class StubBodyProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    /// nil → send no Content-Length at all (chunked-style response).
    nonisolated(unsafe) static var declaredLength: Int?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var headers: [String: String] = [:]
        if let declared = Self.declaredLength {
            headers["Content-Length"] = String(declared)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class BoundedBodyTests: XCTestCase {

    private let url = URL(string: "https://example.invalid/feed.json")!

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubBodyProtocol.self]
        return URLSession(configuration: config)
    }

    private func fetch(limit: Int) async throws -> Data {
        let (data, _) = try await BoundedBody.data(
            for: URLRequest(url: url), session: makeSession(), limit: limit)
        return data
    }

    override func tearDown() {
        StubBodyProtocol.body = Data()
        StubBodyProtocol.declaredLength = nil
        super.tearDown()
    }

    // MARK: - Under the ceiling

    func testReturnsBodyUnderLimit() async throws {
        StubBodyProtocol.body = Data(repeating: 0x61, count: 100)
        StubBodyProtocol.declaredLength = 100
        let data = try await fetch(limit: 1024)
        XCTAssertEqual(data.count, 100)
    }

    /// The callers' contract is `count <= max`, so exactly-at-the-limit passes.
    func testBodyExactlyAtLimitIsAccepted() async throws {
        StubBodyProtocol.body = Data(repeating: 0x61, count: 256)
        StubBodyProtocol.declaredLength = 256
        let data = try await fetch(limit: 256)
        XCTAssertEqual(data.count, 256)
    }

    // MARK: - Over the ceiling

    func testRejectsWhenContentLengthDeclaresOversize() async {
        StubBodyProtocol.body = Data(repeating: 0x61, count: 5000)
        StubBodyProtocol.declaredLength = 5000
        do {
            _ = try await fetch(limit: 1024)
            XCTFail("expected a tooLarge throw")
        } catch {
            XCTAssertEqual(error as? BoundedBody.FetchError, .tooLarge)
        }
    }

    /// The case a declared-length check alone would miss: the server understates
    /// Content-Length (or the header is wrong) and then sends far more. Only the
    /// streaming tally catches this.
    func testRejectsWhenServerUnderstatesContentLength() async {
        StubBodyProtocol.body = Data(repeating: 0x61, count: 5000)
        StubBodyProtocol.declaredLength = 10
        do {
            _ = try await fetch(limit: 1024)
            XCTFail("expected a tooLarge throw")
        } catch {
            XCTAssertEqual(error as? BoundedBody.FetchError, .tooLarge)
        }
    }

    /// No Content-Length at all — the streaming tally is the only bound.
    func testRejectsOversizeWithNoDeclaredLength() async {
        StubBodyProtocol.body = Data(repeating: 0x61, count: 5000)
        StubBodyProtocol.declaredLength = nil
        do {
            _ = try await fetch(limit: 1024)
            XCTFail("expected a tooLarge throw")
        } catch {
            XCTAssertEqual(error as? BoundedBody.FetchError, .tooLarge)
        }
    }
}
