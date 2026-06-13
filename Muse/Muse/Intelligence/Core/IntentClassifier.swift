import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Pure helpers turning a TaggerOutput's signals into classifier inputs.
enum IntentInput {
    /// True when Vision's deterministic StyleKind tagged this image a screenshot.
    static func isScreenshot(tags: [IntelTag]) -> Bool {
        tags.contains { $0.source == "vision-kind" && $0.label == "screenshot" }
    }

    /// The Vision classification labels (excludes color/kind tags).
    static func visionLabels(tags: [IntelTag]) -> [String] {
        tags.filter { $0.source == "vision" }.map(\.label)
    }

    /// OCR text capped — recipes/receipts/code declare themselves early.
    static func ocrSnippet(_ ocr: String, max: Int = 600) -> String {
        String(ocr.prefix(max))
    }
}

/// Classifies a screenshot into an IntentBucket, or nil ("none" / unsure).
protocol IntentClassifying: Sendable {
    func classify(ocrText: String, visionLabels: [String]) async -> IntentBucket?
}

/// Fallback on non-Apple-Intelligence Macs: never classifies.
struct NoIntentClassifier: IntentClassifying {
    func classify(ocrText: String, visionLabels: [String]) async -> IntentBucket? { nil }
}

enum IntentClassifierFactory {
    /// FM-backed classifier on capable Macs, else the no-op fallback.
    static func makeBest() -> IntentClassifying {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *),
           SystemLanguageModel.default.availability == .available {
            return FoundationModelIntentClassifier()
        }
        #endif
        return NoIntentClassifier()
    }

    /// Model version recorded on each classified file.
    static var modelVersion: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *),
           SystemLanguageModel.default.availability == .available {
            return "intent-fm-v1"
        }
        #endif
        return "intent-none-v1"
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
struct FoundationModelIntentClassifier: IntentClassifying {
    private static let instructions = """
    You classify a single screenshot into exactly one category from a fixed list, \
    using its extracted text and image labels. Prefer "none" whenever the screenshot \
    does not clearly belong to a category — a wrong label is worse than none. \
    Reply with ONLY the lowercase category key and nothing else.
    """

    func classify(ocrText: String, visionLabels: [String]) async -> IntentBucket? {
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let prompt = """
            Categories: \(IntentBucket.promptKeys), none.
            Image labels: \(visionLabels.prefix(8).joined(separator: ", ")).
            Extracted text: \(ocrText)

            Reply with ONLY one category key, or "none".
            """
            let response = try await session.respond(to: prompt)
            return IntentBucket.from(response.content)
        } catch {
            return nil
        }
    }
}
#endif
