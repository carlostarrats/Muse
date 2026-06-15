import Foundation

/// Turns Apple Vision's raw `VNClassifyImageRequest` labels into a small set of
/// clean, human-friendly tags. Pure + deterministic.
///
/// Vision's taxonomy is large and machine-flavoured: it emits abstract terms
/// (`material`, `structure`, `conveyance`), sensitive demographic guesses
/// (`adult`, `female`), and underscored compounds (`wood_processed`,
/// `blue_sky`, `printed_page`). Surfacing those raw as user tags is noisy and
/// occasionally alarming. This layer: drops noise + sensitive labels, remaps
/// known-ugly ones to friendly words, replaces remaining underscores with
/// spaces, applies a confidence floor, dedupes, and caps the count.
enum ClassificationCuration {
    /// Minimum Vision confidence to surface a label as a tag.
    static let confidenceFloor: Double = 0.45
    /// Most classification tags to keep per image (most-confident first).
    static let maxLabels = 5

    /// Abstract / structural / sensitive / demographic labels that are not
    /// useful (or not appropriate) as browse-able tags.
    private static let drop: Set<String> = [
        // Sensitive / demographic guesses — keep the neutral "people" instead.
        "adult", "adults", "male", "female", "man", "woman", "boy", "girl",
        "child", "children", "baby", "infant", "toddler", "senior", "teenager",
        // Abstract / structural / meaningless as a tag.
        "material", "structure", "object", "entity", "thing", "abstraction",
        "conveyance", "instrumentality", "instrument", "artifact", "artefact",
        "commodity", "consumer_goods", "covering", "container", "carton",
        "surface", "land", "still_life", "whole", "part", "matter", "substance",
    ]

    /// Known-ugly labels → friendly replacements (empty value would drop it,
    /// but `drop` is the mechanism for that; everything here keeps meaning).
    private static let remap: [String: String] = [
        "wood_processed": "wood",
        "printed_page": "document",
        "blue_sky": "sky",
        "footwear": "shoes",
        "automobile": "car",
        "motor_vehicle": "vehicle",
        "illustrations": "illustration",
        "signage": "sign",
        "human_face": "face",
        "people_group": "people",
    ]

    /// Curate raw `label → confidence` into ordered, friendly tag labels with
    /// their confidences. Most-confident first, deduped, capped at `maxLabels`.
    static func curate(_ raw: [String: Float], max: Int = maxLabels) -> [(label: String, confidence: Double)] {
        var out: [(label: String, confidence: Double)] = []
        var seen = Set<String>()
        for (id, conf) in raw.sorted(by: { $0.value > $1.value }) {
            let c = Double(conf)
            if c < confidenceFloor { continue }
            let lower = id.lowercased()
            if drop.contains(lower) { continue }
            let label = (remap[lower] ?? lower).replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if label.isEmpty || drop.contains(label) { continue }
            if seen.contains(label) { continue }   // keep the higher confidence (first seen)
            seen.insert(label)
            out.append((label, c))
            if out.count >= max { break }
        }
        return out
    }
}
