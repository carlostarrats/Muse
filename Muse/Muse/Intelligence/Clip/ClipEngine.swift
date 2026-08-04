//
//  ClipEngine.swift
//  Muse
//
//  An actor so MLModel access serializes without locks. Loads both encoders
//  lazily from Application Support on first call, and releases them like
//  GeoNamesDataset releases its city table: callers running a pass hold a
//  scoped token via retain()/release(), and with no token outstanding the
//  models unload after a short grace. Browsing carries zero standing model
//  cost.
//

import CoreGraphics
import CoreML
import Foundation

actor ClipEngine {
    static let shared = ClipEngine()

    private var imageEncoder: MLModel?
    private var textEncoder: MLModel?
    private var tokenizer: ClipTokenizer?
    private var retainCount = 0
    private var unloadTask: Task<Void, Never>?

    private static let unloadGraceSeconds: UInt64 = 30

    func retain() {
        retainCount += 1
        unloadTask?.cancel()
        unloadTask = nil
    }

    func release() {
        retainCount = max(0, retainCount - 1)
        guard retainCount == 0 else { return }
        unloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.unloadGraceSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    func unload() {
        imageEncoder = nil
        textEncoder = nil
        tokenizer = nil
    }

    private func ensureLoaded() -> Bool {
        if imageEncoder != nil, textEncoder != nil, tokenizer != nil { return true }
        guard let dir = ClipModel.directory() else { return false }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let image = try? MLModel(contentsOf: dir.appendingPathComponent("ImageEncoder.mlmodelc"),
                                       configuration: config),
              let text = try? MLModel(contentsOf: dir.appendingPathComponent("TextEncoder.mlmodelc"),
                                      configuration: config),
              let tok = ClipTokenizer(modelDir: dir)
        else { return false }
        imageEncoder = image
        textEncoder = text
        tokenizer = tok
        return true
    }

    /// Whether both encoders + the tokenizer are actually loadable from disk.
    func canLoad() -> Bool { ensureLoaded() }

    /// 512-d, L2-normalized. nil when the model isn't installed or encode fails.
    func embedImage(_ cgImage: CGImage) async -> [Float]? {
        guard ensureLoaded(), let model = imageEncoder else { return nil }
        // The preprocess is a pure resample of the full raster into a 224×224
        // buffer, measured at 6 ms per 4096×2731 image, once per photo across a
        // whole-library index. It runs on THIS ACTOR's executor, not the main
        // one, which is the point of `ClipEngine` being an `actor`.
        //
        // Round 15 recorded the opposite here — "this preprocess runs ON THE
        // MAIN ACTOR … the class is main-isolated" — and filed the redesign it
        // implied. That was a misreading of `SWIFT_DEFAULT_ACTOR_ISOLATION =
        // MainActor`: the setting isolates declarations that don't say
        // otherwise, and an `actor` says otherwise by being one. Verified by
        // building the shape under this project's own flag
        // (`-default-isolation MainActor`): a `@MainActor` method reported
        // `pthread_main_np() != 0`, an actor's isolated method did not. The
        // duration was measured correctly; the thread it was attributed to was
        // not. Nothing to move, and `CVPixelBuffer` never needed to be
        // `Sendable` here — it does not cross an isolation boundary.
        guard let buffer = ClipPreprocess.pixelBuffer(from: cgImage,
                                                      side: ClipModel.current.imageInputSide)
        else { return nil }
        guard let inputName = model.modelDescription.inputDescriptionsByName.keys.first,
              let input = try? MLDictionaryFeatureProvider(dictionary: [inputName: buffer]),
              let output = try? await model.prediction(from: input),
              let name = output.featureNames.first,
              let multiArray = output.featureValue(for: name)?.multiArrayValue
        else { return nil }
        return normalize(multiArrayToFloats(multiArray))
    }

    /// nil for empty/whitespace input (the SentenceEmbedder.embed contract).
    func embedText(_ text: String) async -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard ensureLoaded(), let model = textEncoder, let tokenizer else { return nil }
        let ids = tokenizer.encode(trimmed)
        guard let tokenArray = try? MLMultiArray(shape: [1, NSNumber(value: ids.count)],
                                                 dataType: .int32) else { return nil }
        for (i, id) in ids.enumerated() { tokenArray[i] = NSNumber(value: id) }
        guard let inputName = model.modelDescription.inputDescriptionsByName.keys.first,
              let input = try? MLDictionaryFeatureProvider(dictionary: [inputName: tokenArray]),
              let output = try? await model.prediction(from: input),
              let name = output.featureNames.first,
              let multiArray = output.featureValue(for: name)?.multiArrayValue
        else { return nil }
        return normalize(multiArrayToFloats(multiArray))
    }

    private func multiArrayToFloats(_ array: MLMultiArray) -> [Float] {
        (0..<array.count).map { Float(truncating: array[$0]) }
    }

    private func normalize(_ v: [Float]) -> [Float]? {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        return v.map { $0 / norm }
    }
}
