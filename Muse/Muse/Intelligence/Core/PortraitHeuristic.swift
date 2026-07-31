//
//  PortraitHeuristic.swift
//  Muse
//
//  Owner-validated constants (never live-validated against real photos yet).
//  Single declaration site, consumed by PhotoSearch's is:portrait / is:group
//  tokens — so the definition of "a portrait" can't drift between the SQL and
//  a future UI that describes it.
//

nonisolated enum PortraitHeuristic {
    static let portraitMaxFaces = 2
    /// A portrait claim requires the subject actually FILLS the frame — a face
    /// occupying 1% of a landscape is a person in a scene, not a portrait.
    static let portraitMinFaceFrac = 0.05
    static let groupMinFaces = 3

    enum Classification: Equatable { case portrait, group, neither }

    static func classify(faceCount: Int, largestFrac: Double?) -> Classification {
        if faceCount >= groupMinFaces { return .group }
        if faceCount >= 1, faceCount <= portraitMaxFaces,
           let frac = largestFrac, frac >= portraitMinFaceFrac {
            return .portrait
        }
        return .neither
    }
}
