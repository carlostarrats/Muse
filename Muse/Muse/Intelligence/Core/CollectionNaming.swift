import Foundation

final class TagFallbackNamer: CollectionNamer {
    let modelVersion = "topTag-v1"
    func name(tagsByFrequency: [String]) async -> String {
        tagsByFrequency.first?.capitalized ?? "Collection"
    }
    static func makeBest() -> CollectionNamer { TagFallbackNamer() }   // FM gating: Task 13
}
