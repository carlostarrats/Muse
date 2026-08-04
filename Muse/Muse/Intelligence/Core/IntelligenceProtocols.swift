import CoreGraphics
import Foundation

struct IntelTag: Equatable {
    var label: String
    var confidence: Double?
    var source: String        // "vision" | "vision-color" | "vision-kind" | future
}

/// The raster-derived scalars that land in `photo_traits`. Carried through
/// `TaggerOutput` so the analyze pass writes them inside its own guarded
/// transaction rather than re-decoding the file.
nonisolated struct TraitFields {
    var faceCount: Int
    var largestFaceFrac: Double?
    var faceQuality: Double?
    var petCount: Int
    var sharpness: Double?
    var clipHighR: Double?
    var clipHighG: Double?
    var clipHighB: Double?
    var clipLow: Double?
    var noiseSigma: Double?

    init(from result: VisionResult) {
        faceCount = result.faceCount
        largestFaceFrac = result.largestFaceFrac
        faceQuality = result.faceQuality
        petCount = result.petCount
        sharpness = result.sharpness
        clipHighR = result.clipHighR
        clipHighG = result.clipHighG
        clipHighB = result.clipHighB
        clipLow = result.clipLow
        noiseSigma = result.noiseSigma
    }
}

struct TaggerOutput {
    var tags: [IntelTag]
    var caption: String?
    var ocrText: String
    var dominantColor: String?
    var palette: [String]     // hex, ≤6
    var featurePrint: Data?
    var width: Int?
    var height: Int?
    var traits: TraitFields?
    /// The bounded raster the tagger already decoded — reused by the CLIP
    /// embed write so a file is never decoded twice in one pass.
    var decodedImage: CGImage?
}

nonisolated protocol Tagger {
    var modelVersion: String { get }
    func analyze(url: URL) async -> TaggerOutput?
}

protocol Embedder {
    var modelVersion: String { get }
    var dimension: Int { get }
    /// nil when the model can't embed the text (e.g. empty input)
    func embed(_ text: String) -> [Float]?
}

struct ClusterItem {
    var id: String
    var textVector: [Float]?
    var featurePrint: Data?
}

struct Cluster {
    var memberIDs: [String]
}

protocol Clusterer: Sendable {
    var modelVersion: String { get }
    nonisolated func cluster(_ items: [ClusterItem]) -> [Cluster]
}

protocol CollectionNamer {
    var modelVersion: String { get }
    /// tagsByFrequency: most common member tags first, colors excluded
    func name(tagsByFrequency: [String]) async -> String
}
