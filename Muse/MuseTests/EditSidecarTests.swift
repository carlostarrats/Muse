import XCTest
@testable import Muse

final class EditSidecarTests: XCTestCase {
    func empty(updatedAt: Int64 = 0) -> Sidecar {
        Sidecar(schema: Sidecar.currentSchema, updated_at: updatedAt,
                content_hash: "h", kind: "image", tags: [])
    }

    func testPreEditSidecarDecodesWithNilEditFields() throws {
        // The exact shape a pre-Spec-04 build wrote — it must still decode.
        let json = """
        {"schema":1,"updated_at":5,"content_hash":"h","kind":"image","tags":[]}
        """
        let sidecar = try JSONDecoder().decode(Sidecar.self, from: Data(json.utf8))
        XCTAssertNil(sidecar.edit_stack)
        XCTAssertNil(sidecar.edit_updated_at)
    }

    // MARK: - merge

    func testMergeNewerEditUpdatedAtWins() {
        var a = empty(); a.edit_stack = "{\"a\":1}"; a.edit_updated_at = 100
        var b = empty(); b.edit_stack = "{\"b\":1}"; b.edit_updated_at = 500
        XCTAssertEqual(Sidecar.merge(a, b).edit_stack, "{\"b\":1}")
        XCTAssertEqual(Sidecar.merge(b, a).edit_stack, "{\"b\":1}")
    }

    func testMergeNilIncomingNeverClobbers() {
        var a = empty(); a.edit_stack = "{\"a\":1}"; a.edit_updated_at = 100
        let b = empty()
        XCTAssertEqual(Sidecar.merge(a, b).edit_stack, "{\"a\":1}")
        XCTAssertEqual(Sidecar.merge(b, a).edit_stack, "{\"a\":1}")
    }

    /// The edit field has its OWN clock: a newer analyze-export from a device
    /// that never saw the edit must not roll it back.
    func testMergeUsesEditClockNotTheSidecarClock() {
        var edited = empty(updatedAt: 10)
        edited.edit_stack = "{\"e\":1}"; edited.edit_updated_at = 900
        let laterButUnedited = empty(updatedAt: 1000)
        XCTAssertEqual(Sidecar.merge(edited, laterButUnedited).edit_stack, "{\"e\":1}")
    }

    func testMergeCarriesClockAndStackTogether() {
        var a = empty(); a.edit_stack = "{\"a\":1}"; a.edit_updated_at = 100
        var b = empty(); b.edit_stack = "{\"b\":1}"; b.edit_updated_at = 500
        let merged = Sidecar.merge(a, b)
        XCTAssertEqual(merged.edit_updated_at, 500)
        XCTAssertEqual(merged.edit_stack, "{\"b\":1}")
    }

    // MARK: - resolveForWrite

    func testResolveForWritePreservesOnDiskEditWhenNotAuthoritative() {
        var existing = empty(); existing.edit_stack = "{\"disk\":1}"; existing.edit_updated_at = 3
        var fresh = empty(); fresh.edit_stack = "{\"fresh\":1}"; fresh.edit_updated_at = 9
        let resolved = Sidecar.resolveForWrite(fresh: fresh, existing: existing,
                                               mergeExisting: false, noteAuthoritative: false,
                                               editAuthoritative: false)
        XCTAssertEqual(resolved.edit_stack, "{\"disk\":1}")
        XCTAssertEqual(resolved.edit_updated_at, 3)
    }

    func testResolveForWriteFreshWinsIncludingAClearWhenEditAuthoritative() {
        var existing = empty(); existing.edit_stack = "{\"disk\":1}"; existing.edit_updated_at = 3
        var fresh = empty(); fresh.edit_stack = nil; fresh.edit_updated_at = nil
        let resolved = Sidecar.resolveForWrite(fresh: fresh, existing: existing,
                                               mergeExisting: false, noteAuthoritative: false,
                                               editAuthoritative: true)
        // A Reset must propagate, not read as "nothing to say".
        XCTAssertNil(resolved.edit_stack)
        XCTAssertNil(resolved.edit_updated_at)
    }

    func testResolveForWriteDefaultsToNonAuthoritative() {
        var existing = empty(); existing.edit_stack = "{\"disk\":1}"
        var fresh = empty(); fresh.edit_stack = nil
        let resolved = Sidecar.resolveForWrite(fresh: fresh, existing: existing,
                                               mergeExisting: false, noteAuthoritative: false)
        XCTAssertEqual(resolved.edit_stack, "{\"disk\":1}")
    }

    func testTagEditExportDoesNotWipeAnUnhydratedEdit() {
        // The concrete regression: a rating change on device B re-exports the
        // sidecar. B has never hydrated A's edit, so `fresh` carries none.
        var existing = empty(); existing.edit_stack = "{\"A\":1}"; existing.edit_updated_at = 50
        let fresh = empty(updatedAt: 99)
        let resolved = Sidecar.resolveForWrite(fresh: fresh, existing: existing,
                                               mergeExisting: false, noteAuthoritative: true)
        XCTAssertEqual(resolved.edit_stack, "{\"A\":1}")
    }

    // MARK: - build

    func testBuildCarriesEditWhenSupplied() {
        let file = FileRow(id: "f", content_hash: "h", kind: "image", last_seen_at: 0)
        let sidecar = Sidecar.build(from: file, tags: [], updatedAt: 1,
                                    edit: (stack: "{\"s\":1}", updatedAt: 42))
        XCTAssertEqual(sidecar?.edit_stack, "{\"s\":1}")
        XCTAssertEqual(sidecar?.edit_updated_at, 42)
    }

    func testBuildLeavesEditNilWhenAbsent() {
        let file = FileRow(id: "f", content_hash: "h", kind: "image", last_seen_at: 0)
        let sidecar = Sidecar.build(from: file, tags: [], updatedAt: 1)
        XCTAssertNil(sidecar?.edit_stack)
        XCTAssertNil(sidecar?.edit_updated_at)
    }
}
