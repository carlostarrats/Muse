import XCTest
@testable import Muse

final class GridFilterTests: XCTestCase {

    // MARK: - leaf(kind:ext:) mapping

    func testImageExtensionsMapToNamedLeaves() {
        XCTAssertEqual(KindFacet.leaf(kind: .image, ext: "jpg"), .jpeg)
        XCTAssertEqual(KindFacet.leaf(kind: .image, ext: "jpeg"), .jpeg)
        XCTAssertEqual(KindFacet.leaf(kind: .image, ext: "png"), .png)
        XCTAssertEqual(KindFacet.leaf(kind: .image, ext: "heic"), .heic)
        XCTAssertEqual(KindFacet.leaf(kind: .image, ext: "heif"), .heic)
        XCTAssertEqual(KindFacet.leaf(kind: .image, ext: "tif"), .tiff)
        XCTAssertEqual(KindFacet.leaf(kind: .image, ext: "tiff"), .tiff)
        XCTAssertEqual(KindFacet.leaf(kind: .image, ext: "gif"), .gif)
        XCTAssertEqual(KindFacet.leaf(kind: .image, ext: "webp"), .webp)
    }

    func testImageExtensionMatchingIsCaseInsensitive() {
        XCTAssertEqual(KindFacet.leaf(kind: .image, ext: "JPG"), .jpeg)
        XCTAssertEqual(KindFacet.leaf(kind: .image, ext: "PNG"), .png)
        XCTAssertEqual(KindFacet.leaf(kind: .image, ext: "HEIC"), .heic)
    }

    func testUnnamedImageFormatsMapToImageOther() {
        // Image-kind files whose format isn't named fall into the catch-all.
        XCTAssertEqual(KindFacet.leaf(kind: .image, ext: "bmp"), .imageOther)
        XCTAssertEqual(KindFacet.leaf(kind: .image, ext: "ico"), .imageOther)
        XCTAssertEqual(KindFacet.leaf(kind: .image, ext: "avif"), .imageOther)
        // Extensionless image (classified via header sniff) → catch-all.
        XCTAssertEqual(KindFacet.leaf(kind: .image, ext: ""), .imageOther)
    }

    func testRawPsdSvgMapToOwnLeavesRegardlessOfExt() {
        XCTAssertEqual(KindFacet.leaf(kind: .raw, ext: "dng"), .raw)
        XCTAssertEqual(KindFacet.leaf(kind: .raw, ext: "cr3"), .raw)
        XCTAssertEqual(KindFacet.leaf(kind: .raw, ext: "nef"), .raw)
        XCTAssertEqual(KindFacet.leaf(kind: .psd, ext: "psd"), .psd)
        XCTAssertEqual(KindFacet.leaf(kind: .svg, ext: "svg"), .svg)
    }

    func testNonImageKindsMapToTheirLeaves() {
        XCTAssertEqual(KindFacet.leaf(kind: .video, ext: "mp4"), .video)
        XCTAssertEqual(KindFacet.leaf(kind: .pdf, ext: "pdf"), .pdf)
        XCTAssertEqual(KindFacet.leaf(kind: .audio, ext: "mp3"), .audio)
        XCTAssertEqual(KindFacet.leaf(kind: .folder, ext: ""), .folder)
        // document collapses text/markdown/code/office
        XCTAssertEqual(KindFacet.leaf(kind: .text, ext: "txt"), .document)
        XCTAssertEqual(KindFacet.leaf(kind: .markdown, ext: "md"), .document)
        XCTAssertEqual(KindFacet.leaf(kind: .code, ext: "swift"), .document)
        XCTAssertEqual(KindFacet.leaf(kind: .office, ext: "docx"), .document)
        // other collapses model3d/font/archive/unknown
        XCTAssertEqual(KindFacet.leaf(kind: .model3d, ext: "usdz"), .other)
        XCTAssertEqual(KindFacet.leaf(kind: .font, ext: "ttf"), .other)
        XCTAssertEqual(KindFacet.leaf(kind: .archive, ext: "zip"), .other)
        XCTAssertEqual(KindFacet.leaf(kind: .unknown, ext: "dat"), .other)
    }

