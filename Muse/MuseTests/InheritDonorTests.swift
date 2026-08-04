import XCTest
@testable import Muse

/// Which existing copy a NEW copy inherits from.
///
/// Owner decision (2026-08-03): duplicating a photo that already carries edits
/// should start from those edits and diverge, not from blank.
final class InheritDonorTests: XCTestCase {

    private func c(_ id: String, _ dir: String, edited: Int64?) -> InheritDonor.Candidate {
        InheritDonor.Candidate(fileID: id, parentDir: dir,
                               absolutePath: "\(dir)/\(id).jpg", editUpdatedAt: edited)
    }

    func testPrefersACopyInTheSameFolder() {
        let picked = InheritDonor.pick(
            candidates: [c("a", "/Other", edited: 999), c("b", "/Here", edited: 1)],
            targetDir: "/Here")
        XCTAssertEqual(picked, "b")
    }

    func testFallsBackToMostRecentlyEdited() {
        let picked = InheritDonor.pick(
            candidates: [c("a", "/X", edited: 5), c("b", "/Y", edited: 50)],
            targetDir: "/Here")
        XCTAssertEqual(picked, "b")
    }

    /// "I duplicated the one I was just working on" beats "something elsewhere
    /// was edited more recently".
    func testSameFolderBeatsAMoreRecentEditElsewhere() {
        let picked = InheritDonor.pick(
            candidates: [c("a", "/Here", edited: nil), c("b", "/Y", edited: 50)],
            targetDir: "/Here")
        XCTAssertEqual(picked, "a")
    }

    /// Among same-folder copies, the most recently edited still wins.
    func testMostRecentlyEditedWinsWithinTheSameFolder() {
        let picked = InheritDonor.pick(
            candidates: [c("a", "/Here", edited: 5), c("b", "/Here", edited: 50)],
            targetDir: "/Here")
        XCTAssertEqual(picked, "b")
    }

    /// The rule must be total, or the same duplicate inherits differently
    /// depending on the order SQLite happened to return rows in.
    func testTieBreaksOnLowestPathSoItIsDeterministic() {
        let forward = InheritDonor.pick(
            candidates: [c("zzz", "/Here", edited: nil), c("aaa", "/Here", edited: nil)],
            targetDir: "/Here")
        let reversed = InheritDonor.pick(
            candidates: [c("aaa", "/Here", edited: nil), c("zzz", "/Here", edited: nil)],
            targetDir: "/Here")
        XCTAssertEqual(forward, "aaa")
        XCTAssertEqual(reversed, "aaa")
    }

    /// An unedited copy must never beat an edited one on the nil.
    func testAnEditedCopyBeatsAnUneditedOne() {
        let picked = InheritDonor.pick(
            candidates: [c("aaa", "/Here", edited: nil), c("zzz", "/Here", edited: 1)],
            targetDir: "/Here")
        XCTAssertEqual(picked, "zzz")
    }

    func testNoCandidatesIsNil() {
        XCTAssertNil(InheritDonor.pick(candidates: [], targetDir: "/Here"))
    }
}
