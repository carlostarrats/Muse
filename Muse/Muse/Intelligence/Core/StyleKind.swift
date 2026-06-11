import Foundation

/// Coarse "what kind of image is this" from Vision labels + metadata.
/// Deterministic rule ladder — first match wins.
enum StyleKind {
    static let screenAspects: [Double] = [16.0/10, 16.0/9, 4.0/3, 19.5/9]

    static func classify(labels: [String: Float], width: Int?, height: Int?,
                         ocrLength: Int, faceCount: Int) -> String {
        let keys = Set(labels.keys.map { $0.lowercased() })

        // Rule 1: Screen words + high OCR
        if hasAny(keys, ["screen", "screenshot", "monitor", "computer", "website", "software"]) && ocrLength > 80 { return "screenshot" }

        // Rule 2: Screen-like aspect ratio + high OCR
        if isScreenLike(width: width, height: height) && ocrLength > 400 { return "screenshot" }

        // Rule 3: Diagram words
        if hasAny(keys, ["diagram", "chart", "graph", "blueprint", "map"]) { return "diagram" }

        // Rule 4: Poster words
        if hasAny(keys, ["poster", "flyer", "advertisement", "album cover", "book"]) { return "poster" }

        // Rule 5: Illustration words
        if hasAny(keys, ["illustration", "drawing", "cartoon", "painting", "sketch", "anime", "art"]) { return "illustration" }

        // Rule 6: High OCR text = diagram
        if ocrLength > 600 { return "diagram" }

        // Rule 7: Default to photo
        return "photo"
    }

    private static func hasAny(_ keys: Set<String>, _ words: [String]) -> Bool {
        keys.contains { k in words.contains { k.contains($0) } }
    }

    private static func isScreenLike(width: Int?, height: Int?) -> Bool {
        guard let w = width, let h = height, w > 0, h > 0 else { return false }
        let aspect = Double(w) / Double(h)

        for screenAspect in screenAspects {
            let diff = abs(aspect - screenAspect)
            let reciprocalDiff = abs(1.0 / aspect - screenAspect)
            if diff < 0.02 || reciprocalDiff < 0.02 {
                return true
            }
        }
        return false
    }
}
