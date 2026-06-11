import Foundation

/// Single place where implementations are chosen, capability-gated.
/// macOS 27 adapters get added here with new modelVersions — nothing
/// else in the app changes.
final class IntelligenceRegistry {
    static let shared = IntelligenceRegistry()
    let tagger: Tagger
    let embedder: Embedder?           // nil if no embedding model available
    let clusterer: Clusterer
    let namer: CollectionNamer

    private init() {
        tagger = VisionTagger()
        embedder = SentenceEmbedder.makeIfAvailable()
        clusterer = HybridClusterer()
        namer = TagFallbackNamer.makeBest()
    }
}
