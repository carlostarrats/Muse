//
//  PeakingOverlayTests.swift
//  MuseTests
//

import XCTest
import CoreImage
@testable import Muse

final class PeakingOverlayTests: XCTestCase {
    private func checkerboard(side: Int = 512, cell: Int = 4) -> CIImage {
        let filter = CIFilter(name: "CICheckerboardGenerator")!
        filter.setValue(CIVector(x: 0, y: 0), forKey: "inputCenter")
        filter.setValue(CIColor.white, forKey: "inputColor0")
        filter.setValue(CIColor.black, forKey: "inputColor1")
        filter.setValue(CGFloat(cell), forKey: "inputWidth")
        return filter.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
    }

    private func blurred(_ image: CIImage) -> CIImage {
        image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 20.0])
            .cropped(to: image.extent)
    }

    private func alphaSum(_ image: CIImage) -> Int {
        let ctx = CIContext()
        let extent = image.extent.integral
        var buffer = [UInt8](repeating: 0, count: Int(extent.width * extent.height) * 4)
        ctx.render(image, toBitmap: &buffer, rowBytes: Int(extent.width) * 4,
                   bounds: extent, format: .RGBA8, colorSpace: nil)
        var total = 0
        for i in stride(from: 3, to: buffer.count, by: 4) { total += Int(buffer[i]) }
        return total
    }

    func testSharpImageProducesNonEmptyPeakingMarks() {
        let sharp = checkerboard()
        let output = PeakingOverlay.render(sharp, accent: .white)
        XCTAssertNotNil(output)
        XCTAssertGreaterThan(alphaSum(output!), 0)
    }

    func testDefocusedImageProducesFarFewerPeakingMarks() {
        let sharp = checkerboard()
        let soft = blurred(sharp)
        let sharpOutput = PeakingOverlay.render(sharp, accent: .white)!
        let softOutput = PeakingOverlay.render(soft, accent: .white)!
        XCTAssertGreaterThan(alphaSum(sharpOutput), alphaSum(softOutput),
                             "a defocused image must mark far fewer edges than a sharp one")
    }

    func testOutputExtentMatchesSourceExtent() {
        let source = checkerboard(side: 256)
        XCTAssertEqual(PeakingOverlay.render(source, accent: .white)?.extent, source.extent)
    }

    func testInfiniteExtentIsRefused() {
        XCTAssertNil(PeakingOverlay.render(CIImage(color: .white), accent: .white))
    }
}
