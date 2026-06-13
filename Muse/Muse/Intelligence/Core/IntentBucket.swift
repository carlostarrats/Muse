import Foundation

/// The fixed vocabulary of screenshot intent types. Pure (no AppKit).
enum IntentBucket: String, CaseIterable {
    case recipe, shopping, places, receipt, quote
    case article, conversation, event, design, code

    /// Stable collection id so reclustering updates the same collection.
    var collectionID: String { "intent:\(rawValue)" }

    var displayName: String {
        switch self {
        case .recipe:       return "Recipes"
        case .shopping:     return "Shopping"
        case .places:       return "Places"
        case .receipt:      return "Receipts"
        case .quote:        return "Quotes"
        case .article:      return "Articles"
        case .conversation: return "Conversations"
        case .event:        return "Events"
        case .design:       return "Design"
        case .code:         return "Code"
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
