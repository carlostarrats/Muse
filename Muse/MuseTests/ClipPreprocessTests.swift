//
//  ClipPreprocessTests.swift
//  MuseTests
//

import XCTest
import CoreGraphics
import CoreVideo
@testable import Muse

final class ClipPreprocessTests: XCTestCase {
    func testLandscapeCropsToCenterSquare() {
        let rect = ClipPreprocess.cropRect(imageSize: CGSize(width: 400, height: 200), side: 256)
        XCTAssertEqual(rect.height, 200, accuracy: 0.01)
        XCTAssertEqual(rect.width, 200, accuracy: 0.01)
        XCTAssertEqual(rect.origin.x, 100, accuracy: 0.01)
        XCTAssertEqual(rect.origin.y, 0, accuracy: 0.01)
    }

    func testPortraitCropsToCenterSquare() {
        let rect = ClipPreprocess.cropRect(imageSize: CGSize(width: 200, height: 400), side: 256)
        XCTAssertEqual(rect.width, 200, accuracy: 0.01)
        XCTAssertEqual(rect.height, 200, accuracy: 0.01)
        XCTAssertEqual(rect.origin.y, 100, accuracy: 0.01)
        XCTAssertEqual(rect.origin.x, 0, accuracy: 0.01)
    }

    func testSquareImageCropsToFullFrame() {
        let rect = ClipPreprocess.cropRect(imageSize: CGSize(width: 300, height: 300), side: 256)
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 300, height: 300))
    }

    func testDegenerateInputReturnsZeroRect() {
        XCTAssertEqual(ClipPreprocess.cropRect(imageSize: .zero, side: 256), .zero)
    }

    func testPixelBufferMatchesRequestedSide() {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8,
                             bytesPerRow: 0, space: cs,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = ctx.makeImage()!
        let buffer = ClipPreprocess.pixelBuffer(from: image, side: 256)
        XCTAssertNotNil(buffer)
        XCTAssertEqual(CVPixelBufferGetWidth(buffer!), 256)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer!), 256)
    }
}
