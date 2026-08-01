import XCTest
import CoreGraphics
import ImageIO
@testable import Muse

/// XMP is a text format, so the fixtures are authored inline rather than
/// bundled as binaries — the same choice the rest of this suite makes, and it
/// keeps the exact `crs:` shape being asserted visible in the test.
private func metadata(_ body: String) throws -> CGImageMetadata {
    let xmp = """
    <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
          xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
          xmlns:dc="http://purl.org/dc/elements/1.1/"
          xmlns:xmp="http://ns.adobe.com/xap/1.0/"
          xmlns:exif="http://ns.adobe.com/exif/1.0/">
    \(body)
        </rdf:Description>
      </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """
    let data = Data(xmp.utf8)
    return try XCTUnwrap(CGImageMetadataCreateFromXMPData(data as CFData))
}

final class LightroomXMPTests: XCTestCase {

    func testCropAndAngleAndOrientationExtracted() throws {
        let meta = try metadata("""
              <crs:HasCrop>True</crs:HasCrop>
              <crs:CropLeft>0.1</crs:CropLeft>
              <crs:CropTop>0.2</crs:CropTop>
              <crs:CropRight>0.9</crs:CropRight>
              <crs:CropBottom>0.8</crs:CropBottom>
              <crs:CropAngle>-2.5</crs:CropAngle>
              <tiff:Orientation>6</tiff:Orientation>
        """)
        let edits = LightroomXMP.read(meta)
        XCTAssertTrue(edits.hasCrop)
        XCTAssertEqual(edits.cropLeft, 0.1)
        XCTAssertEqual(edits.cropAngle, -2.5)
        XCTAssertEqual(edits.orientation, 6)
    }

    func testRAWTemperatureAndTintExtracted() throws {
        let edits = try LightroomXMP.read(metadata("""
              <crs:Temperature>5500</crs:Temperature>
              <crs:Tint>+10</crs:Tint>
        """))
        XCTAssertEqual(edits.temperatureKelvin, 5500)
        XCTAssertEqual(edits.tint, 10)
    }

    func testEncodedIncrementalWBExtracted() throws {
        let edits = try LightroomXMP.read(metadata("""
              <crs:IncrementalTemperature>+40</crs:IncrementalTemperature>
              <crs:IncrementalTint>-20</crs:IncrementalTint>
        """))
        XCTAssertEqual(edits.incrementalTemperature, 40)
        XCTAssertEqual(edits.incrementalTint, -20)
    }

    func testFourToneColorSlidersExtracted() throws {
        let edits = try LightroomXMP.read(metadata("""
              <crs:Exposure2012>+0.85</crs:Exposure2012>
              <crs:Contrast2012>+25</crs:Contrast2012>
              <crs:Vibrance>-10</crs:Vibrance>
              <crs:Saturation>+5</crs:Saturation>
        """))
        XCTAssertEqual(edits.exposure2012, 0.85)
        XCTAssertEqual(edits.contrast2012, 25)
        XCTAssertEqual(edits.vibrance, -10)
        XCTAssertEqual(edits.saturation, 5)
    }

    func testToneCurveExtracted() throws {
        let edits = try LightroomXMP.read(metadata("""
              <crs:ToneCurvePV2012>
                <rdf:Seq>
                  <rdf:li>0, 0</rdf:li>
                  <rdf:li>128, 150</rdf:li>
                  <rdf:li>255, 255</rdf:li>
                </rdf:Seq>
              </crs:ToneCurvePV2012>
              <crs:Exposure2012>0.5</crs:Exposure2012>
        """))
        XCTAssertEqual(edits.toneCurvePV2012.count, 3)
        XCTAssertEqual(edits.toneCurvePV2012[1].y, 150)
    }

    /// The unsupported list is DETECTION only. Nothing here may ever start
    /// feeding a mapped value.
    func testUnsupportedSlidersAreEnumeratedNotTranslated() throws {
        let edits = try LightroomXMP.read(metadata("""
              <crs:Clarity2012>+30</crs:Clarity2012>
              <crs:Dehaze>+20</crs:Dehaze>
              <crs:Shadows2012>+15</crs:Shadows2012>
        """))
        XCTAssertTrue(edits.unsupported.contains("Clarity"))
        XCTAssertTrue(edits.unsupported.contains("Dehaze"))
        XCTAssertTrue(edits.unsupported.contains("Shadows"))
        XCTAssertNil(edits.exposure2012)
    }

