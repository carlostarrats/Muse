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
    var dominantColor: String?                   // hex like "#aabbcc"
    var featurePrint: Data?                      // VNFeaturePrintObservation.data
    var width: Int?
    var height: Int?
    var didSucceedFeaturePrint: Bool { featurePrint != nil }
}

enum VisionServices {

    /// Run the full pipeline. Returns whatever succeeded.
    static func analyze(url: URL) async -> VisionResult {
        var result = VisionResult()
        guard let cgImage = await loadCGImage(url: url) else { return result }

        result.width = cgImage.width
        result.height = cgImage.height

        async let classify = classify(cgImage: cgImage)
        async let ocr = ocr(cgImage: cgImage)
        async let faces = detectFaces(cgImage: cgImage)
        async let featurePrint = featurePrint(cgImage: cgImage)
        async let dominantColor = dominantColor(cgImage: cgImage)

        let (cls, text, faceCount, fp, color) =
            await (classify, ocr, faces, featurePrint, dominantColor)

        result.classifications = cls
        result.ocrText = text
        result.faceCount = faceCount
        result.featurePrint = fp
        result.dominantColor = color
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

    // MARK: - Face count

    private static func detectFaces(cgImage: CGImage) async -> Int {
        await runRequest(on: cgImage, fallback: 0) { finish in
            VNDetectFaceRectanglesRequest { req, _ in
                finish((req.results as? [VNFaceObservation])?.count ?? 0)
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

    private static func dominantColor(cgImage: CGImage) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let ci = CIImage(cgImage: cgImage)
            guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(CIVector(cgRect: ci.extent), forKey: kCIInputExtentKey)
            guard let out = filter.outputImage else { return nil }
            var bitmap = [UInt8](repeating: 0, count: 4)
            let context = CIContext(options: [.workingColorSpace: NSNull()])
            context.render(out,
                           toBitmap: &bitmap,
                           rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8,
                           colorSpace: nil)
            return String(format: "#%02x%02x%02x", bitmap[0], bitmap[1], bitmap[2])
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
