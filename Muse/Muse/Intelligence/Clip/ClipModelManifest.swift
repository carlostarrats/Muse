//
//  ClipModelManifest.swift
//  Muse
//
//  Pure parse/verify layer for the CLIP model manifest — kept separate from
//  ClipModelStore so it's unit-testable without a network call. Response
//  capped at 16 KB; an unknown version is refused; assembled bytes are
//  SHA-256-verified before anything is unpacked. Fail closed, the same
//  posture as GeoNamesDataset's bounded inflate.
//

import CryptoKit
import Foundation

nonisolated struct ClipModelManifest: Equatable {
    let version: Int
    let name: String
    let generation: Int
    let totalBytes: Int64
    let sha256: String
    let chunks: [String]

    static let maxResponseBytes = 16 * 1024
    static let supportedVersion = 1

    static func parse(_ data: Data) -> ClipModelManifest? {
        guard data.count <= maxResponseBytes else { return nil }
        guard let decoded = try? JSONDecoder().decode(RawManifest.self, from: data),
              decoded.version == supportedVersion
        else { return nil }
        return ClipModelManifest(version: decoded.version, name: decoded.name,
                                  generation: decoded.generation, totalBytes: decoded.totalBytes,
                                  sha256: decoded.sha256, chunks: decoded.chunks)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func verify(assembled: Data, expectedSHA256: String) -> Bool {
        sha256Hex(assembled) == expectedSHA256
    }

    /// The same check for a download that was streamed to disk rather than
    /// assembled in memory — the caller feeds each chunk to a running
    /// `SHA256` and hands over the finished digest.
    static func hex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func verify(digest: SHA256Digest, expectedSHA256: String) -> Bool {
        hex(digest) == expectedSHA256
    }

    private struct RawManifest: Codable {
        let version: Int
        let name: String
        let generation: Int
        let totalBytes: Int64
        let sha256: String
        let chunks: [String]
    }
}
