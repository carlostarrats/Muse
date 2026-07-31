//
//  VisionServices.swift
//  Muse
//
//  On-device Vision pipeline. Each service runs independently and is
//  callable in isolation. Vision partial-failure policy: if feature
//  print succeeds the file advances to `indexed`; failed sub-requests
//  are logged and retryable on a subsequent Analyze run.
//

import Foundation
import Vision
import AppKit
import CoreImage
import ImageIO

struct VisionResult {
    var classifications: [String: Float] = [:]   // label → confidence
    var ocrText: String = ""
    var faceCount: Int = 0
    /// Fraction of the frame the LARGEST detected face covers (0…1), nil with
    /// no faces. `is:portrait` needs to know the subject actually fills the
    /// frame, not merely that a face exists.
    var largestFaceFrac: Double?
    /// Best `VNFaceObservation.faceCaptureQuality` across detected faces.
    var faceQuality: Double?
    var petCount: Int = 0
    /// log10(variance of Laplacian) — see SharpnessScore.
    var sharpness: Double?
    var dominantColor: String?                   // hex like "#aabbcc"
    var featurePrint: Data?                      // VNFeaturePrintObservation.data
    var width: Int?
    var height: Int?
    /// The (bounded) raster the pipeline decoded. Callers reuse it instead of
    /// decoding the same file a second time — the palette pass used to, at a
    /// measured 851 ms on a 115 MP scan for an identical answer. nil when the
    /// image couldn't be loaded.
    var decodedImage: CGImage?
    var didSucceedFeaturePrint: Bool { featurePrint != nil }
}

enum VisionServices {

    /// Run the full pipeline. Returns whatever succeeded.
    static func analyze(url: URL) async -> VisionResult {
        guard let cgImage = await loadCGImage(url: url) else { return VisionResult() }

        var result = await analyze(cgImage: cgImage)

        // The image's TRUE pixel dimensions, from the header — NOT the decoded
        // raster's. Since the analyze decode became bounded (4096px long edge),
        // `cgImage.width/height` is the downsampled size, and these values are
        // persisted to `files.width/height` and shown in the viewer's Info card.
        // Reading them off the raster made a 9600x12000 scan report 4096x5120.
        // Falls back to the raster only if the header can't be read, which is
        // the pre-existing behaviour for an undecodable header.
        let declared = ImageHeaderSizeCache.resolve(url)
        result.width = declared.map { Int($0.width) } ?? cgImage.width
        result.height = declared.map { Int($0.height) } ?? cgImage.height
        return result
    }

    /// The request fan-out, over a raster the caller already decoded. Both the
    /// per-file live analyze and `DeepAnalysisBackfill` go through here so the
    /// face/pet/sharpness logic can never exist in two copies. `width`/`height`
    /// come from the RASTER here; `analyze(url:)` overwrites them with the
    /// header's true dimensions.
    static func analyze(cgImage: CGImage) async -> VisionResult {
        var result = VisionResult()
        result.width = cgImage.width
        result.height = cgImage.height
        result.decodedImage = cgImage

        async let classify = classify(cgImage: cgImage)
        async let ocr = ocr(cgImage: cgImage)
        async let faceTraits = detectFaceTraits(cgImage: cgImage)
        async let featurePrint = featurePrint(cgImage: cgImage)
        async let dominantColor = dominantColor(cgImage: cgImage)
        async let pets = detectAnimals(cgImage: cgImage)

        let (cls, text, faces, fp, color, petCount) =
            await (classify, ocr, faceTraits, featurePrint, dominantColor, pets)

        result.classifications = cls
        result.ocrText = text
        result.faceCount = faces.count
        result.largestFaceFrac = faces.largestFrac
        result.faceQuality = faces.quality
        result.featurePrint = fp
        result.dominantColor = color
        result.petCount = petCount
        result.sharpness = SharpnessScore.score(cgImage)
        return result
    }

    // MARK: - CGImage loader