    func testFacetGroupings() {
        XCTAssertEqual(KindFacet.imageLeaves,
                       [.jpeg, .png, .heic, .tiff, .gif, .webp, .raw, .psd, .svg, .imageOther])
        XCTAssertEqual(KindFacet.topLevelKinds,
                       [.video, .pdf, .document, .audio, .xmp, .folder, .other])
    }

    // MARK: - matches

    func testEmptyKindsMatchesEverything() {
        let f = GridFilter.none
        XCTAssertTrue(f.matches(kind: .image, ext: "jpg"))
        XCTAssertTrue(f.matches(kind: .image, ext: "bmp"))
        XCTAssertTrue(f.matches(kind: .folder, ext: ""))
        XCTAssertTrue(f.matches(kind: .video, ext: "mp4"))
    }

    func testNarrowToOneImageFormat() {
        let f = GridFilter(kinds: [.png])
        XCTAssertTrue(f.matches(kind: .image, ext: "png"))
        XCTAssertFalse(f.matches(kind: .image, ext: "jpg"))
        // A BMP (imageOther) is hidden when only PNG is selected...
        XCTAssertFalse(f.matches(kind: .image, ext: "bmp"))
        // ...and a non-image kind is hidden too.
        XCTAssertFalse(f.matches(kind: .video, ext: "mp4"))
    }

    func testImageOtherReachesUnnamedFormats() {
        let f = GridFilter(kinds: [.imageOther])
        XCTAssertTrue(f.matches(kind: .image, ext: "bmp"))
        XCTAssertTrue(f.matches(kind: .image, ext: "avif"))
        XCTAssertFalse(f.matches(kind: .image, ext: "png"))
    }

    func testFolderFacetGatesFolders() {
        XCTAssertTrue(GridFilter(kinds: [.folder]).matches(kind: .folder, ext: ""))
        XCTAssertFalse(GridFilter(kinds: [.jpeg]).matches(kind: .folder, ext: ""))
    }

    // MARK: - isActive

    func testIsActive() {
        XCTAssertFalse(GridFilter.none.isActive)
        XCTAssertEqual(GridFilter.none.kinds, [])
        XCTAssertTrue(GridFilter(kinds: [.jpeg]).isActive)
    }

    // MARK: - toggling a single leaf (empty == all sentinel)

    func testTogglingFromEmptyDeselectsOneLeaf() {
        // Empty (all) → toggling png expands to the full set minus png.
        let f = GridFilter.none.toggling(.png)
        XCTAssertFalse(f.kinds.contains(.png))
        XCTAssertTrue(f.kinds.contains(.jpeg))
        XCTAssertTrue(f.kinds.contains(.video))
        XCTAssertTrue(f.isActive)
    }

    func testTogglingBackToFullSetCollapsesToEmpty() {
        // Full-minus-png, then toggle png back on → collapses to the empty (all) sentinel.
        let f = GridFilter.none.toggling(.png).toggling(.png)
        XCTAssertEqual(f, .none)
    }

    func testTogglingLastRemainingLeafOffCollapsesToEmpty() {
        // From a single-leaf selection, toggling that leaf off would empty the
        // set, which collapses back to the "all" sentinel rather than "show nothing".
        let f = GridFilter(kinds: [.jpeg]).toggling(.jpeg)
        XCTAssertEqual(f, .none)
    }

    // MARK: - Images parent (tri-state) + toggle-all

    func testImageParentStateAll() {
        XCTAssertEqual(GridFilter.none.imageParentState, .on)
    }

    func testImageParentStateMixed() {
        let f = GridFilter.none.toggling(.png)   // all images except png
        XCTAssertEqual(f.imageParentState, .mixed)
    }

    func testImageParentStateOff() {
        // Only a non-image leaf selected → no image leaves present.
        XCTAssertEqual(GridFilter(kinds: [.video]).imageParentState, .off)
    }

