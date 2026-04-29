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

enum HashService {
    /// Streams the file in 1MB chunks and returns the lowercase hex SHA-256.
    /// Returns nil on read failure.
    static func sha256(of url: URL) -> String? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: bufferSize)
            if n < 0 { return nil }
            if n == 0 { break }
            hasher.update(data: Data(bytes: buffer, count: n))
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
