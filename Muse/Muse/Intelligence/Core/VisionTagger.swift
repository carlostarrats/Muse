import Foundation

final class VisionTagger: Tagger {
    let modelVersion = "vision-v1"

    func analyze(url: URL) async -> TaggerOutput? {
        let v = await VisionServices.analyze(url: url)
        // VisionServices.analyze returns an empty VisionResult when the image
        // can't be loaded — width is only set after a successful CGImage load.
        guard v.width != nil else { return nil }

        // Curate Vision's raw taxonomy into clean, human-friendly tags
        // (drops abstract/sensitive labels, remaps ugly compounds).
        var tags: [IntelTag] = ClassificationCuration.curate(v.classifications).map {
            IntelTag(label: $0.label, confidence: $0.confidence, source: "vision")
        }

        // Weighted palette: only colors that actually dominate become tags, so
        // a tiny accent (or a portrait's skin sliver) no longer tags the whole
        // image. The stored palette keeps the full sorted list (backdrop/wash).
        let weighted = PaletteExtractor.weightedPalette(for: url)
        let palette = weighted.map { $0.0 }
        let colorNames = ColorTagger.tags(fromWeighted: weighted)
        tags += colorNames.map { IntelTag(label: $0, confidence: nil, source: "vision-color") }

        let kind = StyleKind.classify(labels: v.classifications,
                                      width: v.width, height: v.height,
                                      ocrLength: v.ocrText.count,
                                      faceCount: v.faceCount)
        tags.append(IntelTag(label: kind, confidence: nil, source: "vision-kind"))

        return TaggerOutput(tags: tags,
                            caption: v.caption(),
                            ocrText: v.ocrText,
                            dominantColor: v.dominantColor,
                            palette: palette,
                            featurePrint: v.featurePrint,
                            width: v.width, height: v.height)
    }
}
