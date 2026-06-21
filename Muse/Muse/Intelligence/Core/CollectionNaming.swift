import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

final class TagFallbackNamer: CollectionNamer {
    let modelVersion = "topTag-v1"
    private let localizer: VocabularyLocalizer

    init(localizer: VocabularyLocalizer = .shared) {
        self.localizer = localizer
    }

    func name(tagsByFrequency: [String]) async -> String {
        // Localize the top (canonical) tag for display, then capitalize. The
        // result becomes the stored collection name (user data thereafter).
        guard let top = tagsByFrequency.first else { return "Collection" }
        return localizer.display(top).capitalized
    }

    /// Returns the FM-backed namer on Apple Intelligence-capable Macs
    /// (Apple Intelligence Macs only), otherwise the top-tag fallback.
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

    /// The app's effective UI language as a human name (e.g. "French"), so the
    /// model is asked to title the collection in the user's language.
    private static var languageName: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.current.localizedString(forLanguageCode: code) ?? "English"
    }

    func name(tagsByFrequency: [String]) async -> String {
        let fallback = tagsByFrequency.first?.capitalized ?? "Collection"
        guard !tagsByFrequency.isEmpty else { return fallback }
        let language = Self.languageName
        do {
            let session = LanguageModelSession(instructions: """
            You name small collections of images from their descriptive tags.
            Reply with ONLY a short collection title, 1-3 words, no punctuation,
            written in \(language).
            """)
            let prompt = """
            These tags describe a group of images: \(tagsByFrequency.prefix(8).joined(separator: ", ")).
            Reply with ONLY a short collection title, 1-3 words, no punctuation, in \(language).
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
