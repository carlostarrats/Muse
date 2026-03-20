# Muse Phase 2 -- 3D Views (Universe, Globe, Folder)
## Build Specification for Claude Code

---

## Prerequisites

Phase 1 must be complete and stable before starting this spec. You should have:

- A working Xcode project with GRDB, data models, and ImageRepository
- Import system (single file, folder, drag-and-drop) generating thumbnails
- Grid view displaying images in a masonry layout with detail panel
- Tag and collection CRUD working
- AppState wired up as an EnvironmentObject

This spec adds three SceneKit-based views and a view switcher to navigate between them and the existing Grid view.

---

## Architecture: SwiftUI + SceneKit

Each 3D view is a SceneKit `SCNScene` wrapped in a SwiftUI `NSViewRepresentable` via `SCNView`. The SwiftUI chrome (toolbar, detail panel, search bar) stays the same across all views. Only the main content area swaps between Grid and the SceneKit views.

SceneKit coordinate system: Y is up, Z comes toward the camera. Default camera position for globe views is Z=9 looking at origin.

---

## App State Changes

Add a view mode enum and property to AppState:

```
enum ViewMode {
    case grid
    case universe
    case globe(collectionID: UUID)
    case folder
}
```

Add to AppState:
- `viewMode: ViewMode` (default `.grid`)

The existing `selectedImage`, `detailPanelVisible`, and `searchQuery` properties continue to work across all views. The detail panel behavior is identical regardless of which view triggered it.

---

## View Switcher

Add a `ViewSwitcher` component to the toolbar. It shows four icon buttons in a segmented control style:

- Grid icon (grid view)
- Globe icon (universe view)
- Folder icon (folder view)

Tapping a button sets `appState.viewMode`. The currently active mode is visually highlighted.

The globe(collectionID:) mode is not directly accessible from the switcher. It is entered by clicking a globe in Universe view. Pressing the globe icon in the switcher goes to Universe view.

Update `ContentView` to switch on `appState.viewMode` and show the appropriate view in the main content area.

---

## File Structure (new files only)

```
Muse/
├── SceneKit/
│   ├── FibonacciSphere.swift      # Point distribution math + node builder
│   ├── UniverseScene.swift        # SCNScene for all-collections view
│   ├── GlobeScene.swift           # SCNScene for single-collection sphere
│   ├── FolderScene.swift          # SCNScene for folder open/close
│   └── CameraController.swift     # Shared camera animation helpers
│
├── Views/
│   ├── UniverseView.swift         # NSViewRepresentable wrapper for UniverseScene
│   ├── GlobeView.swift            # NSViewRepresentable wrapper for GlobeScene
│   └── FolderView.swift           # NSViewRepresentable wrapper for FolderScene
│
├── Components/
│   └── ViewSwitcher.swift         # Toolbar segmented control
```

---

## Fibonacci Sphere

This is the core math used to distribute images evenly on the surface of a sphere.

### FibonacciSphere

A utility struct or enum (no instances needed) with two responsibilities:

**1. Generate positions**

Given a count and radius, return an array of 3D positions distributed evenly on a sphere using the golden angle method. The golden angle is `pi * (3 - sqrt(5))`. For each point i of n:
- `theta = golden_angle * i`
- `y = 1 - (2 * i + 1) / n` (maps to -1...1)
- `r = sqrt(1 - y*y)`
- `x = r * cos(theta)`
- `z = r * sin(theta)`

Scale all by the radius.

**2. Build a globe node**

Given an array of MuseImage records and a radius, build an `SCNNode` containing child nodes for each image:

- Each image is an `SCNPlane` geometry (aspect ratio ~1.3:1, roughly 0.45 x 0.35 scene units)
- Texture the plane with the thumbnail. Load the thumbnail as an NSImage. If the thumbnail is missing, use a dark gray placeholder material.
- Position each plane at the corresponding Fibonacci point
- Orient each plane to face outward from the sphere center. Use `SCNNode.look(at:)` pointed away from the origin, or manually compute the rotation from the surface normal. Test this carefully. The images should be visible from outside the sphere, not facing inward.
- Add a small random tilt per image (up to ~0.15 radians on X and Z euler angles) for an organic, non-uniform feel
- Set each node's `name` to the image's UUID string so it can be identified on hit-test

Return the container node.

---

## Universe View

The default 3D view. Shows all collections as floating globes scattered in 3D space, like planets.

### UniverseScene

