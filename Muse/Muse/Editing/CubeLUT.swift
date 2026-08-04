//
//  CubeLUT.swift
//  Muse
//
//  A pure `.cube` (Adobe/Resolve convention) parser, written against the
//  format spec.
//
//  Two refusals rather than best-effort guesses:
//  - `LUT_1D_SIZE` is not a 3D look and has no place in this pipeline.
//  - a non-default DOMAIN_MIN/MAX would need resampling, which silently
//    misrepresents the look. Refusing is honest; a wrong render is not.
//
//  Storage order is R fastest-varying — the spec's order, pinned by an
//  asymmetric test fixture because an axis mixup produces a plausible-looking
//  but completely wrong grade.
//

import Foundation
import CryptoKit

nonisolated struct CubeLUT: Equatable, Sendable {
    let size: Int
    /// size³ × 3 floats, R fastest-varying. Values may exceed 0…1 — some looks
    /// lift past the domain and `CIColorCube` tolerates it.
    let data: [Float]

    init(size: Int, data: [Float]) {
        self.size = size
        self.data = data
    }

    /// The bytes the content hash is taken over, and the bytes stored in the
    /// `edit_luts` blob. Float32 native-endian (Apple silicon + Intel are both
    /// little-endian; the blob never leaves the device — it isn't in sidecars).
    var canonicalData: Data {
        data.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func hash(_ lut: CubeLUT) -> String {
        SHA256.hash(data: lut.canonicalData).map { String(format: "%02x", $0) }.joined()
    }

    /// Does a STORED `(size, blob)` pair describe a cube that can actually be
    /// rendered?
    ///
    /// `CIColorCubeWithColorSpace` is handed `inputCubeDimension` and
    /// `inputCubeData` as an unchecked pair and reads `size³ × 4` floats out of
    /// the buffer — so a row whose declared size outruns its blob is an
    /// out-of-bounds read inside Core Image, not a bad-looking grade.
    /// `CubeLUTParser` guarantees the pair matches for anything it imports, but
    /// a `.muselibrary` archive is a file the user chose off disk and its
    /// `edit_luts` entries land in the table by a plain INSERT. This is the
    /// predicate that keeps the render path from trusting them.
    ///
    /// Deliberately expressed over BYTE COUNT rather than a `[Float]`, because
    /// both callers hold the blob, not the decoded array. Overflow-safe: the
    /// size ceiling is checked before the cube is ever taken.
    static func isRenderableStoredCube(size: Int, byteCount: Int) -> Bool {
        guard size >= 2, size <= CubeLUTParser.maxSize else { return false }
        let entries = size * size * size * 3
        return byteCount == entries * MemoryLayout<Float>.size
    }

    /// The second thing a stored blob has to be: FINITE.
    ///
    /// A right-sized cube can still hold a NaN, and Core Image propagates it
    /// into the rendered pixels rather than rejecting it — where the editor's
    /// statistics tap converts float pixels to bytes and TRAPS. Same provenance
    /// argument as the size check above: `CubeLUTParser` refuses one, a
    /// restored archive's plain INSERT does not.
    ///
    /// Separate from `isRenderableStoredCube` because it costs a pass over
    /// several MB, and the cheap structural check should get to say no first.
    static func storedCubeIsFinite(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            raw.bindMemory(to: Float.self).allSatisfy(\.isFinite)
        }
    }
}

nonisolated enum CubeLUTParser {
    /// A 128³ text cube is roughly 50 MB; past this it isn't a LUT.
    static let maxFileBytes = 64 * 1024 * 1024
    /// CIColorCube's documented ceiling.
    static let maxSize = 128
    private static let domainTolerance = 1e-4

    enum ParseError: Error, Equatable {
        case tooLarge
        case notA3DLUT
        case badSize
        case badValue(line: Int)
        case wrongCount(expected: Int, got: Int)
        case unsupportedDomain
    }

    static func parse(_ text: String) throws -> (lut: CubeLUT, title: String?) {
        guard text.utf8.count <= maxFileBytes else { throw ParseError.tooLarge }

        var title: String?
        var size: Int?
        var domainMin: (Double, Double, Double) = (0, 0, 0)
        var domainMax: (Double, Double, Double) = (1, 1, 1)
        var values: [Float] = []
        var dataRowCount = 0

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lineNumber = index + 1
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("TITLE") {
                title = line.dropFirst("TITLE".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                continue
            }
            if line.hasPrefix("LUT_1D_SIZE") { throw ParseError.notA3DLUT }
            if line.hasPrefix("LUT_3D_SIZE") {
                let rest = line.dropFirst("LUT_3D_SIZE".count).trimmingCharacters(in: .whitespaces)
                guard let n = Int(rest), n >= 2, n <= maxSize else { throw ParseError.badSize }
                size = n
                continue
            }
            if line.hasPrefix("DOMAIN_MIN") {
                let parts = numbers(after: "DOMAIN_MIN", in: line)
                guard parts.count == 3 else { throw ParseError.badValue(line: lineNumber) }
                domainMin = (parts[0], parts[1], parts[2])
                continue
            }
            if line.hasPrefix("DOMAIN_MAX") {
                let parts = numbers(after: "DOMAIN_MAX", in: line)
                guard parts.count == 3 else { throw ParseError.badValue(line: lineNumber) }
                domainMax = (parts[0], parts[1], parts[2])
                continue
            }
            if line.hasPrefix("LUT_1D_INPUT_RANGE") || line.hasPrefix("LUT_3D_INPUT_RANGE") {
                continue    // recognized, not load-bearing for this importer
            }

            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // `.isFinite` is load-bearing, not belt-and-braces. `Float("nan")`
            // and `Float("inf")` both PARSE, and so does any literal that
            // overflows — `Float("1e40")` is `+∞` with no failure to notice. A
            // cube carrying one of those is handed to
            // `CIColorCubeWithColorSpace`, and the NaN comes back out in the
            // rendered pixels, where the stats tap's float→UInt8 conversion
            // traps. Refusing the file is the only honest answer: there is no
            // sensible colour to substitute for "not a number".
            guard parts.count == 3,
                  let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]),
                  r.isFinite, g.isFinite, b.isFinite
            else { throw ParseError.badValue(line: lineNumber) }
            values.append(r); values.append(g); values.append(b)
            dataRowCount += 1
        }

        guard let resolvedSize = size else { throw ParseError.badSize }

        let domainIsDefault =
            abs(domainMin.0) < domainTolerance && abs(domainMin.1) < domainTolerance
            && abs(domainMin.2) < domainTolerance
            && abs(domainMax.0 - 1) < domainTolerance && abs(domainMax.1 - 1) < domainTolerance
            && abs(domainMax.2 - 1) < domainTolerance
        guard domainIsDefault else { throw ParseError.unsupportedDomain }

        let expected = resolvedSize * resolvedSize * resolvedSize
        guard dataRowCount == expected else {
            throw ParseError.wrongCount(expected: expected, got: dataRowCount)
        }
        return (CubeLUT(size: resolvedSize, data: values), title)
    }

    /// Non-finite entries are DROPPED rather than returned, which makes the
    /// caller's `count == 3` guard reject the line. The domain check would
    /// refuse a NaN anyway (every comparison against it is false, so it can't
    /// look default) — but by accident of three-valued arithmetic rather than
    /// by intent, and that is not a thing to leave load-bearing.
    private static func numbers(after keyword: String, in line: String) -> [Double] {
        line.dropFirst(keyword.count)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .compactMap { Double($0) }
            .filter(\.isFinite)
    }
}
