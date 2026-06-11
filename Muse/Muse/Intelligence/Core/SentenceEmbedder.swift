import Foundation

final class SentenceEmbedder: Embedder {
    let modelVersion = "nl-sentence-v1"
    let dimension: Int = 0
    static func makeIfAvailable() -> SentenceEmbedder? { nil }   // real body: Task 7
    func embed(_ text: String) -> [Float]? { nil }
}
