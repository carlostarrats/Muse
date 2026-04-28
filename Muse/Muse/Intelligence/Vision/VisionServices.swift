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

    private static func loadCGImage(url: URL) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let img = NSImage(contentsOf: url) else { return nil }
            var rect = CGRect(origin: .zero, size: img.size)
            return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }.value
    }

    // MARK: - Classify

    private static func classify(cgImage: CGImage) async -> [String: Float] {
        await withCheckedContinuation { continuation in
            let request = VNClassifyImageRequest { req, _ in
                guard let results = req.results as? [VNClassificationObservation] else {
                    continuation.resume(returning: [:])
                    return
                }
                // Keep only confident-ish results
                let kept = results
                    .filter { $0.confidence >= 0.4 }
                    .prefix(10)
                let dict = Dictionary(uniqueKeysWithValues: kept.map { ($0.identifier, $0.confidence) })
                continuation.resume(returning: dict)
            }
            do {
                try VNImageRequestHandler(cgImage: cgImage).perform([request])
            } catch {
                continuation.resume(returning: [:])
            }
        }
    }

    // MARK: - OCR

    private static func ocr(cgImage: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                guard let results = req.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                let strings = results.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: strings.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: cgImage).perform([request])
            } catch {
                continuation.resume(returning: "")
            }
        }
    }

    // MARK: - Face count

    private static func detectFaces(cgImage: CGImage) async -> Int {
        await withCheckedContinuation { continuation in
            let request = VNDetectFaceRectanglesRequest { req, _ in
                let count = (req.results as? [VNFaceObservation])?.count ?? 0
                continuation.resume(returning: count)
            }
            do {
                try VNImageRequestHandler(cgImage: cgImage).perform([request])
            } catch {
                continuation.resume(returning: 0)
            }
        }
    }

    // MARK: - Feature print

    private static func featurePrint(cgImage: CGImage) async -> Data? {
        await withCheckedContinuation { continuation in
            let request = VNGenerateImageFeaturePrintRequest { req, _ in
                guard let obs = (req.results as? [VNFeaturePrintObservation])?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: obs.data)
            }
            do {
                try VNImageRequestHandler(cgImage: cgImage).perform([request])
            } catch {
                continuation.resume(returning: nil)
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
