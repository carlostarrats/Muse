//
//  BoundedBody.swift
//  Muse
//
//  Read a response body with a HARD byte ceiling, enforced WHILE reading.
//
//  `URLSession.data(for:)` buffers the entire body before it returns, so a
//  `data.count <= limit` check afterwards is a check performed on memory the
//  process has already committed — the response decides the allocation, not us.
//  That is the exact reasoning the share page's `readCapped` documents on the
//  JavaScript side (`web/share/share.js`); this is its Swift counterpart, so
//  both ends of the app apply the same rule to a remote body.
//
//  It matters most for the announcements feed: that is the app's only
//  AUTOMATIC, non-user-initiated fetch, it runs at every launch, and its host
//  is remote — so the body is attacker-influenceable in principle by anyone who
//  can serve that host. A bound that only applies after the bytes are in memory
//  does not bound anything.
//
//  Content-Length is honoured when the server declares it (reject before a
//  single byte is read); when it is absent or lies, the streaming tally is what
//  actually enforces the ceiling.
//

import Foundation

nonisolated enum BoundedBody {
    enum FetchError: Error, Equatable {
        /// The body exceeded `limit`, either by declaration or in flight.
        case tooLarge
    }

    /// Fetch `request`, failing rather than allocating past `limit` bytes.
    /// Returns the body plus the response, so callers keep their status check.
    static func data(for request: URLRequest,
                     session: URLSession,
                     limit: Int) async throws -> (Data, URLResponse) {
        let (stream, response) = try await session.bytes(for: request)

        // Declared oversize: refuse before reading anything at all.
        if response.expectedContentLength > 0,
           response.expectedContentLength > Int64(limit) {
            throw FetchError.tooLarge
        }

        var body = Data()
        body.reserveCapacity(min(limit, 64 * 1024))
        for try await byte in stream {
            body.append(byte)
            // Strictly greater: a body of exactly `limit` bytes is allowed
            // through, matching the callers' `count <= max` contract.
            if body.count > limit { throw FetchError.tooLarge }
        }
        return (body, response)
    }
}
