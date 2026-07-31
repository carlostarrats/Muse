//
//  ClipModel.swift
//  Muse
//
//  Model-agnostic descriptor so the license gate (which model may actually
//  ship in a paid app — an owner-only read) never blocks BUILDING the code
//  around it. Swapping models = edit `ClipModel.current` + bump `generation`,
//  which invalidates every stored vector by construction.
//

import Foundation

nonisolated struct ClipModel: Sendable, Equatable {
    let name: String
    let generation: Int
    let dimension: Int
    let imageInputSide: Int
    /// Download size in bytes, shown in the Settings offer row. 0 until the
    /// owner's conversion script has produced the real artifact.
    let downloadBytes: Int64
    let manifestURL: URL

    static let current = ClipModel(
        name: "mobileclip-s2",
        generation: 1,
        dimension: 512,
        imageInputSide: 256,
        downloadBytes: 0,
        manifestURL: URL(string: "\(DriveConfig.shareBaseURL)/models/mobileclip-s2-g1/manifest.json")!)

    /// `~/Library/Application Support/Muse/Models/<name>-g<generation>` —
    /// generation-scoped so an upgrade lands beside the old one and only
    /// deletes it after the new one verifies.
    static func directory(for model: ClipModel = .current) -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false) else { return nil }
        return support
            .appendingPathComponent("Muse/Models", isDirectory: true)
            .appendingPathComponent("\(model.name)-g\(model.generation)", isDirectory: true)
    }
}