An SCNScene subclass (or a function that builds an SCNScene).

Setup:
- Background: very dark blue-black (r:0.04, g:0.04, b:0.08)
- Ambient light at intensity ~400, slightly warm white
- Directional light at intensity ~800, angled down and to the right

Populating globes:
- Takes a list of collections and a dictionary of [UUID: [MuseImage]] (images grouped by collection)
- For each collection, build a globe node using FibonacciSphere
- Globe radius scales with image count: `max(2.5, min(5.0, Float(imageCount) * 0.15))`
- Scatter the globes in 3D space using the golden angle for XZ distribution, with random Y offset (-4 to 4). Spacing should be generous enough that globes do not overlap. Start at a moderate distance from origin and spiral outward.
- Each globe gets a slow perpetual Y-axis rotation (full rotation in ~30 seconds)
- Below each globe, add a 3D text label with the collection name. Use `SCNText` with a small font size (~0.4), white at 85% opacity. Center the text horizontally under the globe.

Keep a dictionary mapping collection UUID to globe SCNNode for later lookup.

### UniverseView (NSViewRepresentable)

Wraps UniverseScene in an SCNView.

Camera:
- Start position: far enough back to see all globes (calculate based on how many collections exist)
- `allowsCameraControl = true` so the user can orbit and zoom with trackpad/mouse

Interaction:
- Click on a globe: identify which collection it belongs to (via node name or the UUID dictionary). Animate the camera flying toward that globe over ~0.6 seconds with ease-in-ease-out timing. Once the fly-to completes, transition to Globe view by setting `appState.viewMode = .globe(collectionID:)`.

Use a Coordinator for gesture handling. Add an `NSClickGestureRecognizer`. On click, run `SCNView.hitTest` at the click location. Walk up the node hierarchy from the hit node to find the globe container node (the one whose name matches a collection UUID).

### CameraController

A helper for camera fly-to animations used by both Universe and Globe views.

Provide a function like:
```
static func flyCamera(_ cameraNode: SCNNode, to position: SCNVector3, lookAt target: SCNVector3, duration: TimeInterval, completion: (() -> Void)?)
```

Use `SCNTransaction` for the animation. Set the timing function to ease-in-ease-out.

---

## Globe View

Shows a single collection's images tiled on a 3D sphere. This is the view entered after clicking a globe in Universe view.

### GlobeScene

An SCNScene for a single collection.

Setup:
- Same dark background as Universe
- Ambient light at intensity ~500
- One globe node built from the collection's images at radius 3.0
- Globe auto-rotates slowly on the Y axis (full rotation in ~25 seconds)

Camera:
- Position at (0, 0, 9), looking at origin
- `allowsCameraControl = true` for orbit/zoom

### GlobeView (NSViewRepresentable)

Wraps GlobeScene in an SCNView.

Gestures via Coordinator:

**Drag to spin:**
- NSPanGestureRecognizer on the SCNView
- During drag, adjust the globe node's euler angles based on the drag delta
- Sensitivity: multiply translation by ~0.005
- While dragging, pause the auto-rotation. Resume auto-rotation a few seconds after the drag ends.

**Click to focus:**
- NSClickGestureRecognizer
- Hit test at click location. If a hit node's name matches an image UUID, focus that image.

Focus behavior:
1. Pause the globe's auto-rotation
2. Animate the clicked image node to position (-1.5, 0, 5) -- forward and to the left of center. Duration ~0.4s, ease-in-ease-out.
3. Scale the focused node up to 2.2x its original size
4. Fade all other image nodes on the globe to ~8% opacity
5. Set `appState.selectedImage` and `appState.detailPanelVisible = true`

Unfocus (when the detail panel is dismissed):
1. Animate the focused node back to its original position and scale
2. Fade all other nodes back to full opacity
3. Resume auto-rotation

**Back to Universe:**
- Add a back button (chevron.left icon) in the toolbar or floating in the view
- Clicking it sets `appState.viewMode = .universe`

---

## Folder View

Shows collections as physical 3D folders. Clicking a folder opens it with an animation and reveals the images inside as a grid.

### FolderScene

An SCNScene that renders a 3D folder object for one collection at a time.

Folder construction:
- Two thin box geometries (SCNBox) representing the back cover and front cover
- Width ~6, height ~4.5, depth ~0.05, chamfer radius ~0.06
- Color: the collection's `colorHex`
- Front cover is slightly in front of back cover (Z offset ~0.05)
- Both covers have a slight initial tilt (small euler angle offsets) so the folder looks like it's resting on a surface rather than floating flat
- A tab element on top (small SCNBox, ~1.2 wide, 0.35 tall) with the collection name as SCNText on it
- Use the Phong lighting model on the folder materials for a slightly glossy look

