# Spatial Views (Polish Phase 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement spec §3 of `docs/superpowers/specs/2026-06-10-post-rewrite-polish-design.md`: a three-way Grid / Cloud / Graph toolbar toggle where Cloud is a real-3D SceneKit scatter matching `docs/superpowers/assets/cloud-pose-prototype.html` (measured poses, warm shadows, drift, hover-float, click-to-open) and Graph replaces GlobeView with a flat-2D knowledge graph of collections that zooms into a 3D similarity spread per cluster.

**Architecture:** All pure math (pose generation, CSS→SceneKit rotation conversion, force-directed 2D layout, 3D stress layout, shared-tag edges) lives in small unit-tested files under `Muse/Muse/Views/Spatial/`. SceneKit views are thin: one perspective camera each, scene units = reference pixels for Cloud, world units for Graph. Both views open the hero viewer by writing the clicked card's projected screen rect into `appState.tileFrames` before setting `selectedFile` — the existing flight machinery does the rest. `GlobeView.swift` and `SceneKit/FibonacciSphere.swift` are deleted.

**Tech Stack:** SwiftUI + SceneKit (macOS 14.6+), simd, GRDB (collections/tags/feature prints), Vision (`VNFeaturePrintObservation.computeDistance` only, via existing stored prints), XCTest.

