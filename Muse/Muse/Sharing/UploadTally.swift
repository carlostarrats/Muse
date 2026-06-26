//
//  UploadTally.swift
//  Muse
//
//  Pure reducer: how many of N copied files have finished uploading to
//  iCloud. The NSMetadataQuery wrapper feeds it per-item uploaded flags.
//

import Foundation

struct UploadTally: Equatable {
    let uploaded: Int
    let total: Int

    var isComplete: Bool { total > 0 && uploaded == total }
    var fraction: Double { total == 0 ? 0 : Double(uploaded) / Double(total) }

    static func tally(uploadedFlags: [Bool]) -> UploadTally {
        UploadTally(uploaded: uploadedFlags.filter { $0 }.count, total: uploadedFlags.count)
    }
}
