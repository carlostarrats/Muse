//
//  ClipTokenizer.swift
//  Muse
//
//  Pure Swift CLIP BPE tokenizer (49,408-token vocab, 77-token context,
//  <|startoftext|>/<|endoftext|>). No dependency added. Unit-tested against
//  script-generated fixture pairs (ClipTokenizerTests) — the Swift and the
//  reference implementation must not diverge, the same rule that keeps
//  PhotoHeaderReader mirroring FileMetadata.
//

import Foundation

nonisolated struct ClipTokenizer: Sendable {
    private let encoder: [String: Int32]
    private let merges: [String: Int]      // "left right" -> rank (lower = merge earlier)
    private let startToken: Int32
    private let endToken: Int32
    static let contextLength = 77

    init?(modelDir: URL) {
        let vocabURL = modelDir.appendingPathComponent("vocab.json")
        let mergesURL = modelDir.appendingPathComponent("merges.txt")
        guard let vocabData = try? Data(contentsOf: vocabURL),
              let vocab = try? JSONDecoder().decode([String: Int32].self, from: vocabData)
        else { return nil }
        let mergesText = (try? String(contentsOf: mergesURL, encoding: .utf8)) ?? ""

        encoder = vocab
        guard let start = vocab["<|startoftext|>"], let end = vocab["<|endoftext|>"] else { return nil }
        startToken = start
        endToken = end

        var rankTable: [String: Int] = [:]
        for (rank, line) in mergesText.split(separator: "\n").enumerated() {
            if line.hasPrefix("#") { continue }
            rankTable[String(line)] = rank
        }
        merges = rankTable
    }

    /// Always exactly `contextLength` ids: start, the BPE run, end, zero pad.
    func encode(_ text: String) -> [Int32] {
        let lowered = text.lowercased()
        var ids: [Int32] = [startToken]
        for word in lowered.split(separator: " ").map(String.init) where !word.isEmpty {
            ids.append(contentsOf: bpe(word + "</w>"))
            if ids.count >= Self.contextLength - 1 { break }
        }
        ids = Array(ids.prefix(Self.contextLength - 1))
        ids.append(endToken)
        while ids.count < Self.contextLength { ids.append(0) }
        return ids
    }

    private func bpe(_ word: String) -> [Int32] {
        // The "</w>" end-of-word marker is one symbol, not four characters.
        var symbols: [String]
        if word.hasSuffix("</w>") {
            symbols = word.dropLast(4).map { String($0) }
            symbols.append("</w>")
        } else {
            symbols = word.map { String($0) }
        }
        guard symbols.count > 1 else {
            return symbols.compactMap { encoder[$0] }
        }
        while symbols.count > 1 {
            var bestRank = Int.max
            var bestPairIndex: Int?
            for i in 0..<(symbols.count - 1) {
                let pairKey = "\(symbols[i]) \(symbols[i + 1])"
                if let rank = merges[pairKey], rank < bestRank {
                    bestRank = rank
                    bestPairIndex = i
                }
            }
            guard let mergeIndex = bestPairIndex else { break }
            let merged = symbols[mergeIndex] + symbols[mergeIndex + 1]
            symbols.replaceSubrange(mergeIndex...(mergeIndex + 1), with: [merged])
        }
        return symbols.compactMap { encoder[$0] }
    }
}
