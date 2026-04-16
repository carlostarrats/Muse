//
//  FluidSim.swift
//  Muse
//

import Foundation
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

nonisolated(unsafe) final class FluidSim: ObservableObject, @unchecked Sendable {

    static let N = 64
    private let N = 64

    private var u:  [Float]
    private var v:  [Float]
    private var u0: [Float]
    private var v0: [Float]

    @Published var dispImage: Image = FluidSim.neutralImage

    var viewportSize: CGSize = CGSize(width: 800, height: 600)

    private var mousePos: CGPoint = CGPoint(x: -1, y: -1)
    private var prevMousePos: CGPoint = CGPoint(x: -1, y: -1)

    private var timer: Timer?
    private var frameCount = 0
    private var didDebugDump = false

    private static let neutralImage: Image = {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        img.lockFocus()
        NSColor(red: 128.0/255.0, green: 128.0/255.0, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        img.unlockFocus()
        return Image(nsImage: img)
    }()

    init() {
        let count = (64 + 2) * (64 + 2)
        u  = [Float](repeating: 0, count: count)
        v  = [Float](repeating: 0, count: count)
        u0 = [Float](repeating: 0, count: count)
        v0 = [Float](repeating: 0, count: count)
    }

    func start() {
        guard timer == nil else { return }
        let sz = N + 2
        for j in (N/3)...(2*N/3) {
            for i in (N/3)...(2*N/3) {
                u0[j * sz + i] = 3.0
                v0[j * sz + i] = 2.0
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
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

    private func step() {
        let n = N
        let sz = n + 2

        if mousePos.x >= 0 && prevMousePos.x >= 0 {
            let dx = mousePos.x - prevMousePos.x
            let dy = mousePos.y - prevMousePos.y
            let speed = sqrt(dx * dx + dy * dy)
            if speed > 0.5 {
                let gx = Float(mousePos.x / viewportSize.width) * Float(n)
                let gy = Float(mousePos.y / viewportSize.height) * Float(n)
                let vx = Float(dx) * 0.3
                let vy = Float(dy) * 0.3
                let radius: Float = 6
                let r2 = radius * radius
                let minI = max(1, Int(gx - radius))
                let maxI = min(n, Int(gx + radius))
                let minJ = max(1, Int(gy - radius))
                let maxJ = min(n, Int(gy + radius))
                for j in minJ...maxJ {
                    for i in minI...maxI {
                        let fx = Float(i) - gx
                        let fy = Float(j) - gy
                        let d2 = fx*fx + fy*fy
                        if d2 < r2 {
                            let w = exp(-d2 / (r2 * 0.25))
                            u0[j * sz + i] += vx * w
                            v0[j * sz + i] += vy * w
                        }
                    }
                }
            }
        }

        diffuse(b: 1, x: &u, x0: u0, diff: 0.0001)
        diffuse(b: 2, x: &v, x0: v0, diff: 0.0001)
        project(u: &u, v: &v, p: &u0, div: &v0)

        let uCopy = u, vCopy = v
        advect(b: 1, d: &u0, d0: uCopy, ux: uCopy, uy: vCopy)
        advect(b: 2, d: &v0, d0: vCopy, ux: uCopy, uy: vCopy)
        swap(&u, &u0)
        swap(&v, &v0)
        project(u: &u, v: &v, p: &u0, div: &v0)

        for i in 0..<u.count { u[i] *= 0.98; v[i] *= 0.98 }
        for i in 0..<u0.count { u0[i] = 0; v0[i] = 0 }

        encodeImage()

        frameCount += 1
        if frameCount == 15 && !didDebugDump {
            didDebugDump = true
            debugDump()
        }
    }

    private func IX(_ i: Int, _ j: Int) -> Int { j * (N + 2) + i }

    private func setBnd(b: Int, x: inout [Float]) {
        let n = N
        for i in 1...n {
            x[IX(0, i)]   = b == 1 ? -x[IX(1, i)] : x[IX(1, i)]
            x[IX(n+1, i)] = b == 1 ? -x[IX(n, i)] : x[IX(n, i)]
            x[IX(i, 0)]   = b == 2 ? -x[IX(i, 1)] : x[IX(i, 1)]
            x[IX(i, n+1)] = b == 2 ? -x[IX(i, n)] : x[IX(i, n)]
        }
        x[IX(0, 0)]     = 0.5 * (x[IX(1, 0)]   + x[IX(0, 1)])
        x[IX(0, n+1)]   = 0.5 * (x[IX(1, n+1)] + x[IX(0, n)])
        x[IX(n+1, 0)]   = 0.5 * (x[IX(n, 0)]   + x[IX(n+1, 1)])
        x[IX(n+1, n+1)] = 0.5 * (x[IX(n, n+1)] + x[IX(n+1, n)])
    }

    private func diffuse(b: Int, x: inout [Float], x0: [Float], diff: Float) {
        let n = N
        let a = (1.0/60.0) * diff * Float(n * n)
        let c = 1.0 + 4.0 * a
        for _ in 0..<4 {
            for j in 1...n {
                for i in 1...n {
                    x[IX(i,j)] = (x0[IX(i,j)] + a * (
                        x[IX(i-1,j)] + x[IX(i+1,j)] +
                        x[IX(i,j-1)] + x[IX(i,j+1)]
                    )) / c
                }
            }
            setBnd(b: b, x: &x)
        }
    }

    private func advect(b: Int, d: inout [Float], d0: [Float], ux: [Float], uy: [Float]) {
        let n = N
        let dt0 = (1.0/60.0) * Float(n)
        for j in 1...n {
            for i in 1...n {
                var x = Float(i) - dt0 * ux[IX(i,j)]
                var y = Float(j) - dt0 * uy[IX(i,j)]
                x = max(0.5, min(Float(n) + 0.5, x))
                y = max(0.5, min(Float(n) + 0.5, y))
                let i0 = Int(x); let i1 = i0 + 1
                let j0 = Int(y); let j1 = j0 + 1
                let s1 = x - Float(i0); let s0 = 1.0 - s1
                let t1 = y - Float(j0); let t0 = 1.0 - t1
                d[IX(i,j)] = s0*(t0*d0[IX(i0,j0)] + t1*d0[IX(i0,j1)]) +
                             s1*(t0*d0[IX(i1,j0)] + t1*d0[IX(i1,j1)])
            }
        }
        setBnd(b: b, x: &d)
    }

    private func project(u: inout [Float], v: inout [Float], p: inout [Float], div: inout [Float]) {
        let n = N
        let h: Float = 1.0 / Float(n)
        for j in 1...n {
            for i in 1...n {
                div[IX(i,j)] = -0.5 * h * (u[IX(i+1,j)] - u[IX(i-1,j)] + v[IX(i,j+1)] - v[IX(i,j-1)])
                p[IX(i,j)] = 0
            }
        }
        setBnd(b: 0, x: &div); setBnd(b: 0, x: &p)
        for _ in 0..<20 {
            for j in 1...n {
                for i in 1...n {
                    p[IX(i,j)] = (div[IX(i,j)] + p[IX(i-1,j)] + p[IX(i+1,j)] + p[IX(i,j-1)] + p[IX(i,j+1)]) / 4.0
                }
            }
            setBnd(b: 0, x: &p)
        }
        for j in 1...n {
            for i in 1...n {
                u[IX(i,j)] -= 0.5 * (p[IX(i+1,j)] - p[IX(i-1,j)]) / h
                v[IX(i,j)] -= 0.5 * (p[IX(i,j+1)] - p[IX(i,j-1)]) / h
            }
        }
        setBnd(b: 1, x: &u); setBnd(b: 2, x: &v)
    }

    private func encodeImage() {
        let n = N
        let sz = n + 2
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let scale: Float = 8.0
        for j in 0..<n {
            for i in 0..<n {
                let idx = (j + 1) * sz + (i + 1)
                let px = j * n + i
                pixels[px * 4 + 0] = UInt8(clamping: Int(u[idx] * scale + 128))
                pixels[px * 4 + 1] = UInt8(clamping: Int(v[idx] * scale + 128))
                pixels[px * 4 + 2] = 0
                pixels[px * 4 + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                  width: n, height: n,
                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil,
                  shouldInterpolate: true, intent: .defaultIntent
              ) else { return }
        let nsImg = NSImage(cgImage: cgImage, size: NSSize(width: n, height: n))
        DispatchQueue.main.async { [weak self] in
            self?.dispImage = Image(nsImage: nsImg)
        }
    }

    private func debugDump() {
        let n = N
        let sz = n + 2
        var maxVal: Float = 0
        for j in 1...n { for i in 1...n { maxVal = max(maxVal, abs(u[IX(i,j)]), abs(v[IX(i,j)])) } }

        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let s: Float = maxVal > 0 ? 127.0 / maxVal : 1.0
        for j in 0..<n {
            for i in 0..<n {
                let idx = (j+1)*sz + (i+1)
                let px = j*n + i
                pixels[px*4+0] = UInt8(clamping: Int(u[idx]*s + 128))
                pixels[px*4+1] = UInt8(clamping: Int(v[idx]*s + 128))
                pixels[px*4+2] = UInt8(clamping: Int(sqrt(u[idx]*u[idx]+v[idx]*v[idx])*s))
                pixels[px*4+3] = 255
            }
        }
        guard let prov = CGDataProvider(data: Data(pixels) as CFData),
              let img = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: n*4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Muse")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fluid_debug.png")
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
        NSLog("[FluidSim] debug: maxVel=%.4f frames=%d path=%@", maxVal, frameCount, url.path)
    }
}
