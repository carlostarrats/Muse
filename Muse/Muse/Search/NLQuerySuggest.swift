//
//  NLQuerySuggest.swift
//  Muse
//
//  Fires one async parse after a committed search whose parse yielded ZERO
//  tokens and whose free text has >= minWords words — never blocks the search
//  itself; plain results show immediately. The composed text is accepted only
//  if it round-trips through the real parser into at least one token; an
//  intent that maps to nothing is dropped silently.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor final class NLQuerySuggest: ObservableObject {
    static let shared = NLQuerySuggest()
    static let minWords = 3

    struct Suggestion: Equatable { let display: String; let queryText: String }

    @Published private(set) var suggestion: Suggestion?

    private var requestToken = 0

    func consider(query: String) {
        let parsed = SearchQueryParser.parse(query)
        guard parsed.tokens.isEmpty else { suggestion = nil; return }
        guard parsed.freeText.split(separator: " ").count >= Self.minWords else {
            suggestion = nil
            return
        }
        guard Self.isAvailable() else { suggestion = nil; return }

        requestToken += 1
        let myToken = requestToken
        let text = parsed.freeText
        suggestion = nil
        Task {
            guard let composed = await Self.parse(text) else { return }
            // Superseded by a newer query while the model was thinking.
            guard myToken == self.requestToken else { return }
            // A composition that yields no tokens is worse than nothing —
            // it would just echo the query back as a "suggestion".
            guard !SearchQueryParser.parse(composed).tokens.isEmpty else { return }
            self.suggestion = Suggestion(display: composed, queryText: composed)
        }
    }

    func dismiss() {
        suggestion = nil
    }

    /// The exact availability triple `FoundationModelNamer.makeBest()` uses —
    /// never assume Foundation Models elsewhere.
    private static func isAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    private static func parse(_ text: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let session = LanguageModelSession(instructions: """
                You extract structured search fields from a photo-library search
                query. Only fill fields the text actually states.
                """)
                let response = try await session.respond(to: text, generating: NLSearchIntent.self)
                let intent = response.content
                return NLTokenComposer.compose(year: intent.year, month: intent.month,
                                               place: intent.place, camera: intent.camera,
                                               minStars: intent.minStars, subject: intent.subject)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }
}