    func testZeroValuedUnsupportedSliderIsNotReported() throws {
        let edits = try LightroomXMP.read(metadata("      <crs:Clarity2012>0</crs:Clarity2012>"))
        XCTAssertFalse(edits.unsupported.contains("Clarity"))
    }

    func testLegacyProcessVersionWithNo2012KeysIsFlagged() throws {
        let edits = try LightroomXMP.read(metadata("""
              <crs:ProcessVersion>5.7</crs:ProcessVersion>
              <crs:Exposure>+0.5</crs:Exposure>
        """))
        XCTAssertTrue(edits.unsupported.contains(LightroomXMP.legacyProcessVersionNote))
        XCTAssertNil(edits.exposure2012)
    }

    func testEmptyMetadataIsEmpty() throws {
        XCTAssertTrue(try LightroomXMP.read(metadata("      <dc:format>image/jpeg</dc:format>")).isEmpty)
    }

    func testPresetNameIsRead() throws {
        let edits = try LightroomXMP.read(metadata("""
              <crs:Name>
                <rdf:Alt><rdf:li xml:lang="x-default">My Look</rdf:li></rdf:Alt>
              </crs:Name>
              <crs:Exposure2012>0.5</crs:Exposure2012>
        """))
        XCTAssertEqual(edits.presetName, "My Look")
    }
}

final class LightroomEditMapperTests: XCTestCase {

    private let encoded = LightroomEditMapper.Context(isRAW: false)

    func testExposureMapsDirectlyAndClamps() {
        var lr = LightroomEdits(); lr.exposure2012 = 0.85
        XCTAssertEqual(LightroomEditMapper.map(lr, context: encoded)?.toneParams?.exposureEV ?? 0,
                       0.85, accuracy: 1e-9)
        lr.exposure2012 = 12
        XCTAssertEqual(LightroomEditMapper.map(lr, context: encoded)?.toneParams?.exposureEV, 5)
    }

