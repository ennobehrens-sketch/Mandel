# Mandel — fast zoomable Mandelbrot for macOS

## Decisions (from interview)

| Topic | Choice |
|---|---|
| Platform | Native macOS app, Swift + Metal |
| Hardware | Apple Silicon (M1+), macOS 13+ |
| Project | Swift Package (`swift run -c release`, or open `Package.swift` in Xcode) |
| Zoom depth | ~10^12 (measured limit of double-float; originally targeted 10^13) via emulated double precision on the GPU |
| Gestures | Two-finger scroll = zoom (anchored at cursor), click-drag = pan |
| Rendering | Always full Retina resolution, no progressive preview |
| Colouring | Smooth gradient **and** classic banded, switchable |
| Extras | HUD overlay |

## Architecture

```
Package.swift
Sources/Mandel/
  main.swift          NSApplication bootstrap, window
  MandelView.swift    MTKView subclass: scrollWheel / mouseDragged / keyDown
  Viewport.swift      CPU-side view state in Double: center (re, im), scale (units/pixel)
  Renderer.swift      MTKViewDelegate: pipeline, uniforms, draw, GPU timing
  Shaders.swift       Metal source as a Swift string, compiled at runtime
  HUD.swift           Overlay label (zoom, centre, iterations, frame time, precision mode)
```

- **Shader compilation at runtime.** `swift build` does not compile `.metal` files (only Xcode does), so the shader source ships as a string and goes through `device.makeLibrary(source:options:)` once at launch (~50 ms). **Fast-math must be off** (`fastMathEnabled = false`, or `mathMode = .safe` on macOS 15). Otherwise the compiler deletes the error-compensation terms the double-float arithmetic relies on. This is the main correctness risk.
- **Full-screen fragment shader**: one triangle covering the drawable, one fragment per Retina pixel.
- **Drawing only on demand**: `isPaused = true`, `enableSetNeedsDisplay = true`. Input events update `Viewport` and mark the view dirty. macOS coalesces those marks into at most one frame per display refresh (up to 120 Hz on ProMotion). When nothing moves, the GPU does no work.

## Precision: hybrid float / double-float

- The CPU keeps the centre and scale as `Double`. Each one is split into a hi/lo `Float` pair and passed to the GPU as uniforms.
- **Shallow (scale > ~1e-5 per pixel):** plain `float` kernel, the fastest path.
- **Deep (below that):** double-float kernel. Each number is a `float2` (hi + lo). Addition uses two-sum and multiplication uses an `fma`-based two-product. That gives about 48 bits of mantissa, so roughly 10^13–10^14 of zoom before pixels go blocky.
- The switch happens automatically and shows in the HUD ("FP32" / "DF64").

## Iteration speed-ups

- Main cardioid and period-2 bulb test: skips the most expensive interior pixels entirely.
- Max iterations scale automatically with zoom: `maxIter ≈ 200 + 150·log10(initialScale/scale)`. `[` and `]` adjust it manually.
- Early-exit escape radius of 256, which helps smooth colouring.

## Input

- `scrollWheel(with:)` uses precise trackpad deltas: `zoom *= exp(-deltaY · k)`. The point under the cursor stays fixed (convert the cursor to complex coordinates before and after, then shift the centre). macOS momentum-phase events keep arriving after you lift your fingers, so smooth inertial zooming comes free.
- `mouseDragged` pans by the pixel delta times the scale.
- Keys: `C` switches smooth/banded colouring, `P` cycles palettes, `H` toggles the HUD, `R` resets the view, `[` `]` change iterations.

## Colouring

- **Smooth:** `mu = n + 1 − log2(log|z|)`, mapped through a cosine palette (a few presets), with an animation-free offset.
- **Banded:** `n mod bandCount` mapped through the same palette, so the bands come out discrete.
- Interior pixels are black.

## HUD

A semi-transparent overlay in the top-left corner showing:
- the zoom level (e.g. `3.2e9×`)
- the centre coordinates, with 16 significant digits
- the max iteration count
- GPU frame time in ms (from `GPUStartTime` / `GPUEndTime`)
- the precision mode and the colouring mode

## Performance expectations / risk

The full-resolution choice has a cost. A 5 MP Retina drawable at very deep zoom with thousands of iterations in double-float can take **hundreds of ms per frame** on a base M1. At shallow zoom (FP32) it stays at 60–120 fps. If deep zoom feels sluggish, the fixes in order of preference are:
1. Render at a reduced resolution while scroll events are arriving, then sharpen at full resolution (a small, optional change).
2. Reuse the previous frame as a stretched texture during the gesture.
3. Perturbation theory, which also extends depth beyond 10^13.

## Milestones

1. Window, FP32 shader, scroll zoom at the cursor, drag pan.
2. Double-float kernel with automatic switch-over; check that 1e13 zoom stays sharp.
3. Smooth and banded colouring, palettes.
4. HUD, iteration auto-scaling, keyboard shortcuts.
5. Performance pass (cardioid test, timing, tuning).

## Testing

This repo is developed in a Linux cloud environment, so the code can't be compiled or run there. Build and run it on the Mac with `swift run -c release`, then report any compile errors or visual issues.