    func testImageParentStateOnForExplicitFullImageSet() {
        // An explicit (non-sentinel) set holding every image leaf plus a
        // non-image leaf still reports .on (exercises the non-effective branch).
        let kinds = Set(KindFacet.imageLeaves).union([.video])
        XCTAssertEqual(GridFilter(kinds: kinds).imageParentState, .on)
    }

    func testTogglingImageGroupFromOffSelectsAllImageLeaves() {
        // From an images-off state (only a non-image leaf), toggling the parent
        // turns every image leaf on.
        let f = GridFilter(kinds: [.video]).togglingImageGroup()
        for leaf in KindFacet.imageLeaves { XCTAssertTrue(f.kinds.contains(leaf)) }
        XCTAssertEqual(f.imageParentState, .on)
    }

    func testTogglingImageGroupOffRemovesAllImageLeaves() {
        // From all-on, toggling the Images parent removes every image leaf,
        // leaving the non-image kinds.
        let f = GridFilter.none.togglingImageGroup()
        for leaf in KindFacet.imageLeaves { XCTAssertFalse(f.kinds.contains(leaf)) }
        XCTAssertTrue(f.kinds.contains(.video))
        XCTAssertTrue(f.kinds.contains(.folder))
        XCTAssertEqual(f.imageParentState, .off)
    }

    func testTogglingImageGroupOnFromMixedSelectsAllImageLeaves() {
        // A mixed state (some images) → toggling the parent turns all images on.
        let f = GridFilter.none.toggling(.png).togglingImageGroup()
        XCTAssertEqual(f.imageParentState, .on)
    }

    func testTogglingImageGroupRoundTripCollapsesToEmpty() {
        // Off then on again from the all-on default returns to the empty sentinel.
        let f = GridFilter.none.togglingImageGroup().togglingImageGroup()
        XCTAssertEqual(f, .none)
    }

    // MARK: - resolve / Codable round-trip

    func testResolveDefaultsToNone() {
        XCTAssertEqual(GridFilter.resolve(nil), .none)
        XCTAssertEqual(GridFilter.resolve("not json"), .none)
    }

    func testCodableRoundTripViaResolve() throws {
        let original = GridFilter(kinds: [.jpeg, .png, .pdf])
        let data = try JSONEncoder().encode(original)
        let json = String(data: data, encoding: .utf8)
        XCTAssertEqual(GridFilter.resolve(json), original)
    }

    func testResolveIgnoresLegacyImageDateSizeKeys() {
        // A filter saved before this change holds the old coarse "image" leaf
        // (and possibly date/size keys); it no longer decodes → falls back to none.
        let legacy = #"{"kinds":["image"],"date":"week","size":"mb1to10"}"#
        XCTAssertEqual(GridFilter.resolve(legacy), .none)
    }

    // MARK: - XMP sidecar leaf (feat/next-125)

    func testXMPExtensionMapsToXMPLeafRegardlessOfKind() {
        // .xmp sidecars have no dedicated AssetKind — they classify as text or
        // unknown depending on the system's UTType data — so the leaf routes by
        // EXTENSION, before the kind switch. Case-insensitive like the rest.
        XCTAssertEqual(KindFacet.leaf(kind: .text, ext: "xmp"), .xmp)
        XCTAssertEqual(KindFacet.leaf(kind: .unknown, ext: "xmp"), .xmp)
        XCTAssertEqual(KindFacet.leaf(kind: .code, ext: "XMP"), .xmp)
    }

    func testXMPLeafIsAToplevelRow() {
        XCTAssertTrue(KindFacet.topLevelKinds.contains(.xmp))
        XCTAssertFalse(KindFacet.imageLeaves.contains(.xmp))
    }

    func testUncheckingXMPHidesSidecarsOnly() {
        // All leaves except .xmp → sidecars filtered out, documents still shown.
        let filter = GridFilter.none.toggling(.xmp)
        XCTAssertFalse(filter.matches(kind: .text, ext: "xmp"))
        XCTAssertTrue(filter.matches(kind: .text, ext: "txt"))
        XCTAssertTrue(filter.matches(kind: .image, ext: "jpg"))
    }
}
