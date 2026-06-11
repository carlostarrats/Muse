//
//  SeededRandom.swift
//  Muse
//
//  Deterministic RNG (SplitMix64) + stable string hashing (FNV-1a 64)
//  so spatial layouts are identical across launches for the same files.
//

import Foundation

struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// FNV-1a 64 over the UTF-8 of each string in order, with a 0xFF
    /// separator byte between strings (order-sensitive, launch-stable).
    static func fnv1a(_ strings: [String]) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for (i, s) in strings.enumerated() {
            if i > 0 { hash = (hash ^ 0xFF) &* prime }
            for byte in s.utf8 {
                hash = (hash ^ UInt64(byte)) &* prime
            }
        }
        return hash
    }
}
