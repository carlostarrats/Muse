import Foundation

final class VisionTagger: Tagger {
    let modelVersion = "vision-v1"

    func analyze(url: URL) async -> TaggerOutput? {
        let v = await VisionServices.analyze(url: url)
        // VisionServices.analyze returns an empty VisionResult when the image
        // can't be loaded — width is only set after a successful CGImage load.
        guard v.width != nil else { return nil }

        var tags: [IntelTag] = v.classifications.map {
            IntelTag(label: $0.key, confidence: Double($0.value), source: "vision")
        }

        let palette = PaletteExtractor.palette(for: url)
        var colorNames = Set<String>()
        for hex in palette.prefix(3) {
            if let n = NamedColor.name(forHex: hex) { colorNames.insert(n) }
        }
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
