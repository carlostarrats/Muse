import XCTest

/// The platform-neutral-core rule, enforced rather than merely intended:
/// `Editing/` must stay Foundation / CoreGraphics / CoreImage / Metal only, so
/// the render pipeline and edit model can move to iOS unchanged. A grep test
/// rather than a compiler feature because the app is a single target.
///
/// Caveat worth knowing before you "fix" a skip: the test HOST is the
/// sandboxed app, so it can only read the source tree when the checkout sits
/// somewhere the sandbox grants (`~/Documents`, `~/Desktop` and `~/Downloads`
/// are all denied without user selection). When the read is refused the test
/// SKIPS rather than passing vacuously — it still runs for real on any
/// checkout outside those folders, and a green run there is the actual gate.
final class EditingModuleImportTests: XCTestCase {
    /// Neither may appear in `Editing/`. SwiftUI rides along because it pulls
    /// AppKit in transitively on macOS — a SwiftUI import in the core is the
    /// same violation wearing a different name.
    static let bannedImports = ["AppKit", "SwiftUI"]

    func testEditingFolderNeverImportsAppKit() throws {
        let fm = FileManager.default
        // Walk up from this file until a directory containing Editing/ turns
        // up, rather than hard-coding a hop count — the test must keep working
        // if the test file or the source tree is ever moved.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var editingDir: URL?
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Muse/Editing")
            if fm.fileExists(atPath: candidate.path) { editingDir = candidate; break }
            dir = dir.deletingLastPathComponent()
        }
        guard let editingDir else {
            throw XCTSkip("Editing/ not locatable from \(#filePath)")
        }
        guard let names = try? fm.contentsOfDirectoryRecursively(at: editingDir),
              !names.isEmpty else {
            throw XCTSkip("""
                Sandbox denied reading \(editingDir.path). Move the checkout out \
                of ~/Documents (or ~/Desktop, ~/Downloads) to run this check.
                """)
        }

        var violations: [String] = []
        for fileURL in names where fileURL.pathExtension == "swift" {
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            for banned in Self.bannedImports
            where contents.range(of: "^\\s*import\\s+\(banned)",
                                 options: .regularExpression) != nil {
                violations.append("\(fileURL.lastPathComponent): \(banned)")
            }
        }
        XCTAssertTrue(violations.isEmpty,
                      "platform-specific imports in Editing/: \(violations)")
    }
}

private extension FileManager {
    func contentsOfDirectoryRecursively(at url: URL) throws -> [URL] {
        var out: [URL] = []
        for entry in try contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                out += (try? contentsOfDirectoryRecursively(at: entry)) ?? []
            } else {
                out.append(entry)
            }
        }
        return out
    }
}
