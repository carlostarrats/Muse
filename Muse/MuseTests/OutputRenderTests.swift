//
//  OutputRenderTests.swift
//  MuseTests
//
//  forOutput is identity today (originals pass through unrendered).
//  RenderedOutput cannot be constructed outside OutputRender.swift — the ONLY
//  way this test file obtains one is by calling forOutput, which is the
//  compile-time proof the export choke point can't be bypassed.
//

import XCTest
@testable import Muse

final class OutputRenderTests: XCTestCase {

    override func tearDown() {
        EditStackIndex.installProvider(nil)
        super.tearDown()
    }

    func testForOutputIsIdentityToday() throws {
        let url = URL(fileURLWithPath: "/tmp/output-test.jpg")
        let out = try OutputRender.forOutput(url)
        XCTAssertEqual(out.url, url)
        XCTAssertNil(out.stackHash)
    }

    func testForOutputArrayPreservesOrder() throws {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.jpg"),
            URL(fileURLWithPath: "/tmp/b.jpg"),
            URL(fileURLWithPath: "/tmp/c.jpg"),
        ]
        let outs = try OutputRender.forOutput(urls)
        XCTAssertEqual(outs.map(\.url), urls)
    }

    func testForOutputEmptyArray() throws {
        XCTAssertTrue(try OutputRender.forOutput([URL]()).isEmpty)
    }

    func testForOutputCarriesStackHashWhenProviderInstalled() throws {
        EditStackIndex.installProvider(StubEditStackProvider(hash: "zzz", cropped: nil))
        let url = URL(fileURLWithPath: "/tmp/output-test.jpg")
        XCTAssertEqual(try OutputRender.forOutput(url).stackHash, "zzz")
    }

    /// Every export must carry the same stack identity — an array path that
    /// dropped it would ship edited and unedited pixels from one publish.
    func testArrayPathCarriesStackHashToo() throws {
        EditStackIndex.installProvider(StubEditStackProvider(hash: "zzz", cropped: nil))
        let outs = try OutputRender.forOutput([URL(fileURLWithPath: "/tmp/a.jpg")])
        XCTAssertEqual(outs.first?.stackHash, "zzz")
    }
}
