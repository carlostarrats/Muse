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
