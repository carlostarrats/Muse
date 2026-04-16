//
//  FluidSim.swift
//  Muse
//
//  2D wave equation simulation. Mouse movement disturbs the surface,
//  waves propagate outward in expanding circles like dragging through water.
//  The surface gradient is encoded as a displacement map for the shader.
//

import Foundation
import SwiftUI
import AppKit

nonisolated(unsafe) final class FluidSim: ObservableObject, @unchecked Sendable {

    static let N = 128
    private let N = 128
    private let sz = 130 // N + 2

    // Wave height fields: current and previous frame
    private var h:     [Float]
    private var hPrev: [Float]

    // Preallocated pixel buffer
    private var pixels: [UInt8]

    @Published var dispImage: Image = FluidSim.neutralImage

    var viewportSize: CGSize = CGSize(width: 800, height: 600)

    private var mousePos: CGPoint = CGPoint(x: -1, y: -1)
    private var prevMousePos: CGPoint = CGPoint(x: -1, y: -1)

    private var timer: Timer?

    static let neutralImage: Image = {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        img.lockFocus()
        NSColor(red: 128.0/255.0, green: 128.0/255.0, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        img.unlockFocus()
        return Image(nsImage: img)
    }()

    init() {
        let count = 130 * 130
        h     = [Float](repeating: 0, count: count)
        hPrev = [Float](repeating: 0, count: count)
        pixels = [UInt8](repeating: 0, count: 128 * 128 * 4)
    }

    // MARK: - Public API

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.step()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setMouse(_ pos: CGPoint) {
        prevMousePos = mousePos
        mousePos = pos
    }

    func clearMouse() {
        mousePos = CGPoint(x: -1, y: -1)
        prevMousePos = CGPoint(x: -1, y: -1)
    }

    // MARK: - Simulation Step

    private func step() {
        let n = N
        let s = sz

        // 1. Inject disturbance at mouse position
        if mousePos.x >= 0 && prevMousePos.x >= 0 {
            let dx = mousePos.x - prevMousePos.x
            let dy = mousePos.y - prevMousePos.y
            let speed = sqrt(dx * dx + dy * dy)
            if speed > 0.3 {
                let gx = Float(mousePos.x / viewportSize.width) * Float(n)
                let gy = Float(mousePos.y / viewportSize.height) * Float(n)
                let strength = min(Float(speed) * 0.4, 6.0)
                let radius: Float = 5
                let r2 = radius * radius
                let minI = max(1, Int(gx - radius))
                let maxI = min(n, Int(gx + radius))
                let minJ = max(1, Int(gy - radius))
                let maxJ = min(n, Int(gy + radius))
                for j in minJ...maxJ {
                    for i in minI...maxI {
                        let fx = Float(i) - gx
                        let fy = Float(j) - gy
                        let d2 = fx * fx + fy * fy
                        if d2 < r2 {
                            let w = exp(-d2 / (r2 * 0.3))
                            h[j * s + i] += strength * w
                        }
                    }
                }
            }
        }

        // 2. Wave equation: h_next = 2*h - h_prev + c^2 * laplacian(h)
        //    We compute h_next into hPrev (which we don't need after this)
        let c2: Float = 0.3  // wave speed squared — controls propagation rate

        for j in 1...n {
            for i in 1...n {
                let idx = j * s + i
                let laplacian = h[idx - 1] + h[idx + 1] + h[idx - s] + h[idx + s] - 4.0 * h[idx]
                let hNext = 2.0 * h[idx] - hPrev[idx] + c2 * laplacian
                // Smooth damping curve: small amplitudes decay faster than large ones
                // Uses a continuous function so there's no visible speed-up or snap
                let absH = abs(hNext)
                let damping: Float = 0.90 + min(absH, 3.0) * 0.02  // range: 0.90 to 0.96
                hPrev[idx] = hNext * damping
            }
        }

        // 3. Swap: hPrev now has the new values, h has the current
        swap(&h, &hPrev)
        // Now h = new frame, hPrev = old frame (for next iteration)

        // 4. Boundary: zero at edges
        for i in 0..<s {
            h[i] = 0          // top row
            h[(n + 1) * s + i] = 0  // bottom row
            h[i * s] = 0      // left column
            h[i * s + (n + 1)] = 0  // right column
        }

        // 5. Encode surface gradient as displacement image
        encodeImage()
    }

    // MARK: - Image Encoding

    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

    private func encodeImage() {
        let n = N
        let s = sz
        // Encode the GRADIENT of the height field as displacement.
        // Gradient = surface normal, which is what causes light refraction in water.
        let scale: Float = 35.0
        for j in 0..<n {
            for i in 0..<n {
                let idx = (j + 1) * s + (i + 1)
                // Central difference gradient
                let dhdx = (h[idx + 1] - h[idx - 1]) * 0.5
                let dhdy = (h[idx + s] - h[idx - s]) * 0.5
                let px = (j * n + i) * 4
                pixels[px]     = UInt8(clamping: Int(dhdx * scale + 128))
                pixels[px + 1] = UInt8(clamping: Int(dhdy * scale + 128))
                pixels[px + 2] = 0
                pixels[px + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                  width: n, height: n,
                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                  space: colorSpace, bitmapInfo: bitmapInfo,
                  provider: provider, decode: nil,
                  shouldInterpolate: true, intent: .defaultIntent
              ) else { return }
        let nsImg = NSImage(cgImage: cgImage, size: NSSize(width: n, height: n))
        dispImage = Image(nsImage: nsImg)
    }
}
