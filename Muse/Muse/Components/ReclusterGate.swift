//
//  ReclusterGate.swift
//  Muse
//
//  Whether a finished analyze pass needs to rebuild collections.
//
//  Reclustering reads every embedding in the library and runs single-linkage
//  connected components over all pairs. That cost scales with LIBRARY size, not
//  with how much the pass just added — so a pass that embedded nothing (every
//  file already analyzed, every file a non-image, or the embedder unavailable)
//  used to pay the full rebuild for a result that provably cannot have changed.
//
//  `analyze(file:)` was the worst case: it reclustered the ENTIRE library after
//  every single file.
//

import Foundation

enum ReclusterGate {
    /// `force` is the manual/menu path, which must still rebuild on demand.
    static func shouldRecluster(embeddingsWritten: Int, force: Bool) -> Bool {
        force || embeddingsWritten > 0
    }
}
