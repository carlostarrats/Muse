//
//  OutputRenderTests.swift
//  MuseTests
//
//  An unedited file passes through unrendered; an edited one renders.
//  RenderedOutput cannot be constructed outside OutputRender.swift — the ONLY
//  way this test file obtains one is by calling forOutput, which is the
//  compile-time proof the export choke point can't be bypassed. The
//  `preferring:` cases exist to prove the added overload didn't open a second
//  door.
//

import XCTest
import ImageIO
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

    /// A hash alone is NOT enough to render: `forOutput` also needs a
    /// decodable, renderable stack. A stub reporting a hash for a file the
    /// index knows nothing about must fall through to the original rather
    /// than produce an empty temp file.
    func testHashWithoutARenderableStackShipsTheOriginal() throws {
        EditStackIndex.installProvider(StubEditStackProvider(hash: "zzz", cropped: nil))
        let url = URL(fileURLWithPath: "/tmp/output-test.jpg")
        let out = try OutputRender.forOutput(url)
        XCTAssertEqual(out.url, url)
        XCTAssertNil(out.stackHash)
    }

    /// The real thing: an indexed, renderable stack produces a RENDERED temp,
    /// not the original bytes — this is what stops a share shipping unedited
    /// pixels.
    func testForOutputRendersATempWhenAnEditExists() throws {
        let url = try EditRenderTestSupport.writeFixture(width: 256, height: 128,
                                                         orientation: 1, named: "output-render")
        var stack = EditStack.fresh()
        stack.setTone { $0.exposureEV = 1.5 }
        let json = try EditStackCodec.encode(stack)
        let hash = EditStackCodec.hash(stack)
        EditStackIndex.rebuild(entries: [(path: url.standardizedFileURL.path,
                                          stackJSON: json, hash: hash)])
        EditStackIndex.installProvider(LiveEditStackProvider())

        let out = try OutputRender.forOutput(url)
        XCTAssertNotEqual(out.url, url, "an edited file must leave as rendered bytes")
        XCTAssertEqual(out.stackHash, hash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.url.path))
        XCTAssertTrue(out.url.path.contains(OutputRender.tempDirectoryName))
    }

    /// A stack from a NEWER renderer must ship the ORIGINAL, never a partial
    /// application of the half this build understands.
    func testUnrenderableStackShipsTheOriginal() throws {
        let url = try EditRenderTestSupport.writeFixture(width: 128, height: 128,
                                                         orientation: 1, named: "output-future")
        var stack = EditStack.fresh()
        stack.setTone { $0.exposureEV = 1.5 }
        stack.processVersion = EditStack.currentProcessVersion + 1
        let json = try EditStackCodec.encode(stack)
        EditStackIndex.rebuild(entries: [(path: url.standardizedFileURL.path,
                                          stackJSON: json,
                                          hash: EditStackCodec.hash(stack))])
        EditStackIndex.installProvider(LiveEditStackProvider())

        let out = try OutputRender.forOutput(url)
        XCTAssertEqual(out.url, url)
        XCTAssertNil(out.stackHash)
    }

    /// `discard` collects a rendered temp AND its per-render directory as soon
    /// as the consumer is done — a large edited publish used to leave one
    /// full-resolution render per image for the 24 h sweep.
    func testDiscardRemovesARenderedTempAndItsDirectory() throws {
        let url = try EditRenderTestSupport.writeFixture(width: 64, height: 64,
                                                         orientation: 1, named: "output-discard")
        var stack = EditStack.fresh()
        stack.setTone { $0.exposureEV = 1 }
        EditStackIndex.rebuild(entries: [(path: url.standardizedFileURL.path,
                                          stackJSON: try EditStackCodec.encode(stack),
                                          hash: EditStackCodec.hash(stack))])
        EditStackIndex.installProvider(LiveEditStackProvider())

        let out = try OutputRender.forOutput(url)
        let dir = out.url.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.url.path))
        OutputRender.discard(out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    /// THE safety property: for an unedited file `out.url` IS the user's own
    /// file. `discard` must never touch it — a regression here deletes
    /// originals on every share.
    func testDiscardNeverTouchesAnUneditedOriginal() throws {
        let url = try EditRenderTestSupport.writeFixture(width: 32, height: 32,
                                                         orientation: 1, named: "output-keep")
        let out = try OutputRender.forOutput(url)
        XCTAssertNil(out.stackHash)
        OutputRender.discard(out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "discard must be a no-op for an unrendered output")
    }

    func testSweepLeavesFreshTempsAlone() throws {
        let url = try EditRenderTestSupport.writeFixture(width: 64, height: 64,
                                                         orientation: 1, named: "output-sweep")
        var stack = EditStack.fresh()
        stack.setTone { $0.exposureEV = 1 }
        EditStackIndex.rebuild(entries: [(path: url.standardizedFileURL.path,
                                          stackJSON: try EditStackCodec.encode(stack),
                                          hash: EditStackCodec.hash(stack))])
        EditStackIndex.installProvider(LiveEditStackProvider())
        let out = try OutputRender.forOutput(url)
        OutputRender.sweepRenderTemps()
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.url.path),
                      "a temp minutes old is still in use — the sweep is age-based")
    }

    /// The `preferring:` overload must not become a second way to construct a
    /// RenderedOutput. An unedited file takes exactly the same pass-through it
    /// always did — the choke point has one behaviour, not two.
    func testPreferringLeavesAnUneditedFileUntouched() throws {
        let url = try EditRenderTestSupport.writeFixture(width: 32, height: 32,
                                                         orientation: 1, named: "output-plain")
        EditStackIndex.rebuild(entries: [])
        let out = try OutputRender.forOutput(url, preferring: .tiff16)
        XCTAssertEqual(out.url, url)
        XCTAssertNil(out.stackHash)
    }

    /// An EDITED file asked for 16-bit renders its temp at 16-bit, rather than
    /// producing an 8-bit temp the exporter would then inflate.
    func testPreferringRendersTheTempInTheRequestedContainer() throws {
        let url = try EditRenderTestSupport.writeFixture(width: 48, height: 48,
                                                         orientation: 1, named: "output-deep")
        var stack = EditStack.fresh()
        stack.setTone { $0.exposureEV = 1 }
        EditStackIndex.rebuild(entries: [(path: url.standardizedFileURL.path,
                                          stackJSON: try EditStackCodec.encode(stack),
                                          hash: EditStackCodec.hash(stack))])
        EditStackIndex.installProvider(LiveEditStackProvider())
        let out = try OutputRender.forOutput(url, preferring: .tiff16)
        defer { OutputRender.discard(out) }
        XCTAssertNotEqual(out.url, url, "an edited file must render to a temp")
        XCTAssertEqual(out.url.pathExtension, "tif")
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(out.url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any])
        XCTAssertEqual(props[kCGImagePropertyDepth as String] as? Int, 16)
    }
}
