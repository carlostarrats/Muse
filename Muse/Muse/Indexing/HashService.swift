//
//  HashService.swift
//  Muse
//
//  Streaming SHA-256 hashing for arbitrarily-large files. Buffer size
//  tuned for SSDs; HDDs and network drives also benefit from large
//  reads. Cancellable per call.
//

import Foundation
import CryptoKit

nonisolated enum HashService {
    /// Streams the file in 1MB chunks and returns the lowercase hex SHA-256.
    /// Returns nil on read failure.
    static func sha256(of url: URL) -> String? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var totalBytes = 0
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: bufferSize)
            if n < 0 { return nil }
            if n == 0 { break }
            totalBytes += n
            hasher.update(data: Data(bytes: buffer, count: n))
        }
        if stream.streamError != nil { return nil }
        if totalBytes == 0 {
            // Zero bytes off a non-empty file is a failed read (dataless
            // iCloud placeholder, permissions). Hashing it as "empty"
            // once welded 1750 evicted files to a single phantom files row.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 0 { return nil }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
