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
        var byBucket: [String: [String]] = [:]
        for m in members { byBucket[m.bucket, default: []].append(m.fileID) }
        return byBucket.filter { $0.value.count >= threshold }
    }
}
