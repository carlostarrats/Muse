import Foundation

enum CollectionIdentity {
    struct Matched {
        var id: String
        var members: Set<String>
        var isNew: Bool
    }

    /// Match new clusters to old collections by Jaccard overlap (>0.4 keeps
    /// the old id; each old id used at most once, best overlap first).
    static func match(old: [String: Set<String>], new: [Set<String>]) -> [Matched] {
        var available = old
        var pairs: [(score: Double, oldID: String, newIdx: Int)] = []
        for (oldID, oldMembers) in old {
            for (i, n) in new.enumerated() {
                let inter = Double(oldMembers.intersection(n).count)
                let uni = Double(oldMembers.union(n).count)
                if uni > 0 { pairs.append((inter / uni, oldID, i)) }
            }
        }
        pairs.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.oldID != $1.oldID { return $0.oldID < $1.oldID }
            return $0.newIdx < $1.newIdx
        }
        var assigned: [Int: String] = [:]
        for p in pairs where p.score > 0.4 {
            guard available[p.oldID] != nil, assigned[p.newIdx] == nil else { continue }
            assigned[p.newIdx] = p.oldID
            available[p.oldID] = nil
        }
        return new.enumerated().map { i, members in
            if let id = assigned[i] { return Matched(id: id, members: members, isNew: false) }
            return Matched(id: UUID().uuidString, members: members, isNew: true)
        }
    }
}
