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
//  The manifest is also the only description the app has of what it is about to
//  download, so everything it declares is treated as UNTRUSTED INPUT, not as a
//  bound: the artifact size, the chunk count and each chunk NAME are all checked
//  here, and the download leg enforces the size while reading. A SHA-256 that
//  matches proves the assembled bytes are the ones the manifest named — it says
//  nothing about how much was transferred to find that out, or from where.
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

    /// Hard ceiling on the assembled artifact. The manifest DECLARES
    /// `totalBytes`, but a declaration from the server can't be its own bound —
    /// this is the number the app is willing to download at all, and the
    /// download leg enforces it byte by byte (see `ClipModelStore.streamChunks`).
    /// Generous against any real MobileCLIP artifact (tens of MB) and still far
    /// below anything that would fill a disk.
    static let maxArtifactBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// A chunked artifact is a handful of parts, not thousands; the cap keeps a
    /// hostile manifest from turning one accepted tap into an unbounded fetch
    /// loop even if every chunk is empty.
    static let maxChunks = 4_096

    static func parse(_ data: Data) -> ClipModelManifest? {
        guard data.count <= maxResponseBytes else { return nil }
        guard let decoded = try? JSONDecoder().decode(RawManifest.self, from: data),
              decoded.version == supportedVersion,
              decoded.totalBytes > 0, decoded.totalBytes <= maxArtifactBytes,
              !decoded.chunks.isEmpty, decoded.chunks.count <= maxChunks,
              decoded.chunks.allSatisfy(isSafeChunkName)
        else { return nil }
        return ClipModelManifest(version: decoded.version, name: decoded.name,
                                  generation: decoded.generation, totalBytes: decoded.totalBytes,
                                  sha256: decoded.sha256, chunks: decoded.chunks)
    }

    /// A chunk name is appended to the manifest's own directory URL to build the
    /// fetch URL, so it must be ONE ordinary path component. Without this a
    /// manifest could aim a chunk at any other path on the host (`../…`) — or,
    /// via a component that resolves away, at the directory itself. The digest
    /// check downstream proves the assembled BYTES, not where they came from.
    static func isSafeChunkName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        guard name != ".", name != ".." else { return false }
        // Reject separators, percent-escapes and query/fragment punctuation
        // outright rather than trying to normalize them away.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return name.unicodeScalars.allSatisfy(allowed.contains)
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