**Verified project facts:**
- Xcode 16 synced folders — new files under `Muse/Muse/` and `Muse/MuseTests/` are auto-included. Build/test from the `Muse/` directory: `xcodebuild -scheme Muse build` and `xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests`.
- `AppState.ViewMode` is currently `{ grid, globe }` (AppState.swift:75). ContentView's segmented Picker (ContentView.swift:66-72) is the only place that renders it; `CollectionsRow` shows only when `viewMode == .grid` (ContentView.swift:24). The toolbar is AT the 10-item ToolbarContentBuilder limit — we only modify the existing Picker, never add an item.
- Hero viewer source rect: `appState.tileFrames[url.path]` in SwiftUI `.global` coords (HeroImageViewer.swift:196 converts via the overlay's own global frame; falls back to a centered 160pt rect if missing).
- `appState.visibleFiles` is the in-scope file list (folder ∩ optional collection filter; search results pass through). Image kinds = `.image || .raw || .psd` (same filter GlobeView uses).
- `ThumbnailCache.shared.thumbnail(for:size:)` is `@MainActor` async, returns `NSImage?`.
- Collections: `CollectionsEngine.shared.collections` (`[CollectionStore.Loaded]`, `@MainActor @Published`), each `Loaded` = `CollectionRow` + `memberIDs: [String]`. `paths` table maps `absolute_path` ↔ `file_id` with `is_alive`. Tags: `tags(file_id, label, source)`; collection naming already excludes `source != 'vision-color'` (CollectionsEngine.swift:86).
- Feature prints: `files.feature_print` is an `NSKeyedArchiver`'d `VNFeaturePrintObservation`; DuplicateFinder.swift:218-224 shows unarchive + `computeDistance` usage.
- Tests build an in-memory DB via `try Database.makeMigrator().migrate(DatabaseQueue())` (see `CollectionMembershipTests.swift`).
- Prototype pose data: the `POSES` array in `cloud-pose-prototype.html` lines 24-50 is the FINAL card geometry (w/h already include the fitted scale `s`; `cloud-poses.json` holds the raw fit). Stage constants: `REFW = 1999, REFH = 1064, F = 1100`. Background `#E6CFB5`. Hover: flat + `scale(1.15)`, `0.5s cubic-bezier(.25,.85,.3,1)`, zIndex bump. Shadow: `10px 18px 34px rgba(95,65,35,.28)`. zIndex at rest = `4 + round(cy/40)` (lower on canvas paints in front).
- CSS transform order in the prototype is `translate → perspective → rotateZ → rotateY → rotateX`, i.e. rotation matrix `Rz·Ry·Rx` in CSS space (x right, **y down**, z toward viewer). Converting to SceneKit (y up) by conjugation with `diag(1,-1,1)` flips the sign of the x- and z-angles and keeps y: `R_scn = Rz(-rz)·Ry(ry)·Rx(-rx)`.
- Spec decision: Cloud uses ONE SceneKit camera (global vanishing point), accepted divergence from the per-card CSS `perspective()`. Composition is locked to the fixed-aspect stage, letterboxed.

---

### Task 0: Branch

- [ ] `cd /Users/carlostarrats/Documents/Projects/Muse && git checkout -b feat/spatial-views`

---

### Task 1: SeededRandom — deterministic RNG + stable string seed

Layouts must be stable across launches (Swift's `hashValue` is per-launch randomized, `SystemRandomNumberGenerator` is not seedable).

**Files:**
- Create: `Muse/Muse/Views/Spatial/SeededRandom.swift`
- Test: `Muse/MuseTests/SeededRandomTests.swift`

- [ ] **Step 1 — failing tests** (`Muse/MuseTests/SeededRandomTests.swift`):

```swift
import XCTest
@testable import Muse

final class SeededRandomTests: XCTestCase {
    func testSameSeedSameSequence() {
        var a = SeededRandom(seed: 42), b = SeededRandom(seed: 42)
        for _ in 0..<32 { XCTAssertEqual(a.next(), b.next()) }
    }

    func testDifferentSeedsDiverge() {
        var a = SeededRandom(seed: 1), b = SeededRandom(seed: 2)
        let av = (0..<8).map { _ in a.next() }
        let bv = (0..<8).map { _ in b.next() }
        XCTAssertNotEqual(av, bv)
    }

    func testFNV1aIsStableAndOrderSensitive() {
        let s1 = SeededRandom.fnv1a(["/a/b.png", "/c/d.jpg"])
        let s2 = SeededRandom.fnv1a(["/a/b.png", "/c/d.jpg"])
        let s3 = SeededRandom.fnv1a(["/c/d.jpg", "/a/b.png"])
        XCTAssertEqual(s1, s2)
        XCTAssertNotEqual(s1, s3)
        // Known vector: FNV-1a 64 of empty input is the offset basis.
        XCTAssertEqual(SeededRandom.fnv1a([]), 0xcbf29ce484222325)
    }

    func testUniformDoubleInRange() {
        var rng = SeededRandom(seed: 7)
        for _ in 0..<100 {
            let v = Double.random(in: 3...9, using: &rng)
            XCTAssertTrue(v >= 3 && v <= 9)
        }
    }
}
```

- [ ] **Step 2 — run to verify failure**

Run: `cd /Users/carlostarrats/Documents/Projects/Muse/Muse && xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/SeededRandomTests 2>&1 | tail -20`
Expected: build FAILS with "cannot find 'SeededRandom' in scope".

- [ ] **Step 3 — implement** (`Muse/Muse/Views/Spatial/SeededRandom.swift`):

```swift
//
//  SeededRandom.swift
//  Muse
//
//  Deterministic RNG (SplitMix64) + stable string hashing (FNV-1a 64)
//  so spatial layouts are identical across launches for the same files.
//

import Foundation

struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// FNV-1a 64 over the UTF-8 of each string in order, with a 0xFF
    /// separator byte between strings (order-sensitive, launch-stable).
    static func fnv1a(_ strings: [String]) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for (i, s) in strings.enumerated() {
            if i > 0 { hash = (hash ^ 0xFF) &* prime }
            for byte in s.utf8 {
                hash = (hash ^ UInt64(byte)) &* prime
            }
        }
        return hash
    }
}
```

- [ ] **Step 4 — run tests**

Run: `cd /Users/carlostarrats/Documents/Projects/Muse/Muse && xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/SeededRandomTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5 — commit**

```bash
cd /Users/carlostarrats/Documents/Projects/Muse
git add Muse/Muse/Views/Spatial/SeededRandom.swift Muse/MuseTests/SeededRandomTests.swift
git commit -m "feat(spatial): seeded RNG + stable FNV-1a path hashing for deterministic layouts"
```

---

### Task 2: CloudPose + CloudLayout — measured poses and generated arrangements

**Files:**
- Create: `Muse/Muse/Views/Spatial/CloudPose.swift`
- Create: `Muse/Muse/Views/Spatial/CloudLayout.swift`
- Test: `Muse/MuseTests/CloudLayoutTests.swift`

- [ ] **Step 1 — failing tests** (`Muse/MuseTests/CloudLayoutTests.swift`):

```swift
import XCTest
@testable import Muse

final class CloudLayoutTests: XCTestCase {
    func testMeasuredPosesAreThe25FromThePrototype() {
        XCTAssertEqual(CloudPose.measured.count, 25)
        // Spot-check first and last against cloud-pose-prototype.html POSES
        let first = CloudPose.measured[0]
        XCTAssertEqual(first.w, 194.0, accuracy: 0.01)
        XCTAssertEqual(first.h, 219.4, accuracy: 0.01)
        XCTAssertEqual(first.cx, 337.5, accuracy: 0.01)
        XCTAssertEqual(first.cy, 199.4, accuracy: 0.01)
        XCTAssertEqual(first.rx, -33.0, accuracy: 0.01)
        XCTAssertEqual(first.ry, -30.4, accuracy: 0.01)
        XCTAssertEqual(first.rz, 47.5, accuracy: 0.01)
        let last = CloudPose.measured[24]
        XCTAssertEqual(last.w, 514.8, accuracy: 0.01)
        XCTAssertEqual(last.cy, 1006.4, accuracy: 0.01)
    }

    func testSmallCountsUseMeasuredPrefix() {
        let poses = CloudLayout.poses(count: 7, seed: 99)
        XCTAssertEqual(poses.count, 7)
        XCTAssertEqual(poses[3].cx, CloudPose.measured[3].cx, accuracy: 0.001)
    }

    func testLargeCountsAreGeneratedWithinSpecStatistics() {
        let poses = CloudLayout.poses(count: 60, seed: 5)
        XCTAssertEqual(poses.count, 60)
        for p in poses {
            XCTAssertTrue(abs(p.rx) >= 10 && abs(p.rx) <= 33, "rx \(p.rx)")
            XCTAssertTrue(abs(p.ry) >= 5 && abs(p.ry) <= 30, "ry \(p.ry)")
            XCTAssertTrue(abs(p.rz) >= 5 && abs(p.rz) <= 47, "rz \(p.rz)")
            XCTAssertTrue(p.w >= CloudPose.refW * 0.04 && p.w <= CloudPose.refW * 0.10, "w \(p.w)")
            // Cards stay on the stage
            XCTAssertTrue(p.cx > 0 && p.cx < CloudPose.refW)
            XCTAssertTrue(p.cy > 0 && p.cy < CloudPose.refH)
            XCTAssertTrue(p.w.isFinite && p.h.isFinite && p.cx.isFinite && p.cy.isFinite)
        }
    }

    func testGenerationIsDeterministicPerSeed() {
        let a = CloudLayout.poses(count: 40, seed: 11)
        let b = CloudLayout.poses(count: 40, seed: 11)
        let c = CloudLayout.poses(count: 40, seed: 12)
        XCTAssertEqual(a.map(\.cx), b.map(\.cx))
        XCTAssertNotEqual(a.map(\.cx), c.map(\.cx))
    }

    func testZeroCount() {
        XCTAssertTrue(CloudLayout.poses(count: 0, seed: 1).isEmpty)
    }
}
```

- [ ] **Step 2 — run to verify failure**

Run: `cd /Users/carlostarrats/Documents/Projects/Muse/Muse && xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/CloudLayoutTests 2>&1 | tail -20`
Expected: build FAILS with "cannot find 'CloudPose' in scope".

- [ ] **Step 3 — implement `CloudPose.swift`** (poses transcribed 1:1 from `cloud-pose-prototype.html` `POSES`, which is the committed final state):

```swift
//
//  CloudPose.swift
//  Muse
//
//  One card's pose on the cloud stage, in reference-canvas pixels.
//  The 25 measured poses were fitted from the Sternberg Press reference
//  (traced corners -> rigid tilted-rectangle fit, worst error 0.6% of
//  canvas) — see docs/superpowers/assets/cloud-pose-prototype.html and
//  cloud-poses.json. w/h here already include the fitted scale.
//  Angles are CSS-space degrees (x right, y down, z toward viewer),
//  applied rotateZ -> rotateY -> rotateX. CloudMath converts to SceneKit.
//

import Foundation

struct CloudPose: Equatable {
    var w: Double
    var h: Double
    var cx: Double
    var cy: Double
    var rx: Double
    var ry: Double
    var rz: Double

    /// Reference stage size and perspective the poses were measured in.
    static let refW: Double = 1999
    static let refH: Double = 1064
    static let f: Double = 1100

    static let measured: [CloudPose] = [
        .init(w: 194.0, h: 219.4, cx: 337.5, cy: 199.4, rx: -33.0, ry: -30.4, rz: 47.5),
        .init(w: 80.5, h: 224.2, cx: 487.5, cy: 417.8, rx: -29.8, ry: -28.6, rz: 23.9),
        .init(w: 103.4, h: 180.8, cx: 605.4, cy: 387.6, rx: -20.9, ry: -21.6, rz: 22.3),
        .init(w: 178.6, h: 147.3, cx: 384.9, cy: 579.5, rx: 20.4, ry: -19.1, rz: 6.3),
        .init(w: 123.5, h: 175.2, cx: 553.9, cy: 593.1, rx: 11.4, ry: -10.0, rz: 11.2),
        .init(w: 154.1, h: 230.8, cx: 771.9, cy: 567.1, rx: -11.2, ry: -10.2, rz: 10.4),
        .init(w: 203.6, h: 237.9, cx: 941.4, cy: 493.5, rx: 23.6, ry: 21.8, rz: -8.5),
        .init(w: 119.9, h: 153.5, cx: 1036.2, cy: 309.6, rx: -11.4, ry: 6.2, rz: 8.5),
        .init(w: 113.4, h: 249.0, cx: 1187.6, cy: 375.8, rx: -27.3, ry: -25.3, rz: 25.9),
        .init(w: 114.4, h: 219.8, cx: 1375.0, cy: 383.4, rx: 23.2, ry: 21.4, rz: 20.2),
        .init(w: 177.3, h: 175.5, cx: 1537.1, cy: 288.7, rx: 7.4, ry: -12.0, rz: 15.9),
        .init(w: 88.5, h: 138.1, cx: 1472.1, cy: 480.7, rx: 2.8, ry: -5.8, rz: 13.2),
        .init(w: 248.8, h: 223.8, cx: 1681.8, cy: 417.6, rx: 16.9, ry: -17.8, rz: 16.3),
        .init(w: 128.8, h: 159.7, cx: 1241.9, cy: 579.4, rx: 18.1, ry: -18.4, rz: 16.4),
        .init(w: 216.2, h: 227.0, cx: 1088.6, cy: 669.5, rx: 14.4, ry: -13.9, rz: 25.9),
        .init(w: 142.8, h: 190.0, cx: 1425.6, cy: 709.2, rx: -3.3, ry: -7.6, rz: 14.3),
        .init(w: 162.4, h: 237.6, cx: 1603.4, cy: 748.5, rx: -0.3, ry: -8.0, rz: 21.0),
        .init(w: 148.9, h: 137.0, cx: 1771.4, cy: 680.4, rx: 26.0, ry: -24.7, rz: 12.5),
        .init(w: 124.3, h: 234.7, cx: 1275.4, cy: 849.0, rx: -16.1, ry: -16.1, rz: 25.4),
        .init(w: 225.9, h: 242.6, cx: 228.8, cy: 843.4, rx: 21.9, ry: -13.3, rz: -4.9),
        .init(w: 97.8, h: 297.9, cx: 420.1, cy: 918.1, rx: 31.7, ry: -26.2, rz: 30.8),
        .init(w: 126.3, h: 188.5, cx: 634.0, cy: 789.6, rx: 11.6, ry: -14.1, rz: 21.7),
        .init(w: 206.1, h: 301.9, cx: 848.2, cy: 831.0, rx: 24.7, ry: -14.7, rz: -6.8),
        .init(w: 124.5, h: 231.7, cx: 974.2, cy: 821.7, rx: 7.2, ry: -9.5, rz: 8.8),
        .init(w: 514.8, h: 114.6, cx: 1732.1, cy: 1006.4, rx: 8.8, ry: 0.4, rz: 0.4),
    ]
}
```

- [ ] **Step 4 — implement `CloudLayout.swift`**:

```swift
//
//  CloudLayout.swift
//  Muse
//
//  Poses for N cards. Up to 25 cards use the measured reference poses
//  verbatim; beyond that the full set is generated with the same
//  statistics (spec: rx ±10–33°, ry ±5–30°, rz ±5–47°, sizes 4–10% of
//  canvas width, flowing band composition). Deterministic per seed.
//

import Foundation

enum CloudLayout {
    static func poses(count: Int, seed: UInt64) -> [CloudPose] {
        guard count > 0 else { return [] }
        if count <= CloudPose.measured.count {
            return Array(CloudPose.measured.prefix(count))
        }
        return generated(count: count, seed: seed)
    }

    private static func generated(count: Int, seed: UInt64) -> [CloudPose] {
        var rng = SeededRandom(seed: seed)
        // Flowing bands: enough rows to keep ~7 cards per band, serpentine
        // vertical wave along each band like the reference composition.
        let rows = max(3, Int(ceil(Double(count) / 7.0)))
        let cols = Int(ceil(Double(count) / Double(rows)))
        let marginX = CloudPose.refW * 0.07
        let marginY = CloudPose.refH * 0.13
        var out: [CloudPose] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let r = i / cols
            let c = i % cols
            let tx = cols > 1 ? Double(c) / Double(cols - 1) : 0.5
            let ty = rows > 1 ? Double(r) / Double(rows - 1) : 0.5
            let wave = sin(tx * .pi * 2.2 + Double(r) * 1.3) * (CloudPose.refH * 0.035)
            let cx = marginX + tx * (CloudPose.refW - 2 * marginX)
                + Double.random(in: -45...45, using: &rng)
            let cy = marginY + ty * (CloudPose.refH - 2 * marginY) + wave
                + Double.random(in: -35...35, using: &rng)
            let w = CloudPose.refW * Double.random(in: 0.04...0.10, using: &rng)
            let h = w * Double.random(in: 0.75...1.55, using: &rng)
            func signedAngle(_ range: ClosedRange<Double>) -> Double {
                let magnitude = Double.random(in: range, using: &rng)
                return Bool.random(using: &rng) ? magnitude : -magnitude
            }
            out.append(CloudPose(
                w: w, h: h,
                cx: min(max(cx, marginX * 0.5), CloudPose.refW - marginX * 0.5),
                cy: min(max(cy, marginY * 0.5), CloudPose.refH - marginY * 0.5),
                rx: signedAngle(10...33),
                ry: signedAngle(5...30),
                rz: signedAngle(5...47)
            ))
        }
        return out
    }
}
```

- [ ] **Step 5 — run tests**

Run: `cd /Users/carlostarrats/Documents/Projects/Muse/Muse && xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/CloudLayoutTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`. (Note: `h` may exceed 10% of width — only `w` is spec-bounded; the test reflects that.)

- [ ] **Step 6 — commit**

```bash
cd /Users/carlostarrats/Documents/Projects/Muse
git add Muse/Muse/Views/Spatial/CloudPose.swift Muse/Muse/Views/Spatial/CloudLayout.swift Muse/MuseTests/CloudLayoutTests.swift
git commit -m "feat(spatial): measured cloud poses + seeded band-composition pose generation"
```

---

### Task 3: CloudMath — CSS→SceneKit rotation conversion + stage camera

**Files:**
- Create: `Muse/Muse/Views/Spatial/CloudMath.swift`
- Test: `Muse/MuseTests/CloudMathTests.swift`

- [ ] **Step 1 — failing tests** (`Muse/MuseTests/CloudMathTests.swift`):

```swift
import XCTest
import simd
@testable import Muse

final class CloudMathTests: XCTestCase {
    // CSS rotateZ(+90°): with y pointing DOWN in CSS, the screen-right
    // vector rotates to screen-down. In SceneKit (y up) screen-down is -y.
    func testRotateZ90MatchesCSSClockwiseOnScreen() {
        let q = CloudMath.orientation(rxDeg: 0, ryDeg: 0, rzDeg: 90)
        let v = q.act(SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(v.x, 0, accuracy: 1e-5)
        XCTAssertEqual(v.y, -1, accuracy: 1e-5)
        XCTAssertEqual(v.z, 0, accuracy: 1e-5)
    }

    // CSS rotateX(+90°): the card's bottom edge (y down) swings toward the
    // viewer (+z in CSS, +z in SceneKit too). The card's TOP edge — +y in
    // SceneKit — must therefore swing AWAY from the viewer (-z).
    func testRotateX90TiltsTopEdgeAway() {
        let q = CloudMath.orientation(rxDeg: 90, ryDeg: 0, rzDeg: 0)
        let v = q.act(SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(v.y, 0, accuracy: 1e-5)
        XCTAssertEqual(v.z, -1, accuracy: 1e-5)
    }

    // CSS rotateY(+90°): the right edge (+x) swings away from the viewer
    // (-z in CSS — CSS rotateY positive turns the right edge backward...
    // verified against the browser: rotateY(+θ) moves +x toward -z? No:
    // in CSS, rotateY(+90deg) maps (1,0,0) -> (0,0,-1)? The standard
    // right-handed Ry maps x -> -z when θ=+90 with y down. Same in
    // SceneKit space because the y-axis is untouched by Ry and the
    // conjugation leaves Ry unchanged.
    func testRotateY90MapsRightEdgeBackward() {
        let q = CloudMath.orientation(rxDeg: 0, ryDeg: 90, rzDeg: 0)
        let v = q.act(SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(v.x, 0, accuracy: 1e-5)
        XCTAssertEqual(v.z, -1, accuracy: 1e-5)
    }

    func testCompositionOrderIsZThenYThenX() {
        // Composite must equal applying X first, then Y, then Z (CSS
        // reads transform lists left-to-right as world-side products).
        let q = CloudMath.orientation(rxDeg: 30, ryDeg: 40, rzDeg: 50)
        let qz = CloudMath.orientation(rxDeg: 0, ryDeg: 0, rzDeg: 50)
        let qy = CloudMath.orientation(rxDeg: 0, ryDeg: 40, rzDeg: 0)
        let qx = CloudMath.orientation(rxDeg: 30, ryDeg: 0, rzDeg: 0)
        let manual = qz * qy * qx
        let v = SIMD3<Float>(0.3, -0.7, 0.2)
        XCTAssertLessThan(simd_length(q.act(v) - manual.act(v)), 1e-5)
    }

    func testStagePositionMapsReferencePixelsToCenteredYUp() {
        let center = CloudMath.position(cx: CloudPose.refW / 2, cy: CloudPose.refH / 2)
        XCTAssertEqual(center, SIMD3<Float>(0, 0, 0))
        let topLeft = CloudMath.position(cx: 0, cy: 0)
        XCTAssertEqual(topLeft.x, Float(-CloudPose.refW / 2), accuracy: 0.001)
        XCTAssertEqual(topLeft.y, Float(CloudPose.refH / 2), accuracy: 0.001)
    }

    func testFOVsShowExactlyTheStageAtCameraDistanceF() {
        // visible height at z=0 = 2 * F * tan(fov/2) == refH
        let vh = 2 * CloudPose.f * tan(CloudMath.verticalFOV * .pi / 180 / 2)
        XCTAssertEqual(vh, CloudPose.refH, accuracy: 0.01)
        let hw = 2 * CloudPose.f * tan(CloudMath.horizontalFOV * .pi / 180 / 2)
        XCTAssertEqual(hw, CloudPose.refW, accuracy: 0.01)
    }
}
```

- [ ] **Step 2 — run to verify failure**

Run: `cd /Users/carlostarrats/Documents/Projects/Muse/Muse && xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/CloudMathTests 2>&1 | tail -20`
Expected: build FAILS with "cannot find 'CloudMath' in scope".

- [ ] **Step 3 — implement** (`Muse/Muse/Views/Spatial/CloudMath.swift`):

```swift
//
//  CloudMath.swift
//  Muse
//
//  Pure conversion from the prototype's CSS model to SceneKit. CSS space
//  is x-right / y-DOWN / z-toward-viewer with transform list
//  `rotateZ(rz) rotateY(ry) rotateX(rx)` (matrix Rz·Ry·Rx). SceneKit is
//  y-UP; conjugating by diag(1,-1,1) negates the x and z angles and
//  leaves y alone. Scene units = reference-canvas pixels.
//

import Foundation
import simd

enum CloudMath {
    /// SceneKit orientation equivalent of the prototype's CSS rotation.
    static func orientation(rxDeg: Double, ryDeg: Double, rzDeg: Double) -> simd_quatf {
        let d = Float.pi / 180
        let qz = simd_quatf(angle: -Float(rzDeg) * d, axis: SIMD3(0, 0, 1))
        let qy = simd_quatf(angle: Float(ryDeg) * d, axis: SIMD3(0, 1, 0))
        let qx = simd_quatf(angle: -Float(rxDeg) * d, axis: SIMD3(1, 0, 0))
        return qz * qy * qx   // x applied first, matching CSS list order
    }

    /// Card center in scene space (origin = stage center, y up, z = 0).
    static func position(cx: Double, cy: Double) -> SIMD3<Float> {
        SIMD3(Float(cx - CloudPose.refW / 2), Float(CloudPose.refH / 2 - cy), 0)
    }

    /// Stacking: the prototype paints lower-on-canvas cards in front
    /// (zIndex = 4 + cy/40). A small true-z offset reproduces that
    /// without visibly changing the perspective. Range ≈ ±20 units.
    static func stackingZ(cy: Double) -> Float {
        Float((cy / CloudPose.refH) * 40 - 20)
    }

    /// Vertical FOV (degrees) such that, with the camera at z = F looking
    /// at the origin, the stage height exactly fills the viewport.
    static var verticalFOV: Double {
        2 * atan((CloudPose.refH / 2) / CloudPose.f) * 180 / .pi
    }

    /// Horizontal FOV (degrees) for width-fit (window narrower than stage).
    static var horizontalFOV: Double {
        2 * atan((CloudPose.refW / 2) / CloudPose.f) * 180 / .pi
    }
}
```

- [ ] **Step 4 — run tests**

Run: `cd /Users/carlostarrats/Documents/Projects/Muse/Muse && xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/CloudMathTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`. If `testRotateY90MapsRightEdgeBackward` fails with v.z == +1, the CSS Ry sign convention is opposite — fix by negating ry in `orientation` AND update the test comment; verify visually against the prototype in Task 4 Step 5 before accepting either sign.

- [ ] **Step 5 — commit**

```bash
cd /Users/carlostarrats/Documents/Projects/Muse
git add Muse/Muse/Views/Spatial/CloudMath.swift Muse/MuseTests/CloudMathTests.swift
git commit -m "feat(spatial): CSS-to-SceneKit pose math with stage camera FOVs"
```

---

### Task 4: CloudView — SceneKit scene, letterboxed stage, shadows, thumbnails

No unit tests for SceneKit rendering; verification is a clean build now and a side-by-side visual check against the prototype after Task 6 wires the toolbar. Interactions (hover/drift/click) come in Task 5 — this task renders a static, correct-looking scene.

**Files:**
- Create: `Muse/Muse/Views/Spatial/CloudView.swift`

- [ ] **Step 1 — implement** (`Muse/Muse/Views/Spatial/CloudView.swift`):

```swift
//
//  CloudView.swift
//  Muse
//
//  Spec §3 cloud view: the current scope's images as true-3D tilted
//  cards on a fixed-aspect letterboxed stage, matching
//  docs/superpowers/assets/cloud-pose-prototype.html. One perspective
//  camera; scene units = reference-canvas pixels.
//

import SwiftUI
import SceneKit
import AppKit

struct CloudView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        GeometryReader { geo in
            CloudSceneRepresentable(
                files: imageFiles,
                onOpen: { file, localRect in
                    let origin = geo.frame(in: .global).origin
                    appState.tileFrames[file.url.path] =
                        localRect.offsetBy(dx: origin.x, dy: origin.y)
                    appState.selectedFile = file
                }
            )
            .overlay {
                if imageFiles.isEmpty { emptyState }
            }
        }
    }

    private var imageFiles: [FileNode] {
        appState.visibleFiles.filter {
            $0.kind == .image || $0.kind == .raw || $0.kind == .psd
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(Color(red: 0.45, green: 0.33, blue: 0.20).opacity(0.5))
            Text(appState.selectedFolder == nil ? "Select a folder" : "No images here")
                .font(.title3)
                .foregroundStyle(Color(red: 0.45, green: 0.33, blue: 0.20).opacity(0.7))
        }
    }
}

// MARK: - Representable

private struct CloudSceneRepresentable: NSViewRepresentable {
    let files: [FileNode]
    let onOpen: (FileNode, CGRect) -> Void

    func makeCoordinator() -> CloudSceneCoordinator { CloudSceneCoordinator() }

    func makeNSView(context: Context) -> CloudSCNView {
        let view = CloudSCNView()
        view.coordinator = context.coordinator
        view.backgroundColor = NSColor(red: 0.902, green: 0.812, blue: 0.710, alpha: 1) // #E6CFB5
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        view.allowsCameraControl = false
        context.coordinator.rebuildIfNeeded(files: files, in: view)
        return view
    }

    func updateNSView(_ nsView: CloudSCNView, context: Context) {
        context.coordinator.onOpen = onOpen
        context.coordinator.rebuildIfNeeded(files: files, in: nsView)
        nsView.updateProjection()
    }
}

// MARK: - Coordinator (scene graph owner)

@MainActor
final class CloudSceneCoordinator: NSObject {
    var onOpen: (FileNode, CGRect) -> Void = { _, _ in }

    /// pivot node (drift) -> card node (pose/hover). Parallel to `files`.
    private(set) var cardNodes: [SCNNode] = []
    private(set) var files: [FileNode] = []
    private var identity: String = "<unbuilt>"
    private var thumbnailTask: Task<Void, Never>?

    static let shadowImage: NSImage = makeShadowImage()

    func rebuildIfNeeded(files newFiles: [FileNode], in view: SCNView) {
        let newIdentity = newFiles.map(\.url.path).joined(separator: "|")
        guard newIdentity != identity else { return }
        identity = newIdentity
        thumbnailTask?.cancel()
        files = newFiles

        let scene = SCNScene()
        scene.background.contents = NSColor(red: 0.902, green: 0.812, blue: 0.710, alpha: 1)

        let camera = SCNCamera()
        camera.zNear = 50
        camera.zFar = 6000
        camera.fieldOfView = CloudMath.verticalFOV
        let camNode = SCNNode()
        camNode.camera = camera
        camNode.position = SCNVector3(0, 0, CloudPose.f)
        scene.rootNode.addChildNode(camNode)

        let seed = SeededRandom.fnv1a(newFiles.map(\.url.path))
        let poses = CloudLayout.poses(count: newFiles.count, seed: seed)
        var rng = SeededRandom(seed: seed &+ 1)

        cardNodes = []
        for (i, pose) in poses.enumerated() {
            let pivot = SCNNode()
            var p = CloudMath.position(cx: pose.cx, cy: pose.cy)
            p.z = CloudMath.stackingZ(cy: pose.cy)
            pivot.simdPosition = p
            pivot.runAction(Self.driftAction(rng: &rng), forKey: "drift")

            let card = SCNNode(geometry: Self.cardGeometry(w: pose.w, h: pose.h))
            card.simdOrientation = CloudMath.orientation(
                rxDeg: pose.rx, ryDeg: pose.ry, rzDeg: pose.rz)
            card.name = "card-\(i)"

            let shadow = SCNNode(geometry: Self.shadowGeometry(w: pose.w, h: pose.h))
            shadow.position = SCNVector3(10, -18, -6)   // CSS 10px right, 18px down
            shadow.renderingOrder = -1
            card.addChildNode(shadow)

            pivot.addChildNode(card)
            scene.rootNode.addChildNode(pivot)
            cardNodes.append(card)
        }

        view.scene = scene
        view.pointOfView = camNode
        loadThumbnails(poses: poses)
    }

    func file(forCardNode node: SCNNode) -> (FileNode, SCNNode)? {
        var n: SCNNode? = node
        while let current = n {
            if let name = current.name, name.hasPrefix("card-"),
               let i = Int(name.dropFirst(5)), i < files.count {
                return (files[i], current)
            }
            n = current.parent
        }
        return nil
    }

    private func loadThumbnails(poses: [CloudPose]) {
        let nodes = cardNodes
        let toLoad = files
        thumbnailTask = Task { @MainActor in
            for (i, file) in toLoad.enumerated() {
                if Task.isCancelled { return }
                guard i < nodes.count,
                      let plane = nodes[i].geometry as? SCNPlane else { continue }
                if let img = await ThumbnailCache.shared.thumbnail(
                    for: file.url, size: CGSize(width: 256, height: 256)
                ) {
                    Self.applyCover(image: img, to: plane)
                }
            }
        }
    }

    // MARK: geometry + materials

    private static func cardGeometry(w: Double, h: Double) -> SCNPlane {
        let plane = SCNPlane(width: w, height: h)
        let m = plane.firstMaterial!
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.diffuse.contents = NSColor(white: 0.92, alpha: 1)   // until thumbnail lands
        return plane
    }

    /// object-fit: cover — scale the texture so it fills the card and
    /// crop symmetrically via contentsTransform.
    static func applyCover(image: NSImage, to plane: SCNPlane) {
        let m = plane.firstMaterial!
        m.diffuse.contents = image
        let imgAspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        let cardAspect = plane.width / plane.height
        var sx: CGFloat = 1, sy: CGFloat = 1
        if imgAspect > cardAspect { sx = cardAspect / imgAspect } else { sy = imgAspect / cardAspect }
        m.diffuse.contentsTransform = SCNMatrix4Mult(
            SCNMatrix4MakeScale(sx, sy, 1),
            SCNMatrix4MakeTranslation((1 - sx) / 2, (1 - sy) / 2, 0))
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
    }

    private static func shadowGeometry(w: Double, h: Double) -> SCNPlane {
        let plane = SCNPlane(width: w * 1.5, height: h * 1.5)
        let m = plane.firstMaterial!
        m.lightingModel = .constant
        m.diffuse.contents = shadowImage
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        return plane
    }

    /// One shared soft warm radial shadow texture
    /// (prototype: box-shadow 10px 18px 34px rgba(95,65,35,.28)).
    private static func makeShadowImage() -> NSImage {
        let size = NSSize(width: 128, height: 128)
        let img = NSImage(size: size)
        img.lockFocus()
        let warm = NSColor(red: 95 / 255, green: 65 / 255, blue: 35 / 255, alpha: 0.28)
        let gradient = NSGradient(colors: [warm, warm.withAlphaComponent(0)])!
        gradient.draw(in: NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)),
                      relativeCenterPosition: .zero)
        img.unlockFocus()
        return img
    }

    /// Barely-there drift, a few px, unique phase per card (spec §3).
    private static func driftAction(rng: inout SeededRandom) -> SCNAction {
        let dx = CGFloat(Double.random(in: 1.5...3.5, using: &rng))
            * (Bool.random(using: &rng) ? 1 : -1)
        let dy = CGFloat(Double.random(in: 1.5...3.5, using: &rng))
            * (Bool.random(using: &rng) ? 1 : -1)
        let duration = Double.random(in: 2.6...4.4, using: &rng)
        let out = SCNAction.moveBy(x: dx, y: dy, z: 0, duration: duration)
        out.timingMode = .easeInEaseOut
        let back = SCNAction.moveBy(x: -dx, y: -dy, z: 0, duration: duration)
        back.timingMode = .easeInEaseOut
        return .repeatForever(.sequence([out, back]))
    }
}

