# Mandel

A fast, smoothly zoomable Mandelbrot viewer for macOS, written in Swift and Metal.

- Renders every frame at full Retina resolution on the GPU, and only when something changes.
- Two-finger scroll on the trackpad zooms around the cursor, with macOS momentum. Pinch works too.
- Switches automatically from 32-bit float to emulated double precision ("double-float") as you zoom in, reaching about 10¹² magnification.
- Smooth or classic banded colouring, four palettes.
- HUD with zoom, coordinates, iterations, precision mode and GPU frame time.

## Requirements

- Apple Silicon Mac (M1 or later), macOS 13+
- Xcode 15 or later (or the matching command-line tools)

## Run

```sh
swift run -c release
```

Or open `Package.swift` in Xcode and press ⌘R (choose the *Release* scheme for full speed).

## Controls

| Input | Action |
|---|---|
| Two-finger scroll up / down | Zoom in / out around the cursor |
| Pinch | Zoom |
| Click-drag | Pan |
| Double-click / ⇧ double-click | Zoom in / out 2× |
| `+` / `-` | Zoom in / out around the centre |
| `C` | Switch smooth / banded colouring |
| `P` | Next palette |
| `↑` / `↓` (or `]` / `[`) | More / fewer iterations (on top of the automatic count) |
| `→` / `←` | Colour density |
| `I` | Invert the scroll-zoom direction |
| `R` | Reset view |
| `H` | Hide / show HUD |
| ⌃⌘F | Full screen |

## How it works

- `Viewport` keeps the centre and scale in `Double`. Each value is split into a hi/lo `Float` pair for the GPU.
- `Shaders.swift` holds the Metal source. It's compiled at launch in two variants: plain FP32 with fast-math, and double-float with strict IEEE maths (fast-math would optimise away the error terms). Below 1e-5 units per pixel the renderer switches to double-float.
- Speed-ups: interior pixels in the main cardioid and the period-2 bulb are skipped analytically. An exact-repeat periodicity check (Brent) cuts other interior pixels short. Only one frame is in flight at a time, so input that arrives during a slow frame is merged into the next one instead of queueing behind it.
- Maximum iterations grow with zoom: `200 + 250·log10(zoom)`, capped at 50 000.

## Limits

Double-float has a ~48-bit mantissa. At about 2·10⁻¹⁵ units per pixel (≈10¹² zoom) neighbouring pixels are only a few ulps apart. The image turns noisy there, so the zoom stops and the HUD shows a warning. Going deeper would need perturbation theory.
