//
//  ClipVectors.swift
//  Muse
//
//  fp16 storage for CLIP's 512-d joint embedding space (50k photos ~50MB,
//  800k ~800MB on disk). `fromData` REFUSES an odd-length blob — vectors
//  from different model generations must never pair, the same class of rule
//  as FeaturePrints.distance's length-mismatch refusal.
//
//  **This file must compile for x86_64.** Swift's `Float16` exists only on
//  arm64 — on Intel it is not a type at all. Using it unconditionally made the
//  whole app fail to build for x86_64, and that went unnoticed because a Debug
//  build compiles ONLY the active arch: the app still built and ran on Apple
//  Silicon while a Release (universal) build was impossible. It is also the
//  real reason `-exportLocalizations`, which builds universal, stopped working.
//
//  So: one WIRE FORMAT (IEEE-754 binary16, little-endian) and two encoders that
//  must agree bit-for-bit — the hardware type where it exists, a portable
//  bit-twiddle everywhere else. Both are ALWAYS compiled and `ClipVectorsTests`
//  holds them against each other across the whole exponent range, so they can
//  never drift: these bytes live in the database and travel in backups, so a
//  vector written on one machine has to read back identically on the other.
//

import Foundation

nonisolated enum ClipVectors {
    static func toData(_ v: [Float]) -> Data {
        var data = Data(capacity: v.count * 2)
        for value in v {
            var half = halfBits(value).littleEndian
            withUnsafeBytes(of: &half) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func fromData(_ d: Data) -> [Float]? {
        guard !d.isEmpty, d.count % 2 == 0 else { return nil }
        var out = [Float]()
        out.reserveCapacity(d.count / 2)
        d.withUnsafeBytes { raw in
            for i in stride(from: 0, to: raw.count, by: 2) {
                let bits = UInt16(raw[i]) | (UInt16(raw[i + 1]) << 8)
                out.append(float(fromHalfBits: bits))
            }
        }
        return out
    }

    // MARK: - binary32 ⇄ binary16

    /// Hardware conversion on Apple Silicon (one instruction), portable
    /// elsewhere. `ClipIndex.matches` converts every stored vector on every
    /// semantic search, so this is worth branching at COMPILE time.
    @inline(__always)
    static func halfBits(_ value: Float) -> UInt16 {
        #if arch(arm64)
        return Float16(value).bitPattern
        #else
        return portableHalfBits(value)
        #endif
    }

    @inline(__always)
    static func float(fromHalfBits bits: UInt16) -> Float {
        #if arch(arm64)
        return Float(Float16(bitPattern: bits))
        #else
        return portableFloat(fromHalfBits: bits)
        #endif
    }

    /// binary32 → binary16, round-to-nearest-even, handling subnormals,
    /// overflow and NaN. Always compiled; the tests pin it to the hardware
    /// conversion.
    static func portableHalfBits(_ value: Float) -> UInt16 {
        let x = value.bitPattern
        let sign = UInt16((x >> 16) & 0x8000)
        let rawExp = Int32((x >> 23) & 0xFF)
        let mantissa = x & 0x007F_FFFF

        if rawExp == 0xFF {                                   // Inf / NaN
            // A NaN must stay a NaN — keep a payload bit so it cannot
            // collapse into infinity.
            return mantissa != 0 ? (sign | 0x7E00) : (sign | 0x7C00)
        }
        let exp = rawExp - 127 + 15
        if exp >= 0x1F { return sign | 0x7C00 }               // overflow → ±Inf
        if exp <= 0 {
            if exp < -10 { return sign }                      // underflow → ±0
            // Subnormal: restore the implicit leading 1, then shift into place.
            let full = mantissa | 0x0080_0000
            let shift = UInt32(14 - exp)                      // 14…24
            var half = UInt16(truncatingIfNeeded: full >> shift)
            let roundBit = UInt32(1) << (shift - 1)
            if (full & roundBit) != 0,
               (full & (roundBit - 1)) != 0 || (half & 1) != 0 {
                half &+= 1                                    // ties-to-even
            }
            return sign | half
        }
        var half = UInt16(exp << 10) | UInt16(truncatingIfNeeded: mantissa >> 13)
        let roundBit: UInt32 = 0x0000_1000
        if (mantissa & roundBit) != 0,
           (mantissa & (roundBit - 1)) != 0 || (half & 1) != 0 {
            // A carry rolls into the exponent, and from 0x7BFF into 0x7C00
            // (Inf) — the correct rounding of a value just under fp16 max.
            half &+= 1
        }
        return sign | half
    }

    /// binary16 → binary32. Exact: every half is representable as a float.
    static func portableFloat(fromHalfBits bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exp = UInt32((bits >> 10) & 0x1F)
        let mantissa = UInt32(bits & 0x03FF)

        if exp == 0 {
            if mantissa == 0 { return Float(bitPattern: sign) }   // ±0
            // Subnormal: normalize by shifting until the implicit bit appears.
            var m = mantissa
            var shift: UInt32 = 0
            while (m & 0x0400) == 0 { m <<= 1; shift += 1 }
            m &= 0x03FF
            let e = UInt32(127 - 15 - shift + 1)
            return Float(bitPattern: sign | (e << 23) | (m << 13))
        }
        if exp == 0x1F {                                          // Inf / NaN
            return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13))
        }
        return Float(bitPattern: sign | ((exp + 112) << 23) | (mantissa << 13))
    }
}

nonisolated enum ClipCentroid {
    /// Mean then re-normalize. nil for an empty input or a degenerate sum.
    static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let dimension = vectors.first?.count, dimension > 0 else { return nil }
        var sum = [Float](repeating: 0, count: dimension)
        var counted = 0
        for v in vectors {
            guard v.count == dimension else { continue }
            for i in 0..<dimension { sum[i] += v[i] }
            counted += 1
        }
        guard counted > 0 else { return nil }
        var mean = sum.map { $0 / Float(counted) }
        let norm = sqrt(mean.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        for i in 0..<dimension { mean[i] /= norm }
        return mean
    }
}
