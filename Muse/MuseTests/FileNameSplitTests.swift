//
//  FileNameSplitTests.swift
//  MuseTests
//
//  Pure basename/extension split + recombine + shape validation for file rename.
//

import XCTest
@testable import Muse

final class FileNameSplitTests: XCTestCase {

    // MARK: - split

    func testSplitSimpleExtension() {
        let s = FileNameSplit.split("photo.jpg")
        XCTAssertEqual(s.stem, "photo")
        XCTAssertEqual(s.ext, ".jpg")
    }
    func testSplitMultiDotUsesLastSuffixOnly() {
        let s = FileNameSplit.split("archive.tar.gz")
        XCTAssertEqual(s.stem, "archive.tar")
        XCTAssertEqual(s.ext, ".gz")
    }
    func testSplitNoExtension() {
        let s = FileNameSplit.split("README")
        XCTAssertEqual(s.stem, "README")
        XCTAssertEqual(s.ext, "")
    }
    func testSplitLeadingDotDotfileHasNoExtension() {
        let s = FileNameSplit.split(".gitignore")
        XCTAssertEqual(s.stem, ".gitignore")
        XCTAssertEqual(s.ext, "")
    }
    func testSplitTrailingDotIsNotAnExtension() {
        let s = FileNameSplit.split("foo.")
        XCTAssertEqual(s.stem, "foo.")
        XCTAssertEqual(s.ext, "")
    }

    // MARK: - recombine

    func testRecombineReappendsExtension() {
        XCTAssertEqual(FileNameSplit.recombine(stem: "archive.tar", ext: ".gz"), "archive.tar.gz")
    }
    func testRecombineNoExtension() {
        XCTAssertEqual(FileNameSplit.recombine(stem: ".gitignore", ext: ""), ".gitignore")
    }
    func testRecombineDotInStemKeepsLockedExtension() {
        // Typing a dot in the stem is accepted; the real extension stays .jpg.
        XCTAssertEqual(FileNameSplit.recombine(stem: "photo.png", ext: ".jpg"), "photo.png.jpg")
    }

    // MARK: - validate

    func testValidateHappyPath() {
        XCTAssertEqual(
            FileNameSplit.validate(stem: "Invoice — March", ext: ".jpg", originalName: "IMG_1.jpg"),
            .success("Invoice — March.jpg"))
    }
    func testValidateTrimsWhitespace() {
        XCTAssertEqual(
            FileNameSplit.validate(stem: "  Photo  ", ext: ".jpg", originalName: "IMG_1.jpg"),
            .success("Photo.jpg"))
    }
    func testValidateEmptyStem() {
        XCTAssertEqual(
            FileNameSplit.validate(stem: "   ", ext: ".jpg", originalName: "IMG_1.jpg"),
            .failure(.empty))
    }
    func testValidateRejectsSlashAndColon() {
        XCTAssertEqual(
            FileNameSplit.validate(stem: "a/b", ext: ".jpg", originalName: "IMG_1.jpg"),
            .failure(.invalidCharacter))
        XCTAssertEqual(
            FileNameSplit.validate(stem: "a:b", ext: ".jpg", originalName: "IMG_1.jpg"),
            .failure(.invalidCharacter))
    }
    func testValidateRejectsHidingANonDotfile() {
        // A normal file must not be renamed into a hidden dotfile.
        XCTAssertEqual(
            FileNameSplit.validate(stem: ".secret", ext: "", originalName: "notes.txt"),
            .failure(.wouldHide))
    }
    func testValidateAllowsEditingAnExistingDotfile() {
        // .gitignore was already hidden — editing it (still leading-dot) is fine.
        XCTAssertEqual(
            FileNameSplit.validate(stem: ".gitignore-new", ext: "", originalName: ".gitignore"),
            .success(".gitignore-new"))
    }
}
