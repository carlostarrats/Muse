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

    /// Distinct hue per bucket for the Galaxy "taste map" trial.
    var galaxyHex: String {
        switch self {
        case .recipe:       return "#5BA85B"
        case .shopping:     return "#5588CC"
        case .places:       return "#CC8855"
        case .receipt:      return "#999999"
        case .quote:        return "#B07AD0"
        case .article:      return "#C0A14E"
        case .conversation: return "#4EB0A8"
        case .event:        return "#D06A8C"
        case .design:       return "#7A6AD0"
        case .code:         return "#6A8FA8"
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
