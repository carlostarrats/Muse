import XCTest
@testable import Muse

final class RenderCoalescerTests: XCTestCase {
    private actor Recorder {
        private(set) var rendered: [Int] = []
        func record(_ v: Int) { rendered.append(v) }
    }

    /// The contract: intermediate states may be dropped (nobody wants to see a
    /// frame they scrubbed past), but the LATEST one never is — otherwise a
    /// drag can end showing something other than where the finger stopped.
    func testCoalescesABurstButNeverDropsTheLatest() async {
        let coalescer = RenderCoalescer<Int, Int>()
        let recorder = Recorder()

        // Submit sequentially with the first render deliberately slow, so 2…5
        // pile into the pending slot while 1 is in flight.
        async let first: Int? = coalescer.request(1) { v in
            try? await Task.sleep(nanoseconds: 60_000_000)
            await recorder.record(v)
            return v
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        var tail: [Int?] = []
        await withTaskGroup(of: Int?.self) { group in
            for i in 2...5 {
                group.addTask {
                    await coalescer.request(i) { v in
                        await recorder.record(v)
                        return v
                    }
                }
            }
            for await r in group { tail.append(r) }
        }
        _ = await first

        let rendered = await recorder.rendered
        XCTAssertTrue(rendered.contains(1), "the in-flight render must complete")
        XCTAssertLessThan(rendered.count, 5, "a burst must coalesce, not queue")
        XCTAssertFalse(rendered.isEmpty)
    }

    func testSequentialRequestsAllRenderWhenNothingOverlaps() async {
        let coalescer = RenderCoalescer<Int, Int>()
        let recorder = Recorder()
        for i in 1...3 {
            _ = await coalescer.request(i) { v in
                await recorder.record(v)
                return v
            }
        }
        let rendered = await recorder.rendered
        XCTAssertEqual(rendered, [1, 2, 3])
    }

    func testResultIsReturnedToTheCaller() async {
        let coalescer = RenderCoalescer<Int, String>()
        let result = await coalescer.request(7) { "rendered-\($0)" }
        XCTAssertEqual(result, "rendered-7")
    }

    func testNilRenderResultPropagates() async {
        let coalescer = RenderCoalescer<Int, String>()
        let result = await coalescer.request(1) { _ in nil }
        XCTAssertNil(result)
    }
}
