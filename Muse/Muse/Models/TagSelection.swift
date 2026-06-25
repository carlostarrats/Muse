//
//  TagSelection.swift
//  Muse
//
//  Pure transition logic for the multi-tag chip filter. The grid filters by the
//  INTERSECTION (AND) of the selected tags; this type owns the ordered-set
//  mutations (toggle / remove / rename) so AppState stays a thin caller and the
//  rules are unit-tested. `nonisolated` because the module's default actor
//  isolation is MainActor (used from nonisolated tests).
//

nonisolated enum TagSelection {

    /// Cmd-click toggle: remove `label` if present, else append it at the end
    /// (insertion order drives the banner wording).
    static func toggling(_ labels: [String], _ label: String) -> [String] {
        if let idx = labels.firstIndex(of: label) {
            var out = labels
            out.remove(at: idx)
            return out
        }
        return labels + [label]
    }

    /// Per-pill removal from the active-filter bar: drop every occurrence of
    /// `label`, preserving the order of the survivors. Removing the sole label
    /// yields an empty selection (back to "All").
    static func removing(_ labels: [String], _ label: String) -> [String] {
        labels.filter { $0 != label }
    }

    /// Apply a label rename to the selection: replace every `old` with `new`,
    /// then de-duplicate (TagStore MERGES on a rename collision, so if `new` is
    /// already selected the result must not hold it twice). Order preserved.
    static func renaming(_ labels: [String], from old: String, to new: String) -> [String] {
        var seen = Set<String>()
        return labels.map { $0 == old ? new : $0 }.filter { seen.insert($0).inserted }
    }

}
