import Foundation

/// View state, kept in Double on the CPU and split into hi/lo Float pairs for the GPU.
struct Viewport {
    var centerX: Double = -0.75
    var centerY: Double = 0.0
    /// Complex-plane units per drawable pixel.
    var scale: Double = 0.004

    /// Below this, neighbouring pixels are only a few double-float ulps apart and the image turns blocky.
    static let minScale = 2e-15
    static let maxScale = 0.05

    mutating func fit(width: Double, height: Double) {
        centerX = -0.75
        centerY = 0.0
        scale = max(3.5 / width, 3.0 / height)
    }

    /// Multiplies the scale by `factor`, keeping the complex point under `pixel` fixed.
    /// `pixel` is measured in drawable pixels from the centre of the view, y up.
    mutating func zoom(by factor: Double, around pixel: SIMD2<Double>) {
        let newScale = min(max(scale * factor, Self.minScale), Self.maxScale)
        centerX += pixel.x * (scale - newScale)
        centerY += pixel.y * (scale - newScale)
        scale = newScale
    }

    /// Moves the image by `delta` drawable pixels (y up).
    mutating func pan(byPixels delta: SIMD2<Double>) {
        centerX -= delta.x * scale
        centerY -= delta.y * scale
    }

    /// Magnification relative to a view that shows a height of 3 units across the shorter side.
    func zoomLevel(minDimension: Double) -> Double {
        3.0 / (scale * minDimension)
    }

    var isAtPrecisionLimit: Bool { scale <= Self.minScale * 1.0001 }
}

/// Splits a Double into a (hi, lo) Float pair with hi + lo ≈ v to ~48 bits.
func splitDouble(_ v: Double) -> (Float, Float) {
    let hi = Float(v)
    let lo = Float(v - Double(hi))
    return (hi, lo)
}