// MARK: - SCNView subclass (letterboxing; input arrives in Task 5)

final class CloudSCNView: SCNView {
    weak var coordinator: CloudSceneCoordinator?

    override func layout() {
        super.layout()
        updateProjection()
    }

    /// Fixed-aspect stage, letterboxed (spec §3): fit the stage HEIGHT
    /// when the view is wider than the stage, fit the WIDTH when
    /// narrower. The beige background fills the spare space seamlessly.
    func updateProjection() {
        guard let cam = pointOfView?.camera, bounds.height > 0 else { return }
        let viewAspect = bounds.width / bounds.height
        let stageAspect = CGFloat(CloudPose.refW / CloudPose.refH)
        if viewAspect >= stageAspect {
            cam.projectionDirection = .vertical
            cam.fieldOfView = CloudMath.verticalFOV
        } else {
            cam.projectionDirection = .horizontal
            cam.fieldOfView = CloudMath.horizontalFOV
        }
    }
}
```

- [ ] **Step 2 — build**

Run: `cd /Users/carlostarrats/Documents/Projects/Muse/Muse && xcodebuild -scheme Muse build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. (CloudView isn't reachable from the UI yet — that's Task 6.)

- [ ] **Step 3 — commit**

```bash
cd /Users/carlostarrats/Documents/Projects/Muse
git add Muse/Muse/Views/Spatial/CloudView.swift
git commit -m "feat(spatial): cloud view SceneKit scene — letterboxed stage, warm shadows, cover-fit thumbnails, drift"
```

