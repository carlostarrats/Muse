# Fluid Distortion Effect — Design Spec

## Goal
When the mouse moves over the image grid, images distort like dragging through water. Distortion persists briefly and fades when the mouse stops. The effect warps actual image pixels — not an overlay. It appears as one continuous fluid surface across all tiles.

## Architecture

Three components: FluidSim (CPU simulation), FluidDistortion.metal (GPU shader), GridView integration.

### 1. FluidSim

**Location:** `Muse/Muse/Fluid/FluidSim.swift`

**Ownership:** Property on `AppState`. This avoids `@StateObject` initialization issues caused by the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting.

```swift
// In AppState.swift
let fluidSim = FluidSim()
```

**Class design:**
- NOT `@MainActor` — explicitly opts out to avoid actor isolation issues in init
- Conforms to `@unchecked Sendable` for passing across isolation boundaries
- Uses `ObservableObject` with `@Published var dispImage: Image`

**Simulation:** Jos Stam stable fluids, 64x64 grid.
- `start()` — creates a Timer at 1/60s
- `step()` — one simulation frame:
  1. Inject velocity: Gaussian splat (radius 6 cells) at mouse position, strength proportional to mouse velocity
  2. Diffuse: 4 Jacobi iterations, viscosity 0.0001
  3. Project: compute divergence, 20 Jacobi pressure iterations, subtract gradient
  4. Advect: semi-Lagrangian with dt=0.8
  5. Dissipate: multiply velocity by 0.98
  6. Encode: write velocity to 64x64 CGImage (R = vx * scale + 128, G = vy * scale + 128)
  7. Publish: set `dispImage` to SwiftUI Image wrapping the CGImage

**Mouse input:**
- `setMouse(_ pos: CGPoint)` — receives viewport coordinates from `onContinuousHover`
- Maps viewport coords to grid coords internally
- Computes velocity from delta between current and previous position
- `clearMouse()` — called when hover ends

**Debug harness:**
- On init, inject test splats into the velocity field
- After frame 10, write the displacement CGImage to `{AppSupport}/Muse/fluid_debug.png`
- Log max velocity value
- This lets us verify the sim produces correct output before any UI integration

### 2. FluidDistortion.metal

**Location:** `Muse/Muse/Fluid/FluidDistortion.metal`

**Type:** `layerEffect` shader (not `distortionEffect`). This is required because `layerEffect` supports `.image()` arguments while `distortionEffect` does not.

**Signature:**
```metal
#include <SwiftUI/SwiftUI_Metal.h>

[[ stitchable ]]
half4 fluidDistort(float2 position,
                   SwiftUI::Layer layer,
                   texture2d<half> dispMap,
                   float2 tileOrigin,
                   float2 viewportSize)
```

**Logic:**
1. Compute global viewport position: `position + tileOrigin`
2. Compute UV in displacement map: `globalPos / viewportSize`, clamped to [0.001, 0.999]
3. Sample displacement map with bilinear filtering
4. Decode: `displacement = (sample.rg - 0.5) * 2.0 * 40.0` (maps [0,1] to [-40,+40] pixel offset)
5. Return `layer.sample(position + displacement)`

### 3. GridView Integration

**Mouse tracking:** Existing `onContinuousHover` on the ScrollView feeds mouse position to `appState.fluidSim.setMouse()`. On hover end, calls `clearMouse()`.

**FluidSim lifecycle:** `appState.fluidSim.start()` called from `.task` on `ContentView` (alongside `appState.loadAll()`). This ensures it runs regardless of which view mode is active.

**TileView changes:**
- New properties: `dispImage: Image`, `viewportSize: CGSize`
- New `@State`: `tileFrame: CGRect` tracked via background `GeometryReader` with `.global` coordinate space
- `.layerEffect` applied after shadows, before animations:
  ```swift
  .layerEffect(
      ShaderLibrary.fluidDistort(
          .image(dispImage),
          .float2(Float(tileFrame.minX), Float(tileFrame.minY)),
          .float2(Float(viewportSize.width), Float(viewportSize.height))
      ),
      maxSampleOffset: CGSize(width: 50, height: 50)
  )
  ```

**Placeholder image:** A static 1x1 image with RGB(128, 128, 0) — decodes to zero displacement. Used before the sim produces its first frame.

### Coordinate Flow

```
Mouse move (viewport coords)
    → FluidSim.setMouse(viewportPos)
    → Maps to grid coords: (x/vpWidth * 64, y/vpHeight * 64)
    → Gaussian splat injects velocity at that grid cell
    → Simulation step produces velocity field
    → Encoded as 64x64 image (R=dx+128, G=dy+128)
    → Published as dispImage

Each tile:
    → Knows its tileFrame.origin in .global coords
    → Shader computes: globalPos = pixelPos + tileOrigin
    → UV = globalPos / viewportSize
    → Samples displacement map at UV
    → Warps the tile's pixels by the displacement
```

### Known Limitations

- Per-tile `.layerEffect` cannot sample pixels from neighboring tiles. At tile edges, displaced pixels that would come from a neighbor show the tile's own edge pixels instead. The 20px MasonryLayout spacing hides this — the gaps act as natural boundaries.
- The 64x64 simulation resolution means fine details in the fluid are smoothed out. This is intentional — it creates the smooth, organic look of thick liquid rather than sharp ripples.
- Creating a new CGImage + NSImage + SwiftUI Image every frame (60fps) has allocation overhead. If performance is an issue, the frame rate can be dropped to 30fps or the image can be double-buffered.

### Files Changed

| File | Action |
|------|--------|
| `Muse/Fluid/FluidSim.swift` | Create |
| `Muse/Fluid/FluidDistortion.metal` | Create |
| `Muse/Models/AppState.swift` | Add `fluidSim` property |
| `Muse/Views/GridView.swift` | Add `.layerEffect`, pass dispImage to tiles |
| `Muse/ContentView.swift` | Call `fluidSim.start()` in `.task` |