    func testContrastVibranceSaturationDivideByScale() {
        var lr = LightroomEdits()
        lr.contrast2012 = 50; lr.vibrance = -25; lr.saturation = 10
        let stack = LightroomEditMapper.map(lr, context: encoded)
        XCTAssertEqual(stack?.toneParams?.contrast ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(stack?.colorParams?.vibrance ?? 0, -0.25, accuracy: 1e-9)
        XCTAssertEqual(stack?.colorParams?.saturation ?? 0, 0.1, accuracy: 1e-9)
    }

    func testEncodedWBUsesIncrementalDivideByScale() {
        var lr = LightroomEdits()
        lr.incrementalTemperature = 40; lr.incrementalTint = -20
        let stack = LightroomEditMapper.map(lr, context: encoded)
        XCTAssertEqual(stack?.colorParams?.temperature ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(stack?.colorParams?.tint ?? 0, -0.2, accuracy: 1e-9)
    }

    /// Without an as-shot reference there is nothing for a RAW Kelvin to be
    /// relative to, so WB is skipped rather than guessed.
    func testRAWWBRequiresAsShotContext() {
        var lr = LightroomEdits(); lr.temperatureKelvin = 5500; lr.tint = 10
        let none = LightroomEditMapper.map(lr, context: .init(isRAW: true))
        XCTAssertNil(none)
        let withContext = LightroomEditMapper.map(
            lr, context: .init(isRAW: true, asShotKelvin: 5200, asShotTint: 0))
        XCTAssertNotEqual(withContext?.colorParams?.temperature, 0)
    }

    /// The importer and the renderer share ONE mired constant, so an imported
    /// number means what the slider means.
    func testRAWWBUsesTheRenderersOwnMiredConstant() {
        var lr = LightroomEdits(); lr.temperatureKelvin = 5000
        let stack = LightroomEditMapper.map(
            lr, context: .init(isRAW: true, asShotKelvin: 5500, asShotTint: 0))
        let expected = ((1_000_000.0 / 5000) - (1_000_000.0 / 5500))
            / MiredMapping.maxMiredOffset
        XCTAssertEqual(stack?.colorParams?.temperature ?? 0, expected, accuracy: 1e-9)
    }

    func testIdentityCurveIsDropped() {
        var lr = LightroomEdits()
        lr.toneCurvePV2012 = [CGPoint(x: 0, y: 0), CGPoint(x: 255, y: 255)]
        XCTAssertNil(LightroomEditMapper.map(lr, context: encoded))
    }

    func testOversizedCurveKeepsEndpointsAndSubsamples() {
        var lr = LightroomEdits()
        lr.toneCurvePV2012 = (0...30).map { CGPoint(x: Double($0) * 8,
                                                    y: min(Double($0) * 8 + 10, 255)) }
        let points = LightroomEditMapper.map(lr, context: encoded)?.curveParams?.rgb ?? []
        XCTAssertLessThanOrEqual(points.count, CurveParams.maxPoints)
        XCTAssertEqual(points.first?.x ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(points.last?.x ?? -1, 240.0 / 255.0, accuracy: 1e-6)
    }

    func testOrientationTableCoversAllEightValues() {
        for orientation in 1...8 {
            XCTAssertNotNil(LightroomEditMapper.orientationTable[orientation],
                            "orientation \(orientation) missing")
        }
        XCTAssertEqual(LightroomEditMapper.orientationTable[6]?.quarterTurns, 1)
        XCTAssertEqual(LightroomEditMapper.orientationTable[8]?.quarterTurns, 3)
        XCTAssertEqual(LightroomEditMapper.orientationTable[2]?.flipH, true)
    }

    func testStraightenIsTheOppositeOfCropAngle() {
        var lr = LightroomEdits(); lr.cropAngle = 2.5
        XCTAssertEqual(
            LightroomEditMapper.map(lr, context: encoded)?.geometryParams?.straightenDegrees,
            -2.5)
    }

    func testEmptyEditsMapToNil() {
        XCTAssertNil(LightroomEditMapper.map(LightroomEdits(), context: encoded))
    }

    func testOutputOriginIsLightroom() {
        var lr = LightroomEdits(); lr.exposure2012 = 0.5
        XCTAssertEqual(LightroomEditMapper.map(lr, context: encoded)?.origin, .lightroom)
    }

    /// Pinning a decoder version is the first USER edit's job, not an import's.
    func testOutputNeverPinsRawParams() {
        var lr = LightroomEdits(); lr.exposure2012 = 0.5
        let stack = LightroomEditMapper.map(
            lr, context: .init(isRAW: true, asShotKelvin: 5000, asShotTint: 0))
        XCTAssertNil(stack?.rawParams)
    }
}

/// `EditStack.origin` is provenance, not data.
final class EditStackOriginTests: XCTestCase {

    private func sampleStack() -> EditStack {
        var stack = EditStack.fresh()
        stack.setTone { $0.exposureEV = 0.5 }
        return stack.normalized()
    }

    /// The hash-stability rule: a nil origin is omitted by synthesized
    /// `Codable`, so every pre-existing stack's canonical bytes — and its
    /// `stack_hash` — are byte-identical after adding the field.
    func testNilOriginIsOmittedFromCanonicalJSON() throws {
        let json = try EditStackCodec.encode(sampleStack())
        XCTAssertFalse(json.contains("origin"))
    }

    func testSettingOriginChangesTheHashDeterministically() {
        var withOrigin = sampleStack()
        withOrigin.origin = .lightroom
        let a = EditStackCodec.hash(withOrigin)
        let b = EditStackCodec.hash(withOrigin)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, EditStackCodec.hash(sampleStack()))
    }

    func testOriginRoundTripsThroughTheCodec() throws {
        var stack = sampleStack()
        stack.origin = .lightroom
        let decoded = EditStackCodec.decode(try EditStackCodec.encode(stack))
        XCTAssertEqual(decoded?.origin, .lightroom)
    }

    /// Pasting a Lightroom-imported look onto your own photo doesn't make your
    /// photo's edits Lightroom's.
    func testOriginNeverTransfersViaApply() {
        var source = sampleStack(); source.origin = .lightroom
        let target = EditStack.fresh()
        let result = EditTransfer.apply(groups: EditTransfer.adjustedGroups(of: source),
                                        from: source, onto: target)
        XCTAssertNil(result.origin)
        XCTAssertEqual(result.toneParams?.exposureEV, 0.5)
    }

    func testPresetSaveStripsOrigin() throws {
        var stack = sampleStack(); stack.origin = .lightroom
        let json = EditPresetStore.presetJSON(from: stack)
        XCTAssertNil(EditStackCodec.decode(json)?.origin)
    }
}