---

### Task 5: Cloud interactions — hover float, click → hero viewer, shared projection helper

**Files:**
- Create: `Muse/Muse/Views/Spatial/SceneProjection.swift`
- Modify: `Muse/Muse/Views/Spatial/CloudView.swift` (add input handling to `CloudSCNView` + hover/click methods to `CloudSceneCoordinator`)

- [ ] **Step 1 — create `Muse/Muse/Views/Spatial/SceneProjection.swift`** (shared by Cloud and Graph):

```swift
//
//  SceneProjection.swift
//  Muse
//
//  Projects a SceneKit plane node to its screen-space bounding rect in
//  TOP-LEFT-origin view coordinates (SwiftUI-style). Used to hand the
//  hero viewer its flight source rect via appState.tileFrames.
//

import SceneKit
import AppKit

@MainActor
enum SceneProjection {
    static func screenRect(of node: SCNNode, in view: SCNView) -> CGRect? {
        guard let plane = node.geometry as? SCNPlane else { return nil }
        let hw = plane.width / 2, hh = plane.height / 2
        let corners = [
            SCNVector3(-hw, -hh, 0), SCNVector3(hw, -hh, 0),
            SCNVector3(-hw, hh, 0), SCNVector3(hw, hh, 0),
        ]
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for c in corners {
            let world = node.convertPosition(c, to: nil)
            let p = view.projectPoint(world)
            minX = min(minX, CGFloat(p.x)); maxX = max(maxX, CGFloat(p.x))
            minY = min(minY, CGFloat(p.y)); maxY = max(maxY, CGFloat(p.y))
        }
        guard minX < maxX, minY < maxY else { return nil }
        // SCNView projectPoint y is bottom-left-origin; flip to top-left.
        let rect = CGRect(x: minX, y: view.bounds.height - maxY,
                          width: maxX - minX, height: maxY - minY)
        return rect.isNull || rect.isInfinite ? nil : rect
    }
}
```

- [ ] **Step 2 — add hover + click to `CloudSCNView`** (replace the existing `CloudSCNView` class at the bottom of `CloudView.swift` with):

```swift
// MARK: - SCNView subclass (letterboxing + hover + click)

final class CloudSCNView: SCNView {
    weak var coordinator: CloudSceneCoordinator?
    private var trackingArea: NSTrackingArea?
    private var mouseDownPoint: NSPoint?

    override func layout() {
        super.layout()
        updateProjection()
    }

    /// Fixed-aspect stage, letterboxed (spec §3): fit the stage HEIGHT
    /// when the view is wider than the stage, fit the WIDTH when
    /// narrower. The beige background fills the spare space seamlessly.
    func updateProjection() {
        guard let cam = pointOfView?.camera, bounds.height > 0 else { return }
        let viewAspect = bounds.width / bounds.height
        let stageAspect = CGFloat(CloudPose.refW / CloudPose.refH)
        if viewAspect >= stageAspect {
            cam.projectionDirection = .vertical
            cam.fieldOfView = CloudMath.verticalFOV
        } else {
            cam.projectionDirection = .horizontal
            cam.fieldOfView = CloudMath.horizontalFOV
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func cardHit(_ event: NSEvent) -> (FileNode, SCNNode)? {
        let point = convert(event.locationInWindow, from: nil)
        let hits = hitTest(point, options: [.searchMode: NSNumber(value: SCNHitTestSearchMode.all.rawValue)])
        for hit in hits {
            if let match = coordinator?.file(forCardNode: hit.node) { return match }
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        coordinator?.setHovered(cardHit(event)?.1)
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.setHovered(nil)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        let up = convert(event.locationInWindow, from: nil)
        if let down = mouseDownPoint, hypot(up.x - down.x, up.y - down.y) > 6 { return }
        guard let (file, node) = cardHit(event) else { return }
        let rect = SceneProjection.screenRect(of: node, in: self)
            ?? CGRect(x: bounds.midX - 80, y: bounds.midY - 80, width: 160, height: 160)
        coordinator?.onOpen(file, rect)
    }
}
```

- [ ] **Step 3 — add hover state to `CloudSceneCoordinator`** (insert inside the class, after `file(forCardNode:)`):

```swift
    // MARK: hover (prototype: flat + scale 1.15, .5s cubic-bezier(.25,.85,.3,1))

    private weak var hoveredCard: SCNNode?

    func setHovered(_ card: SCNNode?) {
        guard card !== hoveredCard else { return }
        let timing = CAMediaTimingFunction(controlPoints: 0.25, 0.85, 0.3, 1)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.5
        SCNTransaction.animationTimingFunction = timing
        if let old = hoveredCard, let i = cardNodes.firstIndex(where: { $0 === old }) {
            // restore measured pose
            let pose = poses.indices.contains(i) ? poses[i] : nil
            if let pose {
                old.simdOrientation = CloudMath.orientation(
                    rxDeg: pose.rx, ryDeg: pose.ry, rzDeg: pose.rz)
            }
            old.simdScale = SIMD3(1, 1, 1)
            old.simdPosition = SIMD3(0, 0, 0)
            old.parent?.runAction(Self.resumeDriftPlaceholder(), forKey: nil)
        }
        if let card {
            card.simdOrientation = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)) // flat
            card.simdScale = SIMD3(1.15, 1.15, 1.15)
            card.simdPosition = SIMD3(0, 0, 140)   // float up toward the camera
        }
        hoveredCard = card
        SCNTransaction.commit()
    }

    /// Drift keeps animating the PIVOT node; hover animates the CARD
    /// child, so they never fight. This no-op exists to make that
    /// invariant explicit at the call site.
    private static func resumeDriftPlaceholder() -> SCNAction { .wait(duration: 0) }
```

Also add a stored `private(set) var poses: [CloudPose] = []` property to the coordinator and set `self.poses = poses` in `rebuildIfNeeded` right after `let poses = CloudLayout.poses(...)` line (the hover-restore needs the original pose).

- [ ] **Step 4 — build**

Run: `cd /Users/carlostarrats/Documents/Projects/Muse/Muse && xcodebuild -scheme Muse build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5 — commit**

```bash
cd /Users/carlostarrats/Documents/Projects/Muse
git add Muse/Muse/Views/Spatial/SceneProjection.swift Muse/Muse/Views/Spatial/CloudView.swift
git commit -m "feat(spatial): cloud hover float + click-to-open via projected hero source rect"
```

---

### Task 6: Wire Grid / Cloud / Graph toggle; delete GlobeView + FibonacciSphere

GraphView lands here as a minimal real view (its final empty state + scope plumbing); the scene arrives in Tasks 10–11. After this task the app runs with a working Cloud view — do the prototype side-by-side check here.

**Files:**
- Modify: `Muse/Muse/Models/AppState.swift:75-76` (ViewMode enum), add `graphFocusedCollectionID`
- Modify: `Muse/Muse/ContentView.swift` (picker, switch, Esc chain)
- Create: `Muse/Muse/Views/Spatial/GraphView.swift` (minimal)
- Delete: `Muse/Muse/Views/GlobeView.swift`, `Muse/Muse/SceneKit/FibonacciSphere.swift`

- [ ] **Step 1 — AppState**: replace lines 74-76 (`/// Grid vs Globe...` through `@Published var viewMode...`) with:

```swift
    /// Grid / Cloud / Graph view mode for the active folder (spec §3).
    enum ViewMode: String { case grid, cloud, graph }
    @Published var viewMode: ViewMode = .grid

    /// Collection the graph view is zoomed into (nil = flat overview).
    @Published var graphFocusedCollectionID: String? = nil
```

- [ ] **Step 2 — ContentView**: replace the view-mode `switch` (lines 27-32) with:

```swift
                        switch appState.viewMode {
                        case .grid:
                            GridView()
                        case .cloud:
                            CloudView()
                        case .graph:
                            GraphView()
                        }
```

Replace the Picker body (lines 66-72) with:

```swift
                    Picker("View", selection: $appState.viewMode) {
                        Image(systemName: "square.grid.2x2").tag(AppState.ViewMode.grid)
                        Image(systemName: "cloud").tag(AppState.ViewMode.cloud)
                        Image(systemName: "point.3.connected.trianglepath.dotted").tag(AppState.ViewMode.graph)
                    }
                    .pickerStyle(.segmented)
                    .help("Switch between grid, cloud, and graph views")
```

Extend the hidden Esc button's action (lines 167-178): after the hero/selectedFile branches, add a graph-unfocus branch so Esc order is overlay → viewer → graph zoom-out:

```swift
            Button(action: {
                if appState.collectionsOverlayVisible {
                    appState.collectionsOverlayVisible = false
                } else if let selected = appState.selectedFile,
                          selected.kind == .image || selected.kind == .raw
                            || selected.kind == .psd {
                    // Hero viewer: run the return flight instead of popping.
                    appState.viewerClosing = true
                } else if appState.selectedFile != nil {
                    appState.selectedFile = nil
                } else if appState.graphFocusedCollectionID != nil {
                    appState.graphFocusedCollectionID = nil
                }
            }) { EmptyView() }
```

- [ ] **Step 3 — minimal `Muse/Muse/Views/Spatial/GraphView.swift`** (real file, final empty state; the SceneKit body replaces the `content` placeholder in Task 10):

```swift
//
//  GraphView.swift
//  Muse
//
//  Spec §3 graph view (replaces GlobeView): zoomed out, collections as
//  labeled thumbnail clusters on a flat plane with shared-tag lines;
//  zooming into a cluster spreads its images in 3D by visual similarity.
//

import SwiftUI
import SceneKit
import AppKit

struct GraphView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var engine = CollectionsEngine.shared

    var body: some View {
        ZStack {
            Color(red: 0.066, green: 0.066, blue: 0.078).ignoresSafeArea() // Ink
            if engine.collections.isEmpty {
                emptyState
            } else {
                Text("Graph loading…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No collections yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Run Analyze (✨) on a folder of images to build collections.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 4 — delete the globe**:

```bash
cd /Users/carlostarrats/Documents/Projects/Muse
git rm Muse/Muse/Views/GlobeView.swift Muse/Muse/SceneKit/FibonacciSphere.swift
rmdir Muse/Muse/SceneKit
```

- [ ] **Step 5 — build + full test suite** (deleting files can break stale references):

Run: `cd /Users/carlostarrats/Documents/Projects/Muse/Muse && xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6 — visual verification against the prototype (REQUIRED, spec hard requirement)**

