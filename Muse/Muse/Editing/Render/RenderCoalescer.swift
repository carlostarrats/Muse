//
//  RenderCoalescer.swift
//  Muse
//
//  At most ONE render in flight; a newer request overwrites the pending slot
//  rather than queueing behind it.
//
//  The anti-pattern this replaces (Surface Camera's unthrottled per-tick
//  loop): a slider drag emits parameter changes far faster than a 24 MP render
//  completes, so an unbounded queue means the canvas is always showing a
//  render from several hundred milliseconds ago and the backlog keeps growing
//  as long as the finger is down. Dropping intermediate states is not lossy
//  here — nobody wants to see the frame they scrubbed past — but dropping the
//  LATEST one is, so the pending slot always survives.
//

import Foundation

actor RenderCoalescer<Params: Sendable, Output: Sendable> {
    private var inFlight = false
    private var pending: (params: Params, render: @Sendable (Params) async -> Output?)?
    private var waiters: [CheckedContinuation<Output?, Never>] = []

    func request(_ params: Params,
                 render: @Sendable @escaping (Params) async -> Output?) async -> Output? {
        if inFlight {
            // Overwrite rather than append — the older pending params are
            // already stale by definition.
            pending = (params, render)
            return await withCheckedContinuation { waiters.append($0) }
        }
        inFlight = true
        var result = await render(params)
        // Drain the pending slot in a LOOP, not by recursing: a long drag can
        // hand off hundreds of times, and recursion would grow the stack for
        // the whole gesture.
        while let next = pending {
            pending = nil
            let resumed = waiters
            waiters = []
            result = await next.render(next.params)
            for waiter in resumed { waiter.resume(returning: result) }
        }
        inFlight = false
        // Anything that arrived while the last render was completing but after
        // the loop's check would be stranded, so release it explicitly.
        let leftovers = waiters
        waiters = []
        for waiter in leftovers { waiter.resume(returning: result) }
        return result
    }
}
