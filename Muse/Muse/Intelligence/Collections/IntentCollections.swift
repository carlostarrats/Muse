import Foundation

/// Pure logic deciding which intent buckets are big enough to surface as
/// collections. Kept separate from the DB-bound CollectionsEngine so it's
/// unit-testable.
enum IntentCollections {
    /// Minimum alive members before a bucket becomes a visible collection.
    static let threshold = 3

    /// members: (fileID, bucketKey) for ALL alive typed screenshots.
    /// Returns bucketKey -> fileIDs for buckets meeting the threshold.
    static func qualifyingBuckets(
        members: [(fileID: String, bucket: String)],
        threshold: Int = threshold
    ) -> [String: [String]] {
        // Dedupe fileIDs per bucket: the same content can exist under several
        // alive paths (copied into multiple folders), and the upstream query
        // JOINs paths, so a single screenshot can appear N times. Counting
        // entries would let one distinct image cross the threshold N-fold.
        // The gate must count DISTINCT files.
        var byBucket: [String: Set<String>] = [:]
        for m in members { byBucket[m.bucket, default: []].insert(m.fileID) }
        return byBucket
            .filter { $0.value.count >= threshold }
            .mapValues { Array($0) }
    }
}