1. `open /Users/carlostarrats/Documents/Projects/Muse/docs/superpowers/assets/cloud-pose-prototype.html` in a browser sized ~1500×900.
2. Build & run Muse (Cmd+R in Xcode or `xcodebuild ... build` + open the app), point it at a folder with ≥25 images, switch to Cloud.
3. Compare card-by-card for the first few cards: card 0 (top-left) must lean the SAME direction in both (strong clockwise-on-screen rz tilt, top-left corner nearest the viewer). If any axis is mirrored, revisit the sign notes in CloudMath (Task 3 Step 4) — fix the sign, re-run CloudMathTests (updating the affected test + comment), and re-compare. Also confirm: beige background, soft warm down-right shadows, gentle drift, hover floats the card flat and forward, click flies the image into the hero viewer FROM the card's position, stage letterboxes (resize the window both ways; composition must never distort).

- [ ] **Step 7 — commit**

```bash
cd /Users/carlostarrats/Documents/Projects/Muse
git add -A
git commit -m "feat(spatial): grid/cloud/graph toggle; retire GlobeView + FibonacciSphere"
```

---

### Task 7: GraphLayout — deterministic 2D force-directed cluster layout

**Files:**
- Create: `Muse/Muse/Views/Spatial/GraphLayout.swift`
- Test: `Muse/MuseTests/GraphLayoutTests.swift`

- [ ] **Step 1 — failing tests** (`Muse/MuseTests/GraphLayoutTests.swift`):

```swift
import XCTest
import simd
@testable import Muse

final class GraphLayoutTests: XCTestCase {
    func testEmptyAndSingle() {
        XCTAssertTrue(GraphLayout.positions(nodeCount: 0, edges: []).isEmpty)
        XCTAssertEqual(GraphLayout.positions(nodeCount: 1, edges: []), [SIMD2(0, 0)])
    }

    func testDeterministic() {
        let e = [GraphEdge(a: 0, b: 1, sharedTags: 2)]
        let p1 = GraphLayout.positions(nodeCount: 4, edges: e)
        let p2 = GraphLayout.positions(nodeCount: 4, edges: e)
        XCTAssertEqual(p1, p2)
    }

    func testConnectedNodesEndUpCloserThanUnconnected() {
        // 0-1 share tags; 2 floats free.
        let p = GraphLayout.positions(nodeCount: 3,
                                      edges: [GraphEdge(a: 0, b: 1, sharedTags: 3)])
        let d01 = simd_length(p[0] - p[1])
        let d02 = simd_length(p[0] - p[2])
        let d12 = simd_length(p[1] - p[2])
        XCTAssertLessThan(d01, d02)
        XCTAssertLessThan(d01, d12)
    }

    func testOutputIsFiniteAndNormalized() {
        let edges = [GraphEdge(a: 0, b: 1, sharedTags: 1),
                     GraphEdge(a: 1, b: 2, sharedTags: 4),
                     GraphEdge(a: 0, b: 5, sharedTags: 2)]
        let p = GraphLayout.positions(nodeCount: 8, edges: edges)
        XCTAssertEqual(p.count, 8)
        for v in p {
            XCTAssertTrue(v.x.isFinite && v.y.isFinite)
            XCTAssertTrue(abs(v.x) <= 1.0001 && abs(v.y) <= 1.0001)
        }
    }

    func testCoincidentStartDoesNotNaN() {
        // nodeCount 2 starts at opposite circle points, but exercise the
        // degenerate guard with many nodes + strong springs anyway.
        let edges = (1..<6).map { GraphEdge(a: 0, b: $0, sharedTags: 4) }
        let p = GraphLayout.positions(nodeCount: 6, edges: edges)
        for v in p { XCTAssertTrue(v.x.isFinite && v.y.isFinite) }
    }
}
```

- [ ] **Step 2 — run to verify failure**

Run: `cd /Users/carlostarrats/Documents/Projects/Muse/Muse && xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/GraphLayoutTests 2>&1 | tail -20`
Expected: build FAILS with "cannot find 'GraphLayout' in scope".

- [ ] **Step 3 — implement** (`Muse/Muse/Views/Spatial/GraphLayout.swift`):

```swift
//
//  GraphLayout.swift
//  Muse
//
//  Deterministic force-directed layout for the graph view's flat
//  overview: collections repel; shared-tag edges pull them together
//  (more shared tags -> shorter ideal length). Seeded by index order,
//  no RNG, fixed iterations -> identical output for identical input.
//

import Foundation
import simd

struct GraphEdge: Equatable {
    let a: Int
    let b: Int
    let sharedTags: Int
}

enum GraphLayout {
    /// Unit-space positions (max |coord| == 1 after normalization).
    static func positions(nodeCount: Int, edges: [GraphEdge],
                          iterations: Int = 250) -> [SIMD2<Double>] {
        guard nodeCount > 0 else { return [] }
        guard nodeCount > 1 else { return [SIMD2(0, 0)] }

        // Deterministic start: evenly spaced on a circle.
        var pos: [SIMD2<Double>] = (0..<nodeCount).map { i in
            let a = Double(i) / Double(nodeCount) * 2 * .pi
            return SIMD2(cos(a), sin(a))
        }

        let repulsion = 0.08
        for it in 0..<iterations {
            let step = 0.05 * (1 - Double(it) / Double(iterations))
            var force = [SIMD2<Double>](repeating: .zero, count: nodeCount)
            for i in 0..<nodeCount {
                for j in (i + 1)..<nodeCount {
                    var d = pos[i] - pos[j]
                    var len = simd_length(d)
                    if len < 1e-6 {
                        d = SIMD2(1e-3 * Double(i + 1), 1e-3)
                        len = simd_length(d)
                    }
                    let f = d / len * (repulsion / (len * len))
                    force[i] += f
                    force[j] -= f
                }
            }
            for e in edges where e.a < nodeCount && e.b < nodeCount && e.a != e.b {
                let d = pos[e.b] - pos[e.a]
                let len = max(simd_length(d), 1e-6)
                let ideal = 0.6 / (1 + 0.35 * Double(min(e.sharedTags, 4)))
                let f = d / len * (len - ideal) * 0.5
                force[e.a] += f
                force[e.b] -= f
            }
            for i in 0..<nodeCount {
                let l = simd_length(force[i])
                let capped = l > 0.2 ? force[i] / l * 0.2 : force[i]
                pos[i] += capped * step
            }
        }

        // Center, then normalize the longest axis to 1.
        let centroid = pos.reduce(SIMD2<Double>(), +) / Double(nodeCount)
        pos = pos.map { $0 - centroid }
        let maxAbs = pos.flatMap { [abs($0.x), abs($0.y)] }.max() ?? 1
        if maxAbs > 0 { pos = pos.map { $0 / maxAbs } }
        return pos
    }
}
```

- [ ] **Step 4 — run tests**

Run: `cd /Users/carlostarrats/Documents/Projects/Muse/Muse && xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/GraphLayoutTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5 — commit**

```bash
cd /Users/carlostarrats/Documents/Projects/Muse
git add Muse/Muse/Views/Spatial/GraphLayout.swift Muse/MuseTests/GraphLayoutTests.swift
git commit -m "feat(spatial): deterministic 2D force layout for graph overview"
```

---

### Task 8: SimilarityLayout — 3D stress layout from a distance matrix

**Files:**
- Create: `Muse/Muse/Views/Spatial/SimilarityLayout.swift`
- Test: `Muse/MuseTests/SimilarityLayoutTests.swift`

- [ ] **Step 1 — failing tests** (`Muse/MuseTests/SimilarityLayoutTests.swift`):

```swift
import XCTest
import simd
@testable import Muse

final class SimilarityLayoutTests: XCTestCase {
    func testDegenerateCounts() {
        XCTAssertTrue(SimilarityLayout.positions(distances: [], seed: 1).isEmpty)
        XCTAssertEqual(SimilarityLayout.positions(distances: [[0]], seed: 1),
                       [SIMD3(0, 0, 0)])
        let two = SimilarityLayout.positions(distances: [[0, 1], [1, 0]], seed: 1)
        XCTAssertEqual(two.count, 2)
        for v in two { XCTAssertTrue(v.x.isFinite && v.y.isFinite && v.z.isFinite) }
    }

    func testDeterministicPerSeed() {
        let d: [[Float]] = [[0, 0.5, 1], [0.5, 0, 0.7], [1, 0.7, 0]]
        XCTAssertEqual(SimilarityLayout.positions(distances: d, seed: 3),
                       SimilarityLayout.positions(distances: d, seed: 3))
        XCTAssertNotEqual(SimilarityLayout.positions(distances: d, seed: 3),
                          SimilarityLayout.positions(distances: d, seed: 4))
    }

    func testSimilarPairEndsCloserThanDissimilar() {
        // 0 and 1 are near-identical; 2 is far from both.
        let d: [[Float]] = [[0, 0.05, 1.0],
                            [0.05, 0, 1.0],
                            [1.0, 1.0, 0]]
        let p = SimilarityLayout.positions(distances: d, seed: 7)
        let d01 = simd_length(p[0] - p[1])
        let d02 = simd_length(p[0] - p[2])
        XCTAssertLessThan(d01, d02 * 0.5)
    }

    func testAllZeroDistancesStayFinite() {
        let d = [[Float]](repeating: [Float](repeating: 0, count: 5), count: 5)
        let p = SimilarityLayout.positions(distances: d, seed: 2)
        for v in p { XCTAssertTrue(v.x.isFinite && v.y.isFinite && v.z.isFinite) }
    }

    func testNormalizedToUnitRadius() {
        let d: [[Float]] = [[0, 2, 3], [2, 0, 4], [3, 4, 0]]
        let p = SimilarityLayout.positions(distances: d, seed: 9)
        XCTAssertEqual(p.map(simd_length).max() ?? 0, 1.0, accuracy: 1e-6)
    }
}
```

- [ ] **Step 2 — run to verify failure**

Run: `cd /Users/carlostarrats/Documents/Projects/Muse/Muse && xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/SimilarityLayoutTests 2>&1 | tail -20`
Expected: build FAILS with "cannot find 'SimilarityLayout' in scope".

- [ ] **Step 3 — implement** (`Muse/Muse/Views/Spatial/SimilarityLayout.swift`):

```swift
//
//  SimilarityLayout.swift
//  Muse
//
//  Spec §3 graph zoom-in: spread a cluster's images in 3D positioned by
//  visual similarity (feature-print distance). Simple iterative stress
//  relaxation over the pairwise distance matrix — deterministic per
//  seed, output centered and normalized to unit radius.
//

import Foundation
import simd

enum SimilarityLayout {
    static func positions(distances: [[Float]], seed: UInt64,
                          iterations: Int = 200) -> [SIMD3<Double>] {
        let n = distances.count
        guard n > 0 else { return [] }
        guard n > 1 else { return [SIMD3(0, 0, 0)] }

        var rng = SeededRandom(seed: seed)
        var pos: [SIMD3<Double>] = (0..<n).map { _ in
            SIMD3(Double.random(in: -1...1, using: &rng),
                  Double.random(in: -1...1, using: &rng),
                  Double.random(in: -1...1, using: &rng))
        }

        // Normalize target distances to mean 1 (scale-free input).
        var sum = 0.0
        var count = 0
        for i in 0..<n {
            for j in (i + 1)..<n {
                sum += Double(distances[i][j])
                count += 1
            }
        }
        let mean = (count > 0 && sum > 0) ? sum / Double(count) : 1

        for it in 0..<iterations {
            let step = 0.12 * (1 - Double(it) / Double(iterations))
            for i in 0..<n {
                for j in (i + 1)..<n {
                    let target = Double(distances[i][j]) / mean
                    var d = pos[i] - pos[j]
                    var len = simd_length(d)
                    if len < 1e-9 {
                        d = SIMD3(1e-3, 0, 0)
                        len = 1e-3
                    }
                    let delta = (len - target) / len * step * 0.5
                    pos[i] -= d * delta
                    pos[j] += d * delta
                }
            }
        }

        let centroid = pos.reduce(SIMD3<Double>(), +) / Double(n)
        pos = pos.map { $0 - centroid }
        let maxLen = pos.map(simd_length).max() ?? 1
        if maxLen > 0 { pos = pos.map { $0 / maxLen } }
        return pos
    }
}
```

- [ ] **Step 4 — run tests**

Run: `cd /Users/carlostarrats/Documents/Projects/Muse/Muse && xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/SimilarityLayoutTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5 — commit**