    /// Longest edge, in pixels, of the raster handed to the Vision requests.
    ///
    /// Measured (2026-07-28 analysis-performance spec): every request's output is
    /// unchanged between 2048 and full resolution, while full resolution costs
    /// **111 seconds and ~1 GB of peak memory** on a 115 MP scanner TIFF vs well
    /// under a second at 4096. Only feature print downsamples internally —
    /// classify, faces, OCR and CIAreaAverage all scale with input pixels.
    ///
    /// 4096 rather than 2048 because the extra decode is only ~200 ms and it
    /// leaves headroom for documents with dense text: a 5100×6600 document scan
    /// lost 25% of its OCR characters at 1024, but matched full resolution
    /// exactly (918/918) at both 2048 and 4096.
    static let analysisMaxPixel = 4096

    /// Decode `url` downsampled so its longest edge is at most `maxPixel`.
    ///
    /// The decompression-bomb guard runs FIRST and must stay: Vision analysis
    /// runs AUTOMATICALLY on index of a freshly-added file (no click), and for
    /// formats ImageIO can't stream-downsample (PNG/TIFF/BMP) even a thumbnail
    /// request first materializes the FULL raster — so a planted image declaring
    /// an absurd pixel count would OOM the process before the bound applies.
    static func boundedDecode(url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              ThumbnailCache.withinDecodeBudget(src) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    private static func loadCGImage(url: URL) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            boundedDecode(url: url, maxPixel: analysisMaxPixel)
        }.value
    }

    // MARK: - Single-resume request runner

    /// Runs one Vision request and resumes the continuation EXACTLY once.
    ///
    /// `VNImageRequestHandler.perform(_:)` invokes the request's completion
    /// handler synchronously and, for the same failure, can ALSO `throw` — so
    /// a naive "resume in the handler, resume again in `catch`" double-resumes
    /// the continuation and traps (`CheckedContinuation` fatal error). That was
    /// the crash when a folder was removed mid-analysis and a file's Vision
    /// request failed. The `done` flag needs no lock: `perform` is synchronous
    /// and calls the handler on the calling thread before returning, so the
    /// handler and the `catch` can never run concurrently.
    private static func runRequest<T>(
        on cgImage: CGImage,
        fallback: T,
        makeRequest: (@escaping (T) -> Void) -> VNRequest
    ) async -> T {
        await withCheckedContinuation { continuation in
            var done = false
            let finish: (T) -> Void = { value in
                guard !done else { return }
                done = true
                continuation.resume(returning: value)
            }
            let request = makeRequest(finish)
            do {
                try VNImageRequestHandler(cgImage: cgImage).perform([request])
            } catch {
                finish(fallback)
            }
        }
    }

    // MARK: - Classify

    private static func classify(cgImage: CGImage) async -> [String: Float] {
        await runRequest(on: cgImage, fallback: [:]) { finish in
            VNClassifyImageRequest { req, _ in
                guard let results = req.results as? [VNClassificationObservation] else {
                    finish([:])
                    return
                }
                // Keep only confident-ish results
                let kept = results
                    .filter { $0.confidence >= 0.4 }
                    .prefix(10)
                finish(Dictionary(uniqueKeysWithValues: kept.map { ($0.identifier, $0.confidence) }))
            }
        }
    }

    // MARK: - OCR

    private static func ocr(cgImage: CGImage) async -> String {
        await runRequest(on: cgImage, fallback: "") { finish in
            let request = VNRecognizeTextRequest { req, _ in
                guard let results = req.results as? [VNRecognizedTextObservation] else {
                    finish("")
                    return
                }
                let strings = results.compactMap { $0.topCandidates(1).first?.string }
                finish(strings.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            return request
        }
    }

    // MARK: - Face traits

    /// A recognized-animal label below this confidence isn't counted as a pet —
    /// `pets:>0` must not fire on a low-confidence guess at a stuffed toy.
    static let petConfidenceFloor: Float = 0.5

    private static func detectFaceTraits(cgImage: CGImage) async
        -> (count: Int, largestFrac: Double?, quality: Double?) {
        let rects = await runRequest(on: cgImage, fallback: [VNFaceObservation]()) { finish in
            VNDetectFaceRectanglesRequest { req, _ in
                finish((req.results as? [VNFaceObservation]) ?? [])
            }
        }
        guard !rects.isEmpty else { return (0, nil, nil) }
        let largestFrac = rects.map { Double($0.boundingBox.width * $0.boundingBox.height) }.max()

        let qualities = await runRequest(on: cgImage, fallback: [VNFaceObservation]()) { finish in
            VNDetectFaceCaptureQualityRequest { req, _ in
                finish((req.results as? [VNFaceObservation]) ?? [])
            }
        }
        let quality = qualities.compactMap { $0.faceCaptureQuality.map(Double.init) }.max()

        return (rects.count, largestFrac, quality)
    }

    private static func detectAnimals(cgImage: CGImage) async -> Int {
        await runRequest(on: cgImage, fallback: 0) { finish in
            VNRecognizeAnimalsRequest { req, _ in
                let count = ((req.results as? [VNRecognizedObjectObservation]) ?? [])
                    .filter { obs in
                        obs.labels.contains { $0.confidence >= petConfidenceFloor }
                    }
                    .count
                finish(count)
            }
        }
    }

    // MARK: - Feature print

    private static func featurePrint(cgImage: CGImage) async -> Data? {
        await runRequest(on: cgImage, fallback: nil) { finish in
            VNGenerateImageFeaturePrintRequest { req, _ in
                guard let obs = (req.results as? [VNFeaturePrintObservation])?.first else {
                    finish(nil)
                    return
                }
                finish(obs.data)
            }
        }
    }

    // MARK: - Dominant color

    /// Average colour as `#rrggbb`, computed **in sRGB**.
    ///
    /// This used to render with `workingColorSpace: NSNull()` and
    /// `colorSpace: nil` — i.e. no colour management at all — so it read raw
    /// component values in whatever space the decoder happened to return. RAW
    /// files decode as ITU-R 2100 PQ (an HDR space), so every RAW file's stored
    /// `dominant_color` was wrong, and that feeds colour tags and colour search.
    /// Pinning both ends of the render to sRGB makes the result correct AND
    /// consistent across formats. Don't set either back to nil/NSNull.
    static func dominantColorHex(cgImage: CGImage) -> String? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let ci = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: ci.extent), forKey: kCIInputExtentKey)
        guard let out = filter.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: srgb])
        context.render(out,
                       toBitmap: &bitmap,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: srgb)
        return String(format: "#%02x%02x%02x", bitmap[0], bitmap[1], bitmap[2])
    }

    private static func dominantColor(cgImage: CGImage) async -> String? {
        await Task.detached(priority: .userInitiated) {
            dominantColorHex(cgImage: cgImage)
        }.value
    }
}

extension VisionResult {
    /// Build a single caption string from all signals. Non-empty even when
    /// classification is sparse: falls back to "(no caption)" only if literally
    /// everything is empty.
    func caption() -> String {
        var parts: [String] = []
        let topLabels = classifications
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { $0.key }
        if !topLabels.isEmpty {
            parts.append(topLabels.joined(separator: ", "))
        }
        if faceCount > 0 {
            parts.append("\(faceCount) \(faceCount == 1 ? "face" : "faces")")
        }
        if !ocrText.isEmpty {
            // First 200 chars of OCR text
            let snippet = String(ocrText.prefix(200))
                .replacingOccurrences(of: "\n", with: " ")
            parts.append("text: \(snippet)")
        }
        if let color = dominantColor {
            parts.append("dominant \(color)")
        }
        return parts.isEmpty ? "(no caption)" : parts.joined(separator: " · ")
    }
}
