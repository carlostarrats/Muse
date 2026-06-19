//
//  DuplicateDeleteRules.swift
//  Muse
//
//  Pure rules for the Duplicates review modal's delete selection. They enforce
//  the one invariant that matters for a destructive action: no duplicate group
//  is ever fully marked for delete — at least one copy of every group is kept.
//
//  A single file can belong to more than one group (DuplicateFinder runs the
//  byte-exact, filename, and visual clusterers over the same files and appends
//  all three). The delete set is global (a file is trashed or it isn't), so the
//  rules take EVERY group a file belongs to and keep all of them non-empty — a
//  copy kept by one group is never deleted out from under another.
//
//  DuplicatesView is a thin renderer over these; keeping the rules pure makes the
//  "never delete every copy" guarantee unit-testable (UI views aren't).
//

import Foundation

enum DuplicateDeleteRules {

    /// Non-keeper copies of ONE group to pre-mark for delete the first time it
    /// appears — only when the finder is confident about a keeper (byte-exact, or
    /// visual with a clear resolution gap). Filename-only / low-confidence visual
    /// groups carry no keeper and seed nothing, so they open fully kept.
    /// Cross-group conflicts (a keeper here that's a non-keeper there) are
    /// reconciled separately by `rescued`.
    static func seed(members: [(url: URL, isSuggestedKeeper: Bool)]) -> [URL] {
        guard members.contains(where: { $0.isSuggestedKeeper }) else { return [] }
        return members.filter { !$0.isSuggestedKeeper }.map(\.url)
    }

    /// Un-mark one survivor for any group that ended up fully selected, so no
    /// group is ever entirely marked for delete. This only fires when overlapping
    /// groups disagree (a file kept by one was pre-marked by another); in the
    /// common non-overlapping case it's a no-op.
    static func rescued(_ selected: Set<URL>, groups: [[URL]]) -> Set<URL> {
        var result = selected
        for members in groups where !members.isEmpty && members.allSatisfy({ result.contains($0) }) {
            if let keep = members.first { result.remove(keep) }
        }
        return result
    }

    /// Whether `url` can't be marked for delete here: doing so would empty some
    /// group it belongs to, and no simple swap rescues it. A file in a single
    /// two-copy group swaps instead, so it's never locked.
    static func isLocked(_ url: URL, groupsContaining: [[URL]], selected: Set<URL>) -> Bool {
        guard !selected.contains(url) else { return false }
        guard wouldEmptyAGroup(url, groupsContaining: groupsContaining, selected: selected)
        else { return false }
        return !canSwap(groupsContaining)
    }

    /// The delete set after attempting to mark `url` for delete:
    /// - keeps every group it's in non-empty → select it;
    /// - it's the last survivor of a single two-copy group → swap (free the
    ///   partner; freeing only ever adds survivors, so that's always safe);
    /// - otherwise (would empty a group, no swap) → unchanged (locked).
    ///
    /// Deselecting is always allowed and handled by the caller; this only adds.
    static func selecting(_ url: URL, groupsContaining: [[URL]], selected: Set<URL>) -> Set<URL> {
        if !wouldEmptyAGroup(url, groupsContaining: groupsContaining, selected: selected) {
            var result = selected
            result.insert(url)
            return result
        }
        if canSwap(groupsContaining) {
            var result = selected
            for member in groupsContaining[0] where member != url { result.remove(member) }
            result.insert(url)
            return result
        }
        return selected
    }

    /// Marking `url` for delete would leave some group it's in with no survivor.
    private static func wouldEmptyAGroup(_ url: URL, groupsContaining: [[URL]], selected: Set<URL>) -> Bool {
        groupsContaining.contains { members in
            members.allSatisfy { $0 == url || selected.contains($0) }
        }
    }

    /// The unambiguous swap case: the file belongs to exactly one group and that
    /// group has exactly two copies, so freeing "the other" has a single target.
    private static func canSwap(_ groupsContaining: [[URL]]) -> Bool {
        groupsContaining.count == 1 && groupsContaining[0].count == 2
    }
}
