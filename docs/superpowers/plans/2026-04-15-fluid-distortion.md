# Fluid Distortion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fluid distortion effect to the image grid so mouse movement warps image pixels like dragging through water.

**Architecture:** CPU Navier-Stokes fluid sim at 64x64 encodes velocity as a displacement image. Each tile applies a `.layerEffect` Metal shader that reads the displacement and warps its pixels. The sim lives on `AppState` to avoid `@StateObject` init issues from `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.

**Tech Stack:** SwiftUI `.layerEffect`, Metal Shading Language (stitchable shader), Jos Stam stable fluids (CPU)

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `Muse/Muse/Fluid/FluidSim.swift` | Create | CPU fluid simulation, displacement image encoding |
| `Muse/Muse/Fluid/FluidDistortion.metal` | Create | layerEffect shader that warps tile pixels |
| `Muse/Muse/Models/AppState.swift` | Modify | Add `fluidSim` property |
| `Muse/Muse/ContentView.swift` | Modify | Start fluid sim in `.task` |
| `Muse/Muse/Views/GridView.swift` | Modify | Feed mouse to sim, pass dispImage to tiles, apply `.layerEffect` |

---

### Task 1: Create FluidSim with debug verification

**Files:**
- Create: `Muse/Muse/Fluid/FluidSim.swift`

This is the core simulation. We build it standalone and verify it produces non-zero output via a debug PNG before touching any UI.

- [ ] **Step 1: Create the FluidSim class**

Create `Muse/Muse/Fluid/FluidSim.swift`:

```swift
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

    // Velocity fields (padded: (N+2)*(N+2))
    private var u:  [Float]
    private var v:  [Float]
    private var u0: [Float]
    private var v0: [Float]

    // Output
    @Published var dispImage: Image = FluidSim.neutralImage

    // Viewport
    var viewportSize: CGSize = CGSize(width: 800, height: 600)

    // Mouse
    private var mousePos: CGPoint = CGPoint(x: -1, y: -1)
    private var prevMousePos: CGPoint = CGPoint(x: -1, y: -1)

    // Timer
    private var timer: Timer?

    // Debug
    private var frameCount = 0
    private var didDebugDump = false

    // Neutral displacement image: 1x1, RGB(128,128,0) = zero displacement
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

    // MARK: - Public API

    func start() {
        guard timer == nil else { return }
        // Inject test splats to verify sim works
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

    // MARK: - Simulation Step

    private func step() {
        let n = N
        let sz = n + 2

        // Inject velocity from mouse movement
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

        // Velocity step: diffuse, project, advect, project
        diffuse(b: 1, x: &u, x0: u0, diff: 0.0001)
        diffuse(b: 2, x: &v, x0: v0, diff: 0.0001)
        project(u: &u, v: &v, p: &u0, div: &v0)

        let uCopy = u, vCopy = v
        advect(b: 1, d: &u0, d0: uCopy, ux: uCopy, uy: vCopy)
        advect(b: 2, d: &v0, d0: vCopy, ux: uCopy, uy: vCopy)
        swap(&u, &u0)
        swap(&v, &v0)
        project(u: &u, v: &v, p: &u0, div: &v0)

        // Dissipate
        for i in 0..<u.count {
            u[i] *= 0.98
            v[i] *= 0.98
        }

        // Clear source accumulators
        for i in 0..<u0.count { u0[i] = 0; v0[i] = 0 }

        // Encode and publish
        encodeImage()

        // Debug dump
        frameCount += 1
        if frameCount == 15 && !didDebugDump {
            didDebugDump = true
            debugDump()
        }
    }

    // MARK: - Navier-Stokes Primitives

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
                div[IX(i,j)] = -0.5 * h * (u[IX(i+1,j)] - u[IX(i-1,j)] +
                                             v[IX(i,j+1)] - v[IX(i,j-1)])
                p[IX(i,j)] = 0
            }
        }
        setBnd(b: 0, x: &div); setBnd(b: 0, x: &p)
        for _ in 0..<20 {
            for j in 1...n {
                for i in 1...n {
                    p[IX(i,j)] = (div[IX(i,j)] + p[IX(i-1,j)] + p[IX(i+1,j)] +
                                  p[IX(i,j-1)] + p[IX(i,j+1)]) / 4.0
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

    // MARK: - Image Encoding

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

    // MARK: - Debug

    private func debugDump() {
        let n = N
        let sz = n + 2
        var maxVal: Float = 0
        for j in 1...n { for i in 1...n { maxVal = max(maxVal, abs(u[IX(i,j)]), abs(v[IX(i,j)])) } }

        // Encode a visible debug image
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
```

- [ ] **Step 2: Wire FluidSim into AppState**

In `Muse/Muse/Models/AppState.swift`, add below the existing `private var importCancellable` line (around line 70):

```swift
    /// Fluid distortion simulation — shared across all views.
    let fluidSim = FluidSim()
```

- [ ] **Step 3: Start FluidSim in ContentView**

In `Muse/Muse/ContentView.swift`, modify the existing `.task` block (around line 18) from:

```swift
.task {
    await appState.loadAll()
}
```

to:

```swift
.task {
    appState.fluidSim.start()
    await appState.loadAll()
}
```

- [ ] **Step 4: Build and verify debug output**

Run:
```bash
cd /Users/carlostarrats/Documents/Muse/Muse && xcodebuild -project Muse.xcodeproj -scheme Muse -configuration Debug build
```
Expected: `BUILD SUCCEEDED`

Then launch the app:
```bash
pkill -x Muse 2>/dev/null; sleep 0.5; open /Users/carlostarrats/Library/Developer/Xcode/DerivedData/Muse-cydrdfprluoxczeveuqtgdpllwgu/Build/Products/Debug/Muse.app
```

Wait 3 seconds, then verify the debug image exists:
```bash
find ~/Library/Containers/com.tarrats.Muse -name "fluid_debug.png" 2>/dev/null
```
Expected: a file path is printed. Read the PNG with the Read tool to visually verify it shows non-uniform colors (not a solid gray block).

Also check the system log:
```bash
/usr/bin/log show --last 10s 2>/dev/null | grep FluidSim
```
Expected: a line showing `maxVel` > 0.

**If the debug image does NOT appear:** Check the log for errors. The most likely cause is `nonisolated(unsafe)` not compiling — in that case, try removing the `nonisolated(unsafe)` annotation and just use `final class FluidSim: ObservableObject, @unchecked Sendable`.

- [ ] **Step 5: Remove test splats after verification**

Once the debug PNG confirms the sim works, remove the test splat injection from `start()`. Delete these lines:

```swift
        // Inject test splats to verify sim works
        let sz = N + 2
        for j in (N/3)...(2*N/3) {
            for i in (N/3)...(2*N/3) {
                u0[j * sz + i] = 3.0
                v0[j * sz + i] = 2.0
            }
        }
```

Also remove the debug dump logic (the `frameCount`, `didDebugDump`, and `debugDump()` method) — or leave it gated behind `#if DEBUG` for future use.

- [ ] **Step 6: Commit**

```bash
cd /Users/carlostarrats/Documents/Muse
git add Muse/Muse/Fluid/FluidSim.swift Muse/Muse/Models/AppState.swift Muse/Muse/ContentView.swift
git commit -m "feat: add CPU fluid simulation with debug verification

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Create the Metal layerEffect shader

**Files:**
- Create: `Muse/Muse/Fluid/FluidDistortion.metal`

- [ ] **Step 1: Create the shader file**

Create `Muse/Muse/Fluid/FluidDistortion.metal`:

```metal
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// layerEffect shader: reads displacement from the fluid sim's velocity
// image and warps the tile's pixels accordingly.
//
// position:     pixel coordinate in the tile's local space
// layer:        the tile's rendered content
// dispMap:      64x64 displacement image (R=dx+128, G=dy+128)
// tileOrigin:   tile's top-left corner in viewport coordinates
// viewportSize: viewport dimensions
[[ stitchable ]]
half4 fluidDistort(float2 position,
                   SwiftUI::Layer layer,
                   texture2d<half> dispMap,
                   float2 tileOrigin,
                   float2 viewportSize) {
    // Map tile-local pixel to viewport UV
    float2 globalPos = position + tileOrigin;
    float2 uv = globalPos / viewportSize;
    uv = clamp(uv, float2(0.001), float2(0.999));

    // Sample displacement map with bilinear filtering
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    half4 d = dispMap.sample(s, uv);

    // Decode: 0.5 (128/255) = zero displacement
    // Scale controls max pixel offset
    float2 displacement;
    displacement.x = (float(d.r) - 0.5h) * 2.0 * 40.0;
    displacement.y = (float(d.g) - 0.5h) * 2.0 * 40.0;

    // Sample the tile's actual content at the displaced position
    return layer.sample(position + displacement);
}
```

- [ ] **Step 2: Build to verify shader compiles**

```bash
cd /Users/carlostarrats/Documents/Muse/Muse && xcodebuild -project Muse.xcodeproj -scheme Muse -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```

Expected: `BUILD SUCCEEDED` with no Metal compilation errors.

If the `SwiftUI_Metal.h` import fails, try `#include <SwiftUI/SwiftUI.h>` instead.

- [ ] **Step 3: Commit**

```bash
cd /Users/carlostarrats/Documents/Muse
git add Muse/Muse/Fluid/FluidDistortion.metal
git commit -m "feat: add layerEffect shader for fluid distortion

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Integrate fluid distortion into GridView

**Files:**
- Modify: `Muse/Muse/Views/GridView.swift`

- [ ] **Step 1: Update TileView to accept displacement data**

In `GridView.swift`, modify `TileView` to add new properties (around line 121):

Change:
```swift
private struct TileView: View {

    let image: MuseImage
    let thumbnail: NSImage?
    let isSelected: Bool

    @State private var isHovered = false
```

To:
```swift
private struct TileView: View {

    let image: MuseImage
    let thumbnail: NSImage?
    let isSelected: Bool
    let dispImage: Image
    let viewportSize: CGSize

    @State private var isHovered = false
    @State private var tileFrame: CGRect = .zero
```

- [ ] **Step 2: Add `.layerEffect` and frame tracking to TileView body**

In `TileView`'s `body`, after the two `.shadow` modifiers (around line 139) and BEFORE `.animation`, add:

```swift
            .layerEffect(
                ShaderLibrary.fluidDistort(
                    .image(dispImage),
                    .float2(Float(tileFrame.minX), Float(tileFrame.minY)),
                    .float2(Float(viewportSize.width), Float(viewportSize.height))
                ),
                maxSampleOffset: CGSize(width: 50, height: 50)
            )
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { tileFrame = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, newFrame in
                        tileFrame = newFrame
                    }
            })
```

The full modifier chain becomes: clipShape → overlay(stroke) → shadow → shadow → **layerEffect → background(GeometryReader)** → animation → animation → onHover.

- [ ] **Step 3: Pass dispImage and viewportSize from GridView to TileView**

In `GridView`'s `body`, change the `TileView` constructor (around line 31) from:

```swift
TileView(
    image: image,
    thumbnail: thumbnailCache[image.id],
    isSelected: isSelected
)
```

To:
```swift
TileView(
    image: image,
    thumbnail: thumbnailCache[image.id],
    isSelected: isSelected,
    dispImage: appState.fluidSim.dispImage,
    viewportSize: geometry.size
)
```

- [ ] **Step 4: Feed mouse position to FluidSim**

In `GridView`'s `body`, modify the existing `onContinuousHover` handler (around line 74) from:

```swift
.onContinuousHover { phase in
    switch phase {
    case .active(let location):
        withAnimation(.interactiveSpring(response: 0.6, dampingFraction: 0.7)) {
            normalisedCursor = normalise(location, in: geometry.size)
        }
    case .ended:
        withAnimation(.interactiveSpring(response: 0.8, dampingFraction: 0.6)) {
            normalisedCursor = .zero
        }
    }
}
```

To:
```swift
.onContinuousHover { phase in
    switch phase {
    case .active(let location):
        appState.fluidSim.setMouse(location)
        withAnimation(.interactiveSpring(response: 0.6, dampingFraction: 0.7)) {
            normalisedCursor = normalise(location, in: geometry.size)
        }
    case .ended:
        appState.fluidSim.clearMouse()
        withAnimation(.interactiveSpring(response: 0.8, dampingFraction: 0.6)) {
            normalisedCursor = .zero
        }
    }
}
```

Also add viewport size sync. After the `.onContinuousHover` block, add:

```swift
.onChange(of: geometry.size) { _, newSize in
    appState.fluidSim.viewportSize = newSize
}
.onAppear {
    appState.fluidSim.viewportSize = geometry.size
}
```

- [ ] **Step 5: Build and launch**

```bash
cd /Users/carlostarrats/Documents/Muse/Muse && xcodebuild -project Muse.xcodeproj -scheme Muse -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: `BUILD SUCCEEDED`

Launch:
```bash
pkill -x Muse 2>/dev/null; sleep 0.5; open /Users/carlostarrats/Library/Developer/Xcode/DerivedData/Muse-cydrdfprluoxczeveuqtgdpllwgu/Build/Products/Debug/Muse.app
```

Move the mouse over the grid. Images should visibly warp — pixels displacing in the direction of mouse movement, persisting briefly, then settling back.

If images appear but there's no visible distortion:
1. Check the debug PNG exists and shows non-uniform colors
2. Try increasing the displacement scale in the shader from `40.0` to `80.0`
3. Check that `tileFrame` is non-zero by adding a temporary `print(tileFrame)` in the `onAppear`

If the screen is blank:
1. Remove the `.layerEffect` modifier to confirm tiles render without it
2. Check Metal shader compilation in the build log

- [ ] **Step 6: Commit**

```bash
cd /Users/carlostarrats/Documents/Muse
git add Muse/Muse/Views/GridView.swift
git commit -m "feat: integrate fluid distortion into grid tiles

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Tune and clean up

- [ ] **Step 1: Tune displacement strength**

If the distortion is too subtle, increase the scale factor in `FluidDistortion.metal`:
```metal
displacement.x = (float(d.r) - 0.5h) * 2.0 * 60.0;  // was 40.0
displacement.y = (float(d.g) - 0.5h) * 2.0 * 60.0;
```

If too aggressive, reduce to `25.0`.

Also tune `FluidSim.swift`:
- Dissipation: `0.98` = fades in ~2 seconds. Try `0.96` for faster fade or `0.99` for longer persistence.
- Splat strength: the `0.3` multiplier on mouse velocity. Increase for more responsiveness.
- Splat radius: `6` cells. Increase for wider distortion area.

- [ ] **Step 2: Remove debug code**

Remove or gate behind `#if DEBUG`:
- The test splat injection in `start()`
- The `frameCount`, `didDebugDump`, `debugDump()` method
- Any `NSLog` calls

- [ ] **Step 3: Build, test, commit**

```bash
cd /Users/carlostarrats/Documents/Muse/Muse && xcodebuild -project Muse.xcodeproj -scheme Muse -configuration Debug build 2>&1 | grep "BUILD"
pkill -x Muse 2>/dev/null; sleep 0.5; open /Users/carlostarrats/Library/Developer/Xcode/DerivedData/Muse-cydrdfprluoxczeveuqtgdpllwgu/Build/Products/Debug/Muse.app
```

Verify: mouse movement warps images, distortion fades when mouse stops, all existing features work (click selection, double-click preview, Cmd+click multi-select, parallax tilt, scrolling).

```bash
cd /Users/carlostarrats/Documents/Muse
git add -A
git commit -m "polish: tune fluid distortion parameters, remove debug code

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```
