//
//  SharpnessRank.swift
//  Muse
//
//  Relative-WITHIN-the-compared-set ranking — variance-of-Laplacian has no
//  defensible absolute scale across subjects, so this is the honest read of
//  the metric: who's sharpest HERE, never an absolute grade.
//

nonisolated enum SharpnessRank {
    /// log10 units. Owner-validated, never live-validated against real photos yet.
    static let tieBand: Double = 0.15

    enum SharpnessMark: Equatable { case sharpest, comparable, softer, unmarked }

    static func rank(scores: [Double?]) -> [SharpnessMark] {
        guard !scores.isEmpty else { return [] }
        guard let maxScore = scores.compactMap({ $0 }).max() else {
            return scores.map { _ in .unmarked }
        }
        return scores.map { score in
            guard let score else { return .unmarked }
            if score == maxScore { return .sharpest }
            return (maxScore - score) <= tieBand ? .comparable : .softer
        }
    }
}
