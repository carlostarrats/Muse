//
//  CullSummary.swift
//  Muse
//
//  The keep/reject partition of a cull session's marks. Sorted so the
//  resolve card's counts and the paths it applies to are stable between
//  reads of the same dictionary.
//

nonisolated struct CullSummary: Equatable {
    let keepPaths: [String]
    let rejectPaths: [String]

    init(marks: [String: CullStore.Mark]) {
        keepPaths = marks.compactMap { $0.value == .keep ? $0.key : nil }.sorted()
        rejectPaths = marks.compactMap { $0.value == .reject ? $0.key : nil }.sorted()
    }
}
