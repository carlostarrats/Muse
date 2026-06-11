import Foundation
import NaturalLanguage

final class SentenceEmbedder: Embedder {
    let modelVersion = "nl-sentence-v1"
    let dimension: Int
    private let model: NLEmbedding

    private init(model: NLEmbedding) {
        self.model = model
        self.dimension = model.dimension
    }

    static func makeIfAvailable() -> SentenceEmbedder? {
        guard let m = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        return SentenceEmbedder(model: m)
    }

    func embed(_ text: String) -> [Float]? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let v = model.vector(for: t.lowercased()) else { return nil }
        return v.map { Float($0) }
    }
}
