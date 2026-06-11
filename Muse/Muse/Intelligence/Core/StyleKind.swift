import Foundation

/// Coarse "what kind of image is this" from Vision labels + metadata.
/// Deterministic rule ladder — first match wins.
enum StyleKind {
    static let screenAspects: [Double] = [16.0/10, 16.0/9, 4.0/3, 19.5/9]

    static func classify(labels: [String: Float], width: Int?, height: Int?,
                         ocrLength: Int, faceCount: Int) -> String {
        let keys = Set(labels.keys.map { $0.lowercased() })

        // Rule 1: Screen/screenshot
        if hasScreenLabel(keys) && ocrLength > 80 { return "screenshot" }

        let isScreenLike = computeScreenLikeness(width: width, height: height)
        if isScreenLike && ocrLength > 400 { return "screenshot" }

        // Rule 2: Diagram
        if hasDiagramLabel(keys) { return "diagram" }

        // Rule 3: Poster
        if hasPosterLabel(keys) { return "poster" }

        // Rule 4: Illustration
        if hasIllustrationLabel(keys) { return "illustration" }

        // Rule 5: High OCR text = diagram
        if ocrLength > 600 { return "diagram" }

        return "photo"
    }

    private static func hasScreenLabel(_ keys: Set<String>) -> Bool {
        let screenWords = ["screen", "screenshot", "monitor", "computer", "website", "software"]
        for key in keys {
            for word in screenWords {
                if key.contains(word) {
                    return true
                }
            }
        }
        return false
    }

    private static func hasDiagramLabel(_ keys: Set<String>) -> Bool {
        let diagramWords = ["diagram", "chart", "graph", "blueprint", "map"]
        for key in keys {
            for word in diagramWords {
                if key.contains(word) {
                    return true
                }
            }
        }
        return false
    }

    private static func hasPosterLabel(_ keys: Set<String>) -> Bool {
        let posterWords = ["poster", "flyer", "advertisement", "album cover", "book"]
        for key in keys {
            for word in posterWords {
                if key.contains(word) {
                    return true
                }
            }
        }
        return false
    }

    private static func hasIllustrationLabel(_ keys: Set<String>) -> Bool {
        let illustrationWords = ["illustration", "drawing", "cartoon", "painting", "sketch", "anime", "art"]
        for key in keys {
            for word in illustrationWords {
                if key.contains(word) {
                    return true
                }
            }
        }
        return false
    }

    private static func computeScreenLikeness(width: Int?, height: Int?) -> Bool {
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
