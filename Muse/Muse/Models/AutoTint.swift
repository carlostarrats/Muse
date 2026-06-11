//
//  AutoTint.swift
//  Muse
//
//  Auto mood (polish spec §4): tints the background from the dominant
//  colors of the current view's content. Pure HSB blend + one indexed
//  GRDB read. Hue preserved, saturation capped, brightness pinned dark
//  so thumbnails and text always hold up.
//

import Foundation
import GRDB

struct AutoTint: Equatable {
    var background: MoodRGB
    var tile: MoodRGB

    var palette: MoodPalette {
        MoodPalette(backgroundRGB: background, tileRGB: tile, scheme: .dark)
    }

    /// Average the colors, keep the hue, cap saturation, pin brightness.
    static func blend(hexes: [String]) -> AutoTint? {
        let rgbs = hexes.compactMap { NamedColor.parse($0) }
        guard !rgbs.isEmpty else { return nil }
        let n = Double(rgbs.count)
        let sum = rgbs.reduce((0.0, 0.0, 0.0)) {
            ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2)
        }
        var (h, s, _) = rgbToHSB(sum.0 / n, sum.1 / n, sum.2 / n)
        s = min(s, 0.32)
        let bg = hsbToRGB(h, s, 0.13)
        let tile = hsbToRGB(h, s, 0.20)
        return AutoTint(background: MoodRGB(r: bg.0, g: bg.1, b: bg.2),
                        tile: MoodRGB(r: tile.0, g: tile.1, b: tile.2))
    }

    /// Dominant colors for the given absolute paths (alive, non-null only).
    static func dominantColors(queue: DatabaseQueue,
                               paths: [String],
                               limit: Int = 48) async throws -> [String] {
        let sample = Array(paths.prefix(limit))
        guard !sample.isEmpty else { return [] }
        return try await queue.read { db in
            let marks = databaseQuestionMarks(count: sample.count)
            return try String.fetchAll(db, sql: """
                SELECT f.dominant_color FROM files f
                JOIN paths p ON p.file_id = f.id
                WHERE p.is_alive = 1 AND f.dominant_color IS NOT NULL
                  AND p.absolute_path IN (\(marks))
                """, arguments: StatementArguments(sample))
        }
    }

    // MARK: - HSB math (pure; h in degrees 0..<360, s/v in 0...1)

    static func rgbToHSB(_ r: Double, _ g: Double, _ b: Double)
        -> (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r {
                h = ((g - b) / d).truncatingRemainder(dividingBy: 6)
            } else if mx == g {
                h = (b - r) / d + 2
            } else {
                h = (r - g) / d + 4
            }
            h *= 60
            if h < 0 { h += 360 }
        }
        let s = mx == 0 ? 0 : d / mx
        return (h, s, mx)
    }

    static func hsbToRGB(_ h: Double, _ s: Double, _ v: Double)
        -> (Double, Double, Double) {
        let c = v * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<60:  (r, g, b) = (c, x, 0)
        case ..<120: (r, g, b) = (x, c, 0)
        case ..<180: (r, g, b) = (0, c, x)
        case ..<240: (r, g, b) = (0, x, c)
        case ..<300: (r, g, b) = (x, 0, c)
        default:     (r, g, b) = (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }
}
