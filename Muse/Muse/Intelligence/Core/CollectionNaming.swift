import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

final class TagFallbackNamer: CollectionNamer {
    let modelVersion = "topTag-v1"
    func name(tagsByFrequency: [String]) async -> String {
        tagsByFrequency.first?.capitalized ?? "Collection"
    }

    /// Returns the FM-backed namer on Apple Intelligence-capable Macs
    /// (same gate as ChatService), otherwise the top-tag fallback.
    static func makeBest() -> CollectionNamer {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *),
           SystemLanguageModel.default.availability == .available {
            return FoundationModelNamer()
        }
        #endif
        return TagFallbackNamer()
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
final class FoundationModelNamer: CollectionNamer {
    let modelVersion = "fm-namer-v1"

    private static let instructions = """
    You name small collections of images from their descriptive tags.
    Reply with ONLY a short collection title, 1-3 words, no punctuation.
    """

    func name(tagsByFrequency: [String]) async -> String {
        let fallback = tagsByFrequency.first?.capitalized ?? "Collection"
        guard !tagsByFrequency.isEmpty else { return fallback }
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let prompt = """
            These tags describe a group of images: \(tagsByFrequency.prefix(8).joined(separator: ", ")).
            Reply with ONLY a short collection title, 1-3 words, no punctuation.
            """
            let response = try await session.respond(to: prompt)
            let title = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return (title.isEmpty || title.count > 40) ? fallback : title
        } catch {
            return fallback
        }
    }
}
#endif
