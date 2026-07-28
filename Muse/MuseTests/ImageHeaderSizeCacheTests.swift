import XCTest
import CoreGraphics
@testable import Muse

final class ImageHeaderSizeCacheTests: XCTestCase {

    private func tempURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ihsc-\(name)")
    }

    override func setUp() {
        super.setUp()
        // Every test uses its own synthetic paths, so no cross-test bleed.
    }

    func testRecordThenCachedRoundTrips() {
        let u = tempURL("a.tif")
        ImageHeaderSizeCache.record(u, width: 9600, height: 12000)
        XCTAssertEqual(ImageHeaderSizeCache.cached(u), CGSize(width: 9600, height: 12000))
    }

    /// The whole point of the cache: the lookup used on the main thread must
    /// never fall through to a header read.
    func testCachedReturnsNilForAnUnknownFileRatherThanReadingIt() {
        XCTAssertNil(ImageHeaderSizeCache.cached(tempURL("never-recorded.tif")))
    }

    /// A URL built two different ways must hit the same entry — the hero looks
    /// up by the viewer's URL, the thumbnail pass records the enumerated one.
    func testLookupIsPathNormalized() {
        let dir = NSTemporaryDirectory()
        let plain = URL(fileURLWithPath: dir).appendingPathComponent("norm.tif")
        let messy = URL(fileURLWithPath: dir + "/./" + "norm.tif")
        ImageHeaderSizeCache.record(plain, width: 100, height: 50)
        XCTAssertEqual(ImageHeaderSizeCache.cached(messy), CGSize(width: 100, height: 50))
    }

    /// An in-place edit can change an image's dimensions, so a stale entry must
    /// be droppable — ThumbnailCache.invalidate calls this.
    func testInvalidateForgetsTheEntry() {
        let u = tempURL("edited.tif")
        ImageHeaderSizeCache.record(u, width: 10, height: 10)
        ImageHeaderSizeCache.invalidate(u)
        XCTAssertNil(ImageHeaderSizeCache.cached(u))
    }

    /// A degenerate header must not be memoized as a real size — a zero
    /// dimension would make the flight's fit math divide into nothing.
    func testDegenerateSizesAreRejected() {
        let z = tempURL("zero.tif")
        ImageHeaderSizeCache.record(z, width: 0, height: 100)
        XCTAssertNil(ImageHeaderSizeCache.cached(z))
        let n = tempURL("neg.tif")
        ImageHeaderSizeCache.record(n, width: -4, height: -4)
        XCTAssertNil(ImageHeaderSizeCache.cached(n))
    }

    /// `resolve` reads a real file's header and memoizes it, so the second call
    /// is a pure lookup. Also pins that an unreadable file yields nil rather
    /// than poisoning the table.
    func testResolveReadsARealHeaderAndMemoizes() throws {
        let u = tempURL("real.png")
        try? FileManager.default.removeItem(at: u)
        let w = 37, h = 11
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cg = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(u as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        defer { try? FileManager.default.removeItem(at: u) }

        ImageHeaderSizeCache.invalidate(u)
        XCTAssertNil(ImageHeaderSizeCache.cached(u), "precondition: cold")
        XCTAssertEqual(ImageHeaderSizeCache.resolve(u), CGSize(width: w, height: h))
        XCTAssertEqual(ImageHeaderSizeCache.cached(u), CGSize(width: w, height: h),
                       "resolve must memoize so later lookups do no I/O")
    }

    func testResolveOfAnUnreadableFileIsNilAndNotCached() {
        let u = tempURL("missing-\(UUID().uuidString).tif")
        XCTAssertNil(ImageHeaderSizeCache.resolve(u))
        XCTAssertNil(ImageHeaderSizeCache.cached(u))
    }

    /// Concurrent record/lookup must not trap — the thumbnail pass writes from
    /// several decode tasks at once while the viewer reads on the main thread.
    func testConcurrentAccessIsSafe() {
        let exp = expectation(description: "done")
        exp.expectedFulfillmentCount = 8
        for t in 0..<8 {
            DispatchQueue.global().async {
                for i in 0..<400 {
                    let u = self.tempURL("c\(t)-\(i).tif")
                    ImageHeaderSizeCache.record(u, width: i + 1, height: i + 2)
                    _ = ImageHeaderSizeCache.cached(u)
                }
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 30)
    }
}
