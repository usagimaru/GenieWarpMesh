# GenieWarpMesh

A Swift package that applies macOS Genie-style minimize/restore effects to any `NSWindow` using the private `CGSSetWindowWarp` API.

[日本語 (Japanese)](README_ja.md)

<img src="./screenshot.jpg" width=420 alt="Screenshot">

## Requirements

- macOS 14.0+
    - (Tested only on macOS 26.4)
- Swift 5.9+

## Installation

### Swift Package Manager

Add the package as a local dependency or reference the repository URL:

```swift
dependencies: [
    .package(url: "https://github.com/usagimaru/GenieWarpMesh.git", from: "1.0.0")
]
```

Then add `GenieWarpMesh` to your target's dependencies:

```swift
.target(
    name: "YourApp",
    dependencies: ["GenieWarpMesh"]
)
```

If your app directly uses CGS private APIs (e.g. `CGSGetWindowBounds`), also add `CGSPrivate`:

```swift
dependencies: ["GenieWarpMesh", "CGSPrivate"]
```

## Usage

### Basic Minimize and Restore

Create a `GenieEffect` instance and call `minimize(window:to:direction:completion:)` / `restore(window:from:direction:completion:)`. All rect parameters use the **Cocoa coordinate system (bottom-left origin)** — you can pass `NSWindow.frame` or `NSScreen.frame` values directly.

```swift
import GenieWarpMesh

let genieEffect = GenieEffect()

// Minimize: warp the window into the target rect and hide it
genieEffect.minimize(window: myWindow, to: dockIconFrame) {
    print("Window is now hidden")
}

// Restore: reverse-warp from the target rect to re-show the window
genieEffect.restore(window: myWindow, from: dockIconFrame) {
    print("Window is visible again")
    myWindow.makeKey()
}
```

After `minimize` completes, the window is ordered out (hidden) but **not closed** — its warp state is preserved. The next `restore` (or another `minimize`) automatically resets the warp before starting.

> **Note:** `GenieEffect` does not track whether the window is minimized. It only holds internal animation state (`isAnimating` / `isReversed`). Your app is responsible for managing a flag like `isMinimized` to decide whether to call `minimize` or `restore`.

### Typical Minimize / Restore Flow

```swift
class WindowController: NSWindowController {
    private let genieEffect = GenieEffect()
    private var isMinimized = false

    func toggleGenie() {
        guard let window = self.window else { return }

        let targetRect = dockTileFrame() // Your target rect in Cocoa coordinates

        if isMinimized {
            genieEffect.restore(window: window, from: targetRect) { [weak self] in
                self?.isMinimized = false
                window.makeKey()
            }
        }
        else {
            genieEffect.minimize(window: window, to: targetRect) { [weak self] in
                self?.isMinimized = true
            }
        }
    }
}
```

### Direction

`GenieDirection` specifies which edge the window warps toward:

| Value | Description |
|-------|-------------|
| `.auto` (default) | Determined from source/target geometry |
| `.bottom` | Warp toward the bottom edge |
| `.top` | Warp toward the top edge |
| `.left` | Warp toward the left edge |
| `.right` | Warp toward the right edge |

`.auto` compares the horizontal and vertical distances between the centers of the source window and target rect, then selects the dominant axis. You can omit the `direction` parameter to use auto-detection:

```swift
// Direction is automatically determined
genieEffect.minimize(window: myWindow, to: targetRect)
```

### Configuration

`GenieEffect` properties can be customized before calling `minimize` / `restore`:

```swift
// Animation
genieEffect.duration = 0.5                  // Animation duration (seconds)
genieEffect.easingType = .easeInOutQuart     // Main easing curve
genieEffect.retreatEasingType = .easeInQuad  // Easing for retreat movement

// Curve shape
genieEffect.curveP1Ratio = 0.45     // Bézier control point P1 position (0–1)
genieEffect.curveP2Ratio = 0.65     // Bézier control point P2 position (0–1)

// Deformation behavior
genieEffect.widthEnd = 0.4          // Progress at which width shrink completes
genieEffect.slideStart = 0.15       // Progress at which sliding begins
genieEffect.stretchPower = 2.0      // Trailing edge stretch intensity

// Retreat (auto-correction when source and target are close)
genieEffect.retreatEnd = 0.4        // Progress at which retreat completes
genieEffect.skipCutoffOnRetreat = true  // Skip cutoff during retreat

// Phase cutoff (trim the animation timeline)
genieEffect.minimizeRawTStart = 0.0  // Forward: skip this portion from the start
genieEffect.minimizeRawTEnd = 1.0    // Forward: stop at this point
genieEffect.restoreRawTStart = 0.0   // Reverse: skip this portion from the start
genieEffect.restoreRawTEnd = 1.0     // Reverse: stop at this point

// Mesh resolution
genieEffect.gridWidth = 8           // Mesh grid columns
genieEffect.gridHeight = 20         // Mesh grid rows
genieEffect.adaptiveMesh = true     // Auto-adjust resolution by direction
```

### Easing Types

The `EasingType` enum provides standard polynomial easing functions:

```
linear
easeInQuad / easeOutQuad / easeInOutQuad       (2nd order)
easeInCubic / easeOutCubic / easeInOutCubic     (3rd order)
easeInQuart / easeOutQuart / easeInOutQuart     (4th order)
easeInQuint / easeOutQuint / easeInOutQuint     (5th order)
```

### Progress Callback

Monitor the animation progress (0.0 → 1.0) on every display frame:

```swift
genieEffect.progressHandler = { progress in
    // Update a progress indicator, etc.
    print("Progress: \(progress)")
}

genieEffect.minimize(window: myWindow, to: targetRect) {
    genieEffect.progressHandler = nil  // Clean up when done
}
```

### Debug Overlay

#### Built-in DebugOverlayWindow

The library includes `DebugOverlayWindow`, a full-screen transparent overlay that visualizes Bézier curve paths, control points, mesh wireframes, and corrected frames. This is the easiest way to debug the effect:

```swift
let debugOverlay = DebugOverlayWindow()
debugOverlay.orderFront(nil)

genieEffect.debugOverlayReceiver = debugOverlay
```

Call `fitToScreen()` when the screen geometry changes, and `clearCurves()` to reset:

```swift
debugOverlay.fitToScreen()   // After screen resolution change
debugOverlay.clearCurves()   // Clear all visualizations
```

#### Custom Debug Overlay

Implement the `GenieDebugOverlay` protocol for custom visualization:

```swift
class MyOverlay: NSWindow, GenieDebugOverlay {
    func receiveCurveGuideData(
        leftCurve: (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint),
        rightCurve: (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint),
        sourceFrame: CGRect,
        targetFrame: CGRect,
        fitRect: CGRect?,
        leftExtensionEnd: CGPoint?,
        rightExtensionEnd: CGPoint?,
        correctedData: CorrectedCurveData?
    ) { /* Draw curve guides */ }

    func receiveMeshEdgePoints(
        _ points: [CGPoint],
        gridWidth: Int,
        gridHeight: Int,
        screenHeight: CGFloat
    ) { /* Draw mesh wireframe */ }

    func clearMeshEdgePoints() { /* Clear mesh visualization */ }
}
```

You can also call `updateDebugOverlayForCurrentLayout(sourceFrame:targetFrame:direction:)` to refresh the overlay without running an animation — useful when windows are being dragged:

```swift
genieEffect.updateDebugOverlayForCurrentLayout(
    sourceFrame: window.frame,
    targetFrame: targetPanel.frame,
    direction: .auto
)
```

### Proximity Correction

When the source window and target rect are very close (within 20 pt on the warp axis), the Bézier curve becomes too short for a convincing effect. `GenieEffect` automatically computes a corrected frame that moves the source away from the target, then smoothly animates the retreat. You can preview this correction:

```swift
if let corrected = genieEffect.computeCorrectedFrame(
    sourceFrame: window.frame,
    targetFrame: targetRect,
    direction: .bottom
) {
    print("Window will retreat to: \(corrected)")
}
// Returns nil when no correction is needed
```

## Important Notes

- This library uses the private `CGSSetWindowWarp` API which is not documented by Apple. Apps using this API may not be accepted on the Mac App Store.
- The `CGSPrivate` module exposes C declarations for `CGSSetWindowWarp`, `CGSGetWindowBounds`, and related functions.

## License

See [LICENSE](./LICENSE) for details.
