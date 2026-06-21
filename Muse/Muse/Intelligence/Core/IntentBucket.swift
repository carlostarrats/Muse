import Foundation

/// The fixed vocabulary of screenshot intent types. Pure (no AppKit).
enum IntentBucket: String, CaseIterable {
    case recipe, shopping, places, receipt, quote
    case article, conversation, event, design, code

    /// Stable collection id so reclustering updates the same collection.
    var collectionID: String { "intent:\(rawValue)" }

    var displayName: String {
        switch self {
        case .recipe:       return String(localized: "Recipes")
        case .shopping:     return String(localized: "Shopping")
        case .places:       return String(localized: "Places")
        case .receipt:      return String(localized: "Receipts")
        case .quote:        return String(localized: "Quotes")
        case .article:      return String(localized: "Articles")
        case .conversation: return String(localized: "Conversations")
        case .event:        return String(localized: "Events")
        case .design:       return String(localized: "Design")
        case .code:         return String(localized: "Code")
        }
    }

    /// Comma-separated keys for the classifier prompt.
    static var promptKeys: String { allCases.map(\.rawValue).joined(separator: ", ") }

    /// Validate a raw model response. Off-list / "none" / empty → nil.
    static func from(_ raw: String) -> IntentBucket? {
        let key = raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return IntentBucket(rawValue: key)
    }
}