```bash
cd /Users/carlostarrats/Documents/Projects/Muse
git add Muse/Muse/Views/Spatial/SimilarityLayout.swift Muse/MuseTests/SimilarityLayoutTests.swift
git commit -m "feat(spatial): 3D similarity stress layout for graph cluster zoom"
```

---

### Task 9: GraphModel — clusters in scope, shared-tag edges, feature-print distances

**Files:**
- Create: `Muse/Muse/Views/Spatial/GraphModel.swift`
- Test: `Muse/MuseTests/GraphModelTests.swift`

- [ ] **Step 1 — failing tests** (`Muse/MuseTests/GraphModelTests.swift`):

```swift
import XCTest
import GRDB
@testable import Muse

final class GraphModelTests: XCTestCase {
    /// files f1..f5 with paths /p/f<n>.png; collections c1{f1,f2},
    /// c2{f2,f3}, c3{f4}; tags: c1 files {dog,park}, c2 files {park,tree},
    /// c3 file {car}; f5 in no collection.
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            for n in 1...5 {
                try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES (?, 'image', 0)",
                               arguments: ["f\(n)"])
                try db.execute(sql: """
                    INSERT INTO paths (id, file_id, absolute_path, is_alive)
                    VALUES (?, ?, ?, 1)
                    """, arguments: ["p\(n)", "f\(n)", "/p/f\(n).png"])
            }
            let now: Int64 = 0
            for (cid, name) in [("c1", "Dogs"), ("c2", "Parks"), ("c3", "Cars")] {
                try db.execute(sql: """
                    INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at)
                    VALUES (?, ?, 0, 't', ?, ?)
                    """, arguments: [cid, name, now, now])
            }
            for (cid, fid) in [("c1", "f1"), ("c1", "f2"), ("c2", "f2"), ("c2", "f3"), ("c3", "f4")] {
                try db.execute(sql: """
                    INSERT INTO collection_members (collection_id, file_id, added_by)
                    VALUES (?, ?, 'auto')
                    """, arguments: [cid, fid])
            }
            let tags: [(String, String)] = [
                ("f1", "dog"), ("f1", "park"), ("f2", "dog"), ("f2", "park"),
                ("f3", "park"), ("f3", "tree"), ("f4", "car"),
            ]
            for (i, t) in tags.enumerated() {
                try db.execute(sql: """
                    INSERT INTO tags (id, file_id, label, source) VALUES (?, ?, ?, 'vision')
                    """, arguments: ["t\(i)", t.0, t.1])
            }
        }
        return q
    }

    func testBuildFiltersToScopeAndComputesEdges() async throws {
        let q = try makeQueue()
        let scope = ["/p/f1.png", "/p/f2.png", "/p/f3.png", "/p/f4.png", "/p/f5.png"]
        let data = try await GraphModel.build(queue: q, scopePaths: scope)
        XCTAssertEqual(data.clusters.count, 3)
        let byName = Dictionary(uniqueKeysWithValues: data.clusters.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName["Dogs"]!.memberPaths), ["/p/f1.png", "/p/f2.png"])
        XCTAssertEqual(Set(byName["Parks"]!.memberPaths), ["/p/f2.png", "/p/f3.png"])
        // Dogs and Parks share the "park" (and "dog" via f2) tags -> edge.
        // Cars shares nothing -> no edge to it.
        XCTAssertEqual(data.edges.count, 1)
        let e = data.edges[0]
        let names = Set([data.clusters[e.a].name, data.clusters[e.b].name])
        XCTAssertEqual(names, ["Dogs", "Parks"])
        XCTAssertGreaterThanOrEqual(e.sharedTags, 1)
    }

    func testScopeNarrowsClusters() async throws {
        let q = try makeQueue()
        // Only f4 in scope: just the Cars cluster survives.
        let data = try await GraphModel.build(queue: q, scopePaths: ["/p/f4.png"])
        XCTAssertEqual(data.clusters.map(\.name), ["Cars"])
        XCTAssertTrue(data.edges.isEmpty)
    }

    func testEmptyScope() async throws {
        let q = try makeQueue()
        let data = try await GraphModel.build(queue: q, scopePaths: [])
        XCTAssertTrue(data.clusters.isEmpty)
        XCTAssertTrue(data.edges.isEmpty)
    }

    func testSharedTagEdgesPure() {
        let edges = GraphModel.sharedTagEdges(tagsByCluster: [
            ["a", "b", "c"], ["b", "c", "d"], ["x"],
        ])
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges[0].a, 0)
        XCTAssertEqual(edges[0].b, 1)
        XCTAssertEqual(edges[0].sharedTags, 2)
    }

    func testDistanceMatrixHandlesNilPrints() {
        let m = GraphModel.distanceMatrix(prints: [nil, nil, nil])
        XCTAssertEqual(m.count, 3)
        XCTAssertEqual(m[0][0], 0)
        XCTAssertEqual(m[0][1], 1.0)   // unknown pairs get neutral distance
        XCTAssertEqual(m[1][2], 1.0)
    }
}
```

- [ ] **Step 2 — run to verify failure**

Run: `cd /Users/carlostarrats/Documents/Projects/Muse/Muse && xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/GraphModelTests 2>&1 | tail -20`
Expected: build FAILS with "cannot find 'GraphModel' in scope".

- [ ] **Step 3 — implement** (`Muse/Muse/Views/Spatial/GraphModel.swift`):

```swift
//
//  GraphModel.swift
//  Muse
//
//  Data assembly for the graph view. Membership = collections (hybrid
//  rule from spec §3); only members inside the current scope (folder /
//  collection filter / search results) are shown. Edges connect
//  collections sharing tags. Distances for the 3D spread come from the
//  stored Vision feature prints.
//

import Foundation
import GRDB
import Vision

struct GraphCluster: Identifiable, Equatable {
    let id: String            // collection id
    let name: String
    let memberPaths: [String] // alive + in scope, stable DB order
    let memberFileIDs: [String]
    let topTags: Set<String>
}

struct GraphData: Equatable {
    var clusters: [GraphCluster]
    var edges: [GraphEdge]     // indices into `clusters`
}

enum GraphModel {
    /// Build the overview model for the given in-scope absolute paths.
    static func build(queue: DatabaseQueue, scopePaths: [String]) async throws -> GraphData {
        guard !scopePaths.isEmpty else { return GraphData(clusters: [], edges: []) }
        let clusters: [GraphCluster] = try await queue.read { db in
            // scope path -> file id (chunked IN to stay under SQLite limits)
            var pathByFileID: [String: String] = [:]
            for chunk in stride(from: 0, to: scopePaths.count, by: 500).map({
                Array(scopePaths[$0..<min($0 + 500, scopePaths.count)])
            }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT file_id, absolute_path FROM paths
                    WHERE is_alive = 1 AND file_id IS NOT NULL
                      AND absolute_path IN (\(marks))
                    """, arguments: StatementArguments(chunk))
                for r in rows { pathByFileID[r["file_id"]] = r["absolute_path"] }
            }
            guard !pathByFileID.isEmpty else { return [] }

            let collectionRows = try CollectionRow
                .filter(Column("is_hidden") == 0)
                .fetchAll(db)
            var out: [GraphCluster] = []
            for c in collectionRows {
                let memberIDs = try String.fetchAll(db, sql: """
                    SELECT file_id FROM collection_members WHERE collection_id = ?
                    """, arguments: [c.id])
                let inScope = memberIDs.filter { pathByFileID[$0] != nil }
                guard !inScope.isEmpty else { continue }
                let marks = inScope.map { _ in "?" }.joined(separator: ",")
                let tags = try String.fetchAll(db, sql: """
                    SELECT label FROM tags
                    WHERE file_id IN (\(marks)) AND source != 'vision-color'
                    GROUP BY label ORDER BY COUNT(*) DESC LIMIT 10
                    """, arguments: StatementArguments(inScope))
                out.append(GraphCluster(
                    id: c.id, name: c.name,
                    memberPaths: inScope.compactMap { pathByFileID[$0] },
                    memberFileIDs: inScope,
                    topTags: Set(tags)))
            }
            // Biggest clusters first, ties by name for stable layouts.
            return out.sorted {
                ($0.memberPaths.count, $1.name) > ($1.memberPaths.count, $0.name)
            }
        }
        return GraphData(clusters: clusters,
                         edges: sharedTagEdges(tagsByCluster: clusters.map(\.topTags)))
    }

    /// One edge per cluster pair with ≥1 shared top tag.
    static func sharedTagEdges(tagsByCluster: [Set<String>]) -> [GraphEdge] {
        var edges: [GraphEdge] = []
        for i in 0..<tagsByCluster.count {
            for j in (i + 1)..<tagsByCluster.count {
                let shared = tagsByCluster[i].intersection(tagsByCluster[j]).count
                if shared >= 1 {
                    edges.append(GraphEdge(a: i, b: j, sharedTags: shared))
                }
            }
        }
        return edges
    }

    /// Stored feature prints for the given file ids (id -> archived print).
    static func featurePrints(queue: DatabaseQueue, fileIDs: [String]) async throws -> [String: Data] {
        try await queue.read { db in
            guard !fileIDs.isEmpty else { return [:] }
            var out: [String: Data] = [:]
            for chunk in stride(from: 0, to: fileIDs.count, by: 500).map({
                Array(fileIDs[$0..<min($0 + 500, fileIDs.count)])
            }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, feature_print FROM files
                    WHERE id IN (\(marks)) AND feature_print IS NOT NULL
                    """, arguments: StatementArguments(chunk))
                for r in rows { out[r["id"]] = r["feature_print"] }
            }
            return out
        }
    }

    /// Symmetric pairwise distance matrix. Pairs lacking a print get a
    /// neutral 1.0 (typical Vision print distances are ~0–2). CPU-bound:
    /// call off the main actor (Task.detached) for big clusters.
    static func distanceMatrix(prints: [Data?]) -> [[Float]] {
        let n = prints.count
        var matrix = [[Float]](repeating: [Float](repeating: 1.0, count: n), count: n)
        let observations: [VNFeaturePrintObservation?] = prints.map { data in
            guard let data else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self, from: data)
        }
        for i in 0..<n {
            matrix[i][i] = 0
            guard let a = observations[i] else { continue }
            for j in (i + 1)..<n {
                guard let b = observations[j] else { continue }
                var distance: Float = 1.0
                if (try? a.computeDistance(&distance, to: b)) != nil {
                    matrix[i][j] = distance
                    matrix[j][i] = distance
                }
            }
        }
        return matrix
    }
}
```

- [ ] **Step 4 — run tests**

Run: `cd /Users/carlostarrats/Documents/Projects/Muse/Muse && xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/GraphModelTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5 — commit**

```bash
cd /Users/carlostarrats/Documents/Projects/Muse
git add Muse/Muse/Views/Spatial/GraphModel.swift Muse/MuseTests/GraphModelTests.swift
git commit -m "feat(spatial): graph data assembly — scoped clusters, shared-tag edges, print distances"
```

---

### Task 10: GraphView — flat overview scene (clusters, labels, edge lines) + camera focus

Replaces the Task 6 placeholder body. After this task: the overview renders and clicking a cluster flies the camera in / clicking empty space (or Esc) flies back. The 3D similarity spread and image-click-to-viewer land in Task 11.

**Files:**
- Modify: `Muse/Muse/Views/Spatial/GraphView.swift` (full rewrite below)

- [ ] **Step 1 — rewrite `GraphView.swift`**:

```swift
//
//  GraphView.swift
//  Muse
//
//  Spec §3 graph view (replaces GlobeView). Zoomed out: flat 2D —
//  collections as labeled thumbnail clusters, lines between collections
//  sharing tags. Zooming into a cluster transitions to 3D: images
//  spread by visual similarity (Task 11). One perspective camera,
//  straight-on, so the overview reads flat.
//

