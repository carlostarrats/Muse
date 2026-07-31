//
//  ClipPromptVectors.swift
//  Muse
//
//  On model install/upgrade, re-encode every stored `.similar` PROMPT whose
//  `promptGeneration` is stale. Anchors need nothing here — their vectors
//  live in `clip_embeddings` and DeepAnalysisBackfill re-embeds those.
//

import Foundation
import GRDB

nonisolated enum ClipPromptVectors {
    static func refreshAll() async {
        guard let queue = Database.shared.dbQueue else { return }
        let rows = (try? await queue.read { db in
            try CollectionRow.filter(sql: "smart_rules IS NOT NULL").fetchAll(db)
        }) ?? []

        for row in rows {
            guard let json = row.smart_rules,
                  var ruleSet = SmartRuleSet.decode(json) else { continue }
            var changed = false
            for i in ruleSet.rules.indices {
                guard case let .similar(term) = ruleSet.rules[i],
                      let prompt = term.prompt,
                      !prompt.trimmingCharacters(in: .whitespaces).isEmpty,
                      term.promptGeneration != ClipModel.current.generation
                else { continue }
                guard let vector = await ClipEngine.shared.embedText(prompt) else { continue }
                var updated = term
                updated.promptVector = vector
                updated.promptGeneration = ClipModel.current.generation
                ruleSet.rules[i] = .similar(updated)
                changed = true
            }
            guard changed, let encoded = ruleSet.encodedJSON() else { continue }
            try? await queue.write { db in
                try db.execute(sql: "UPDATE collections SET smart_rules = ? WHERE id = ?",
                               arguments: [encoded, row.id])
            }
        }
        await CollectionsEngine.shared.reload()
    }
}