Camera:
- Position at (0, 1, 8), looking slightly down
- `allowsCameraControl = false` (camera is fixed in folder view)

Lighting:
- Ambient at ~600
- Directional at ~800, angled for depth shadows

### FolderView (NSViewRepresentable)

Wraps FolderScene in an SCNView.

Interaction via Coordinator:

**Open folder:**
- Click on the folder (hit test matches "frontCover" or "backCover")
- Animate the front cover rotating backward on the X axis to about -135 degrees (0.75 * pi) over 0.6 seconds, ease-in-ease-out
- After the cover opens (~0.5s delay), animate images appearing:
  - Create SCNPlane nodes for each image (up to 20 visible), textured with thumbnails
  - Each starts at position (0, 0, 0.1) with opacity 0
  - Stagger-animate each to its grid position (4 columns, ~1.6 spacing, rows going downward) over 0.45 seconds with ease-out timing
  - Stagger delay: 0.04 seconds per image
  - Each image gets a tiny random Z-axis rotation for organic feel

**Close folder:**
- Click the folder again, or click a "close" control
- Remove all image nodes
- Animate front cover rotating back to its initial position over 0.45 seconds

**Click image inside open folder:**
- Hit test identifies the image node by UUID name
- Set `appState.selectedImage` and `appState.detailPanelVisible = true`
- The detail panel slides in from the right as usual (SwiftUI layer)

**Switching between collections in folder view:**
- Show tabs along the right edge of the scene (or as a SwiftUI overlay list) for other collections
- Clicking a different collection tab closes the current folder and opens the new one

### NSColor hex extension

Add a convenience initializer on NSColor that takes a hex string (e.g. "#5E8BFF") and parses it to RGB values. This is needed for collection colors in the folder and globe label rendering.

---

## Transitions Between Views

Switching views via ViewSwitcher or back buttons should feel smooth:

- Grid to Universe: Crossfade transition (0.3s)
- Universe to Globe: Camera fly-to animation (handled in SceneKit), then swap to GlobeView
- Globe to Universe: Crossfade back
- Any to Folder: Crossfade
- Folder to Grid: Crossfade

Use SwiftUI `.transition()` and `.animation()` on the view switching in ContentView. The SceneKit scenes handle their own internal animations.

---

## Performance Notes

- Thumbnail textures are the same 400px images generated in Phase 1. Do not load full-resolution images as SceneKit textures.
- For collections with 100+ images, the Fibonacci sphere will have many plane nodes. If performance is an issue, limit the globe to the most recent 80-100 images and note the total count in the label.
- SceneKit rendering should use `SCNView.antialiasingMode = .multisampling4X` for clean edges.
- The globe's auto-rotation should stop cleanly (not snap) when the user starts dragging.

---

## What Is NOT in This Spec

Do not build:
- AI tagging (Phase 3)
- Bulk tag operations
- Collection color picker UI (collections have colors but the picker is a later polish item)
- Export or sharing
- Any network calls

---

## Build Order

1. Build FibonacciSphere. Unit test: generate 50 points on a sphere of radius 3, verify all points are approximately distance 3 from origin, verify reasonable distribution (no clusters).
2. Build ViewSwitcher and update ContentView to switch on viewMode.
3. Build GlobeScene and GlobeView. Test: assign images to a collection, switch to globe view, verify images are visible on the sphere surface facing outward.
4. Add drag-to-spin on the globe. Test: drag to rotate, release, auto-rotation resumes.
5. Add click-to-focus on globe images. Test: click an image, it animates forward, detail panel opens.
6. Build CameraController fly-to helper.
7. Build UniverseScene and UniverseView. Test: create 3-4 collections with images, verify globes appear scattered in space with labels.
8. Wire Universe click-to-globe transition. Test: click a globe in Universe, camera flies in, view switches to GlobeView for that collection.
9. Add back button from Globe to Universe.
10. Build the NSColor hex extension.
11. Build FolderScene and FolderView. Test: open a collection folder, images animate into grid.
12. Wire click-to-focus inside open folders.
13. Add collection tabs in folder view.
14. Add crossfade transitions between views in ContentView.
15. Performance test with 5 collections of 50+ images each.