import SwiftUI
import SceneKit
import AppKit

struct GraphView: View {
    @EnvironmentObject var appState: AppState
    @State private var data: GraphData?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(red: 0.066, green: 0.066, blue: 0.078).ignoresSafeArea() // Ink
                if let data, !data.clusters.isEmpty {
                    GraphSceneRepresentable(
                        data: data,
                        focusedID: appState.graphFocusedCollectionID,
                        onFocus: { id in appState.graphFocusedCollectionID = id },
                        onOpen: { path, localRect in
                            guard let file = fileByPath[path] else { return }
                            let origin = geo.frame(in: .global).origin
                            appState.tileFrames[file.url.path] =
                                localRect.offsetBy(dx: origin.x, dy: origin.y)
                            appState.selectedFile = file
                        }
                    )
                } else if data != nil {
                    emptyState
                } else {
                    ProgressView().controlSize(.large)
                }
            }
        }
        .task(id: scopeIdentity) {
            appState.graphFocusedCollectionID = nil
            await rebuild()
        }
        .onDisappear { appState.graphFocusedCollectionID = nil }
    }

    private var imageFiles: [FileNode] {
        appState.visibleFiles.filter {
            $0.kind == .image || $0.kind == .raw || $0.kind == .psd
        }
    }

    private var fileByPath: [String: FileNode] {
        Dictionary(imageFiles.map { ($0.url.standardizedFileURL.path, $0) },
                   uniquingKeysWith: { a, _ in a })
    }

    private var scopeIdentity: String {
        imageFiles.map(\.url.path).joined(separator: "|")
    }

    private func rebuild() async {
        guard let q = Database.shared.dbQueue else {
            data = GraphData(clusters: [], edges: [])
            return
        }
        let paths = imageFiles.map { $0.url.standardizedFileURL.path }
        data = (try? await GraphModel.build(queue: q, scopePaths: paths))
            ?? GraphData(clusters: [], edges: [])
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No collections yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Run Analyze (✨) on a folder of images to build collections.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Representable

private struct GraphSceneRepresentable: NSViewRepresentable {
    let data: GraphData
    let focusedID: String?
    let onFocus: (String?) -> Void
    let onOpen: (String, CGRect) -> Void

    func makeCoordinator() -> GraphSceneCoordinator { GraphSceneCoordinator() }

    func makeNSView(context: Context) -> GraphSCNView {
        let view = GraphSCNView()
        view.coordinator = context.coordinator
        view.backgroundColor = NSColor(red: 0.066, green: 0.066, blue: 0.078, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        view.allowsCameraControl = false
        context.coordinator.rebuildIfNeeded(data: data, in: view)
        return view
    }

    func updateNSView(_ nsView: GraphSCNView, context: Context) {
        context.coordinator.onFocus = onFocus
        context.coordinator.onOpen = onOpen
        context.coordinator.rebuildIfNeeded(data: data, in: nsView)
        context.coordinator.setFocus(focusedID, in: nsView)
    }
}

// MARK: - Coordinator

@MainActor
final class GraphSceneCoordinator: NSObject {
    var onFocus: (String?) -> Void = { _ in }
    var onOpen: (String, CGRect) -> Void = { _, _ in }

    static let worldSpread: Double = 700      // layout unit -> world units
    static let overviewCameraZ: Double = 1750
    static let focusCameraZ: Double = 950
    static let spreadRadius: Double = 380     // 3D spread (Task 11)
    static let heapVisibleCount = 7

    private(set) var data = GraphData(clusters: [], edges: [])
    private var identity = "<unbuilt>"
    private var clusterNodes: [SCNNode] = []          // parallel to data.clusters
    private var memberNodes: [[SCNNode]] = []         // [cluster][member]
    private var heapTransforms: [[(SIMD3<Float>, simd_quatf, Float)]] = [] // pos, rot, opacity
    private var labelNodes: [SCNNode] = []
    private var edgesNode = SCNNode()
    private var cameraNode = SCNNode()
    private(set) var focusedID: String?
    private var thumbnailTask: Task<Void, Never>?

    func rebuildIfNeeded(data newData: GraphData, in view: SCNView) {
        let newIdentity = newData.clusters.map { "\($0.id):\($0.memberPaths.count)" }
            .joined(separator: "|") + "#\(newData.edges.count)"
        guard newIdentity != identity else { return }
        identity = newIdentity
        thumbnailTask?.cancel()
        data = newData
        focusedID = nil

        let scene = SCNScene()
        scene.background.contents = NSColor(red: 0.066, green: 0.066, blue: 0.078, alpha: 1)

        let camera = SCNCamera()
        camera.zNear = 10
        camera.zFar = 8000
        camera.fieldOfView = 50
        cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, Self.overviewCameraZ)
        scene.rootNode.addChildNode(cameraNode)

        let layout = GraphLayout.positions(
            nodeCount: data.clusters.count,
            edges: data.edges)
        let worldPositions: [SIMD3<Float>] = layout.map {
            SIMD3(Float($0.x * Self.worldSpread), Float($0.y * Self.worldSpread * 0.62), 0)
        }

        // Edge lines (under the clusters).
        edgesNode = SCNNode()
        for e in data.edges {
            edgesNode.addChildNode(Self.lineNode(
                from: worldPositions[e.a], to: worldPositions[e.b],
                alpha: 0.18 + 0.07 * CGFloat(min(e.sharedTags, 4))))
        }
        scene.rootNode.addChildNode(edgesNode)

        clusterNodes = []
        memberNodes = []
        heapTransforms = []
        labelNodes = []
        for (ci, cluster) in data.clusters.enumerated() {
            let group = SCNNode()
            group.simdPosition = worldPositions[ci] + SIMD3(0, 0, 2)
            group.name = "cluster-\(ci)"
            var rng = SeededRandom(seed: SeededRandom.fnv1a([cluster.id]))
            var nodes: [SCNNode] = []
            var transforms: [(SIMD3<Float>, simd_quatf, Float)] = []
            for (mi, _) in cluster.memberPaths.enumerated() {
                let plane = SCNPlane(width: mi == 0 ? 110 : 80,
                                     height: mi == 0 ? 110 : 80)
                let m = plane.firstMaterial!
                m.lightingModel = .constant
                m.diffuse.contents = NSColor(white: 0.22, alpha: 1)
                m.isDoubleSided = true
                let node = SCNNode(geometry: plane)
                node.name = "member-\(ci)-\(mi)"
                let t = Self.heapTransform(memberIndex: mi, rng: &rng)
                node.simdPosition = t.0
                node.simdOrientation = t.1
                node.opacity = CGFloat(t.2)
                group.addChildNode(node)
                nodes.append(node)
                transforms.append(t)
            }
            let label = Self.labelNode(
                text: "\(cluster.name)  ·  \(cluster.memberPaths.count)")
            label.position = SCNVector3(0, -120, 4)
            group.addChildNode(label)
            labelNodes.append(label)

            scene.rootNode.addChildNode(group)
            clusterNodes.append(group)
            memberNodes.append(nodes)
            heapTransforms.append(transforms)
        }

        view.scene = scene
        view.pointOfView = cameraNode
        loadOverviewThumbnails()
    }

    /// Collage heap: first member large at the center, the next six in a
    /// loose ring with slight in-plane tilts; the rest hidden until the
    /// cluster is focused.
    private static func heapTransform(memberIndex mi: Int,
                                      rng: inout SeededRandom) -> (SIMD3<Float>, simd_quatf, Float) {
        let tilt = Float(Double.random(in: -8...8, using: &rng)) * .pi / 180
        let rot = simd_quatf(angle: tilt, axis: SIMD3(0, 0, 1))
        if mi == 0 { return (SIMD3(0, 0, 1), rot, 1) }
        if mi < heapVisibleCount {
            let angle = Double(mi - 1) / 6 * 2 * .pi + Double.random(in: -0.2...0.2, using: &rng)
            let radius = Double.random(in: 58...74, using: &rng)
            return (SIMD3(Float(cos(angle) * radius), Float(sin(angle) * radius),
                          Float(mi) * 0.5), rot, 1)
        }
        return (SIMD3(0, 0, 0), rot, 0)   // hidden until focus
    }

    private static func lineNode(from a: SIMD3<Float>, to b: SIMD3<Float>,
                                 alpha: CGFloat) -> SCNNode {
        let source = SCNGeometrySource(vertices: [SCNVector3(a), SCNVector3(b)])
        let element = SCNGeometryElement(indices: [Int32(0), Int32(1)],
                                         primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.firstMaterial?.lightingModel = .constant
        geometry.firstMaterial?.diffuse.contents = NSColor(white: 1, alpha: alpha)
        return SCNNode(geometry: geometry)
    }

    private static func labelNode(text: String) -> SCNNode {
        let font = NSFont.systemFont(ofSize: 28, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(white: 1, alpha: 0.85),
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let imageSize = NSSize(width: ceil(textSize.width) + 8,
                               height: ceil(textSize.height) + 8)
        let image = NSImage(size: imageSize)
        image.lockFocus()
        (text as NSString).draw(at: NSPoint(x: 4, y: 4), withAttributes: attrs)
        image.unlockFocus()
        let worldHeight: CGFloat = 34
        let plane = SCNPlane(width: worldHeight * imageSize.width / imageSize.height,
                             height: worldHeight)
        let m = plane.firstMaterial!
        m.lightingModel = .constant
        m.diffuse.contents = image
        m.isDoubleSided = true
        m.blendMode = .alpha
        return SCNNode(geometry: plane)
    }

    private func loadOverviewThumbnails() {
        let work: [(SCNNode, String)] = zip(memberNodes, data.clusters).flatMap { nodes, cluster in
            zip(nodes.prefix(Self.heapVisibleCount), cluster.memberPaths)
                .map { ($0, $1) }
        }
        thumbnailTask = Task { @MainActor in
            for (node, path) in work {
                if Task.isCancelled { return }
                guard let plane = node.geometry as? SCNPlane else { continue }
                if let img = await ThumbnailCache.shared.thumbnail(
                    for: URL(fileURLWithPath: path),
                    size: CGSize(width: 128, height: 128)
                ) {
                    CloudSceneCoordinator.applyCover(image: img, to: plane)
                }
            }
        }
    }

    // MARK: focus / unfocus (camera; member spread arrives in Task 11)

    func setFocus(_ id: String?, in view: SCNView) {
        guard id != focusedID else { return }
        focusedID = id
        let index = id.flatMap { fid in data.clusters.firstIndex { $0.id == fid } }

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.7
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        if let index {
            let p = clusterNodes[index].simdPosition
            cameraNode.position = SCNVector3(CGFloat(p.x), CGFloat(p.y),
                                             Self.focusCameraZ)
            edgesNode.opacity = 0.1
            for (ci, node) in clusterNodes.enumerated() where ci != index {
                node.opacity = 0.12
            }
            clusterNodes[index].opacity = 1
            labelNodes[index].opacity = 0
            spread(clusterIndex: index)
        } else {
            cameraNode.position = SCNVector3(0, 0, Self.overviewCameraZ)
            edgesNode.opacity = 1
            for (ci, node) in clusterNodes.enumerated() {
                node.opacity = 1
                labelNodes[ci].opacity = 1
                for (mi, member) in memberNodes[ci].enumerated() {
                    let t = heapTransforms[ci][mi]
                    member.simdPosition = t.0
                    member.simdOrientation = t.1
                    member.opacity = CGFloat(t.2)
                }
            }
        }
        SCNTransaction.commit()
    }

    /// Placeholder until Task 11: reveal all members in the flat heap
    /// ring so focus already shows everything.
    func spread(clusterIndex: Int) {
        for member in memberNodes[clusterIndex] {
            member.opacity = 1
        }
    }

    // MARK: hit routing

    func hitTarget(for node: SCNNode) -> (clusterIndex: Int, memberIndex: Int?)? {
        var n: SCNNode? = node
        while let current = n {
            if let name = current.name {
                if name.hasPrefix("member-") {
                    let parts = name.dropFirst(7).split(separator: "-")
                    if parts.count == 2, let ci = Int(parts[0]), let mi = Int(parts[1]) {
                        return (ci, mi)
                    }
                }
                if name.hasPrefix("cluster-"), let ci = Int(name.dropFirst(8)) {
                    return (ci, nil)
                }
            }
            n = current.parent
        }
        return nil
    }
}

// MARK: - SCNView subclass

final class GraphSCNView: SCNView {
    weak var coordinator: GraphSceneCoordinator?
    private var mouseDownPoint: NSPoint?

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        let up = convert(event.locationInWindow, from: nil)
        if let down = mouseDownPoint, hypot(up.x - down.x, up.y - down.y) > 6 { return }
        guard let coordinator else { return }
        let hits = hitTest(up, options: [.searchMode: NSNumber(value: SCNHitTestSearchMode.all.rawValue)])
        let target = hits.lazy.compactMap { coordinator.hitTarget(for: $0.node) }.first

        if let focusedID = coordinator.focusedID {
            guard let target,
                  let fi = coordinator.data.clusters.firstIndex(where: { $0.id == focusedID })
            else {
                coordinator.onFocus(nil)   // empty space -> zoom out
                return
            }
            if target.clusterIndex == fi, let mi = target.memberIndex {
                coordinator.openMember(clusterIndex: fi, memberIndex: mi, in: self)
            } else if target.clusterIndex != fi {
                coordinator.onFocus(coordinator.data.clusters[target.clusterIndex].id)
            }
        } else if let target {
            coordinator.onFocus(coordinator.data.clusters[target.clusterIndex].id)
        }
    }
}

extension GraphSceneCoordinator {
    func openMember(clusterIndex: Int, memberIndex: Int, in view: SCNView) {
        guard data.clusters.indices.contains(clusterIndex),
              data.clusters[clusterIndex].memberPaths.indices.contains(memberIndex),
              memberNodes.indices.contains(clusterIndex),
              memberNodes[clusterIndex].indices.contains(memberIndex) else { return }
        let node = memberNodes[clusterIndex][memberIndex]
        let rect = SceneProjection.screenRect(of: node, in: view)
            ?? CGRect(x: view.bounds.midX - 80, y: view.bounds.midY - 80,
                      width: 160, height: 160)
        onOpen(data.clusters[clusterIndex].memberPaths[memberIndex], rect)
    }
}
```

Note: `memberNodes`/`clusterNodes`/`heapTransforms`/`labelNodes` must be accessible from the `openMember` extension and `GraphSCNView` — they are `private` only where marked; keep `data`, `focusedID` as `private(set)` and the node arrays `private` with the access points shown (`hitTarget`, `openMember`, `setFocus`). `openMember` lives in an extension of the same file, so `private` members are visible (Swift file-scope privacy).

- [ ] **Step 2 — build + run existing tests**

Run: `cd /Users/carlostarrats/Documents/Projects/Muse/Muse && xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 3 — manual check**

Run the app on an analyzed folder (collections exist), switch to Graph: clusters appear as labeled thumbnail heaps spread on a flat plane, lines between collections sharing tags (more shared tags = brighter line). Click a cluster: camera flies in, others dim, label fades. Click empty space or press Esc: flies back out. Switching folders rebuilds.

- [ ] **Step 4 — commit**

```bash
cd /Users/carlostarrats/Documents/Projects/Muse
git add Muse/Muse/Views/Spatial/GraphView.swift
git commit -m "feat(spatial): graph overview — labeled cluster heaps, shared-tag edges, camera focus"
```

---

### Task 11: Graph zoom-in — 3D similarity spread

Replace the Task 10 `spread(clusterIndex:)` placeholder: on focus, fetch the cluster members' feature prints, compute the distance matrix off-main, lay out with `SimilarityLayout`, and animate members from the heap into the 3D spread. Cache per cluster.

**Files:**
- Modify: `Muse/Muse/Views/Spatial/GraphView.swift`

- [ ] **Step 1 — replace the `spread(clusterIndex:)` method** in `GraphSceneCoordinator` with:

```swift
    /// Spec §3: membership = collections, internal arrangement = visual
    /// similarity. Positions are cached per cluster id; computed off-main
    /// (print unarchiving + computeDistance are CPU-bound).
    private var spreadCache: [String: [SIMD3<Float>]] = [:]
    private var spreadTask: Task<Void, Never>?

    func spread(clusterIndex: Int) {
        let cluster = data.clusters[clusterIndex]
        if let cached = spreadCache[cluster.id] {
            applySpread(clusterIndex: clusterIndex, positions: cached)
            return
        }
        // Until positions land: reveal everything in the flat heap ring.
        for member in memberNodes[clusterIndex] { member.opacity = 1 }

        spreadTask?.cancel()
        spreadTask = Task { @MainActor in
            guard let q = Database.shared.dbQueue else { return }
            let ids = cluster.memberFileIDs
            let printsByID = (try? await GraphModel.featurePrints(queue: q, fileIDs: ids)) ?? [:]
            let prints: [Data?] = ids.map { printsByID[$0] }
            let seed = SeededRandom.fnv1a(ids)
            let positions = await Task.detached(priority: .userInitiated) {
                let matrix = GraphModel.distanceMatrix(prints: prints)
                return SimilarityLayout.positions(distances: matrix, seed: seed)
                    .map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
            }.value
            guard !Task.isCancelled else { return }
            spreadCache[cluster.id] = positions
            // Still focused on this cluster? Animate into the spread.
            if focusedID == cluster.id {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.7
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                applySpread(clusterIndex: clusterIndex, positions: positions)
                SCNTransaction.commit()
            }
        }
        loadAllThumbnails(clusterIndex: clusterIndex)
    }

    private func applySpread(clusterIndex: Int, positions: [SIMD3<Float>]) {
        let radius = Float(Self.spreadRadius)
        for (mi, member) in memberNodes[clusterIndex].enumerated() {
            guard mi < positions.count else { break }
            member.simdPosition = positions[mi] * radius
            member.simdOrientation = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
            member.opacity = 1
        }
    }

    /// Focused cluster shows every member — load the tail thumbnails.
    private func loadAllThumbnails(clusterIndex: Int) {
        let cluster = data.clusters[clusterIndex]
        let nodes = memberNodes[clusterIndex]
        Task { @MainActor in
            for (mi, path) in cluster.memberPaths.enumerated()
            where mi >= Self.heapVisibleCount {
                guard mi < nodes.count,
                      let plane = nodes[mi].geometry as? SCNPlane else { continue }
                if let img = await ThumbnailCache.shared.thumbnail(
                    for: URL(fileURLWithPath: path),
                    size: CGSize(width: 128, height: 128)
                ) {
                    CloudSceneCoordinator.applyCover(image: img, to: plane)
                }
            }
        }
    }
```

Also: in `setFocus`, the unfocus branch must reset members of the previously focused cluster back to their heap transforms — the Task 10 code already iterates ALL clusters on unfocus, which covers this. And in `rebuildIfNeeded`, add `spreadCache = [:]` and `spreadTask?.cancel()` next to `thumbnailTask?.cancel()` (a new scope invalidates cached spreads because membership may differ).

- [ ] **Step 2 — build + tests**

Run: `cd /Users/carlostarrats/Documents/Projects/Muse/Muse && xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 3 — manual check (full graph loop)**

On an analyzed folder: focus a cluster → members animate from the heap into a 3D spread where visually similar images sit near each other (duplicates/near-dupes should clump); camera flies in. Click an image → hero viewer flight starts FROM that card; Esc closes the viewer back; Esc again zooms the graph out and members return to the heap. Clicking a dimmed background cluster while focused switches focus to it.

- [ ] **Step 4 — commit**

```bash
cd /Users/carlostarrats/Documents/Projects/Muse
git add Muse/Muse/Views/Spatial/GraphView.swift
git commit -m "feat(spatial): graph cluster zoom — 3D similarity spread from feature prints"
```

---

### Task 12: Docs + final verification

**Files:**
- Modify: `CLAUDE.md` (architecture map, phase table, toolbar description)
- Modify: `docs/superpowers/specs/2026-06-10-post-rewrite-polish-design.md` (status line)

- [ ] **Step 1 — CLAUDE.md**:
  - Phase table: add row `| Polish 3 — spatial views (cloud + graph, globe retired) | ✅ shipped | feat/spatial-views (merged) |` after the Polish 2 row (mark merged only after the merge actually happens in finishing).
  - Architecture map: delete the `GlobeView.swift` and `SceneKit/FibonacciSphere.swift` lines; add under `Views/`:

```
    Spatial/
      SeededRandom.swift           SplitMix64 + FNV-1a for launch-stable layouts
      CloudPose.swift              25 measured reference poses + stage constants
      CloudLayout.swift            band-composition pose generation for big folders
      CloudMath.swift              CSS→SceneKit rotation + stage camera FOVs
      CloudView.swift              cloud scatter (SceneKit, letterboxed stage)
      SceneProjection.swift        node → screen rect (hero-viewer source frames)
      GraphLayout.swift            2D force layout for collection overview
      SimilarityLayout.swift       3D stress layout from feature-print distances
      GraphModel.swift             scoped clusters + shared-tag edges + distances
      GraphView.swift              knowledge graph (replaces GlobeView)
```

  - "How to run" toolbar line: change `grid/globe` to `grid/cloud/graph`.
  - GridView's architecture-map line mentions "water shader layerEffect when fluidEnabled" — unchanged; but the `GlobeView.swift   Fibonacci-sphere image cluster (Phase 8)` line goes away with the section above.
- [ ] **Step 2 — spec status**: in `docs/superpowers/specs/2026-06-10-post-rewrite-polish-design.md` line 13-14, update the parenthetical to `(AI brain ✅, hero viewer ✅, spatial views ✅ shipped; delights are phase 4, plan written per phase)`.
- [ ] **Step 3 — full suite + build**:

Run: `cd /Users/carlostarrats/Documents/Projects/Muse/Muse && xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests 2>&1 | tail -5 && xcodebuild -scheme Muse build 2>&1 | tail -3`
Expected: `** TEST SUCCEEDED **` and `** BUILD SUCCEEDED **`

- [ ] **Step 4 — commit**

```bash
cd /Users/carlostarrats/Documents/Projects/Muse
git add CLAUDE.md docs/superpowers/specs/2026-06-10-post-rewrite-polish-design.md
git commit -m "docs: record polish phase 3 (spatial views) in project notes"
```

- [ ] **Step 5 — finish the branch** per `superpowers:finishing-a-development-branch` (merge `feat/spatial-views` → `main` following the same convention as `feat/hero-viewer`).

---

## Spec-coverage checklist (§3 of the polish spec)

| Spec requirement | Task |
|---|---|
| Grid/Cloud/Graph three-way toolbar toggle | 6 |
| Cloud/Graph show current scope (folder, collection, search) | 4 (`visibleFiles`), 10 (`visibleFiles` → GraphModel scope) |
| Real 3D cards, per-card rx/ry/rz, genuine foreshortening | 3, 4 |
| Measured reference poses for the default arrangement | 2 |
| Generated poses with reference statistics for arbitrary counts | 2 |
| Fixed-aspect letterboxed stage | 3 (FOVs), 4/5 (`updateProjection`) |
| Soft warm shadows | 4 |
| Barely-there drift | 4 |
| Hover floats card up flat | 5 |
| Click opens the viewer (hero flight from the card) | 5 |
| SceneKit, one camera | 4 |
| Graph zoomed out: flat 2D, labeled thumbnail clusters | 10 |
| Lines between collections sharing tags | 9, 10 |
| Zoom into cluster → 3D spread by feature-print similarity, camera flies in | 10, 11 |
| Membership = collections, arrangement = similarity (hybrid) | 9, 11 |
| Zoom out flattens back | 10 |
| Click opens the viewer | 10 (`openMember`), 11 |
| FibonacciSphere retires with GlobeView | 6 |
| Thumbnails from ThumbnailCache (perf §) | 4, 10, 11 |
| Layout/AI work off the UI thread (perf §) | 11 (`Task.detached`), layouts are sub-ms pure funcs |
