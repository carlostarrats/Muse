//
//  DeepBackfillPresenceTests.swift
//  MuseTests
//
//  `paths.is_alive = 1` is a CLAIM, not a fact. Existence reconcile only ever
//  visits the subtree of a CURRENT root, so a folder that was indexed and then
//  removed from the sidebar AND deleted from disk leaves its rows alive
//  forever — nothing is left that is allowed to look at them.
//
//  DeepAnalysisBackfill selected those rows on every launch, failed to decode a
//  file that isn't there, and deliberately did NOT stamp a marker (correct — a
//  file that is merely offline must not be recorded as scanned). So the same
//  rows came back next launch, and the next, and the pass could never converge.
//  Owner-reported as the app "analyzing every time you make a new build":
//  2,923 rows from four deleted Desktop test folders, re-attempted every launch.
//
//  Absent files are dropped from the SCAN LIST rather than stamped: nothing is
//  recorded, so a file that comes back is still scanned. And they must not
//  consume the per-launch budget, or a library with more ghosts than the cap
//  would silently never scan its real photos.
//

import XCTest
@testable import Muse

final class DeepBackfillPresenceTests: XCTestCase {

    private func ctx(_ pairs: [(String, String)]) -> [String: (url: URL, hash: String)] {
        var map: [String: (url: URL, hash: String)] = [:]
        for (id, path) in pairs {
            map[id] = (URL(fileURLWithPath: path), "h-" + id)
        }
        return map
    }

    func testAbsentFileIsDropped() {
        let ids = ["gone"]
        let list = DeepAnalysisBackfill.scanList(
            candidateIDs: ids,
            context: ctx([("gone", "/Users/x/Desktop/Deleted/a.png")]),
            limit: 10, exists: { _ in false })
        XCTAssertTrue(list.isEmpty,
                      "a file that is not on disk must not be re-attempted every launch")
    }

    func testPresentFileIsKeptInCandidateOrder() {
        let ids = ["b", "a"]
        let list = DeepAnalysisBackfill.scanList(
            candidateIDs: ids,
            context: ctx([("a", "/here/a.png"), ("b", "/here/b.png")]),
            limit: 10, exists: { _ in true })
        XCTAssertEqual(list, ["b", "a"])
    }

    func testOnlyTheAbsentOnesAreDropped() {
        let list = DeepAnalysisBackfill.scanList(
            candidateIDs: ["gone", "here"],
            context: ctx([("gone", "/gone/a.png"), ("here", "/here/b.png")]),
            limit: 10, exists: { $0.hasPrefix("/here/") })
        XCTAssertEqual(list, ["here"])
    }

    /// The bug this guards: the per-launch cap is applied by the SQL selection,
    /// so absent rows used to spend it. A library whose ghost count exceeds the
    /// cap would then never reach a single real photo — and nothing would say
    /// so, because the pass "completed".
    func testAbsentCandidatesDoNotSpendTheBudget() {
        let list = DeepAnalysisBackfill.scanList(
            candidateIDs: ["g1", "g2", "g3", "real1", "real2"],
            context: ctx([("g1", "/gone/1.png"), ("g2", "/gone/2.png"),
                          ("g3", "/gone/3.png"), ("real1", "/here/1.png"),
                          ("real2", "/here/2.png")]),
            limit: 2, exists: { $0.hasPrefix("/here/") })
        XCTAssertEqual(list, ["real1", "real2"],
                       "the budget is a SCAN budget, not a candidate budget")
    }

    func testBudgetIsRespected() {
        let ids = (0..<5).map { "f\($0)" }
        let list = DeepAnalysisBackfill.scanList(
            candidateIDs: ids,
            context: ctx(ids.map { ($0, "/here/\($0).png") }),
            limit: 2, exists: { _ in true })
        XCTAssertEqual(list, ["f0", "f1"])
    }

    func testCandidateWithoutContextIsDropped() {
        let list = DeepAnalysisBackfill.scanList(
            candidateIDs: ["orphan", "here"],
            context: ctx([("here", "/here/b.png")]),
            limit: 10, exists: { _ in true })
        XCTAssertEqual(list, ["here"], "no alive path resolved — nothing to open")
    }

    /// Dataless iCloud files still HAVE a filesystem entry, so plain
    /// `fileExists` keeps them — but the old-style evicted placeholder does
    /// not, and dropping those would stop them being scanned once they
    /// materialize. Same probe `PathReconciler.reconcileByExistence` uses.
    func testEvictedPlaceholderCountsAsPresent() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-presence-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("photo.png")
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent(".photo.png.icloud").path, contents: Data())

        let list = DeepAnalysisBackfill.scanList(
            candidateIDs: ["evicted"], context: ctx([("evicted", real.path)]), limit: 10)
        XCTAssertEqual(list, ["evicted"],
                       "an evicted iCloud file is offline, not deleted")
    }
}
