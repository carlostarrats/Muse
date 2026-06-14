import Foundation

struct IntelTag: Equatable {
    var label: String
    var confidence: Double?
    var source: String        // "vision" | "vision-color" | "vision-kind" | future
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
}

protocol Tagger {
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
