import MetalKit

/// Metal view that draws only when something changes, plus all trackpad, mouse and keyboard input.
final class MandelView: MTKView {
    private(set) var renderer: Renderer!
    private let hud = HUDView()
    /// Flips the scroll-to-zoom direction ("I" key).
    private var invertScroll = false

    init(contentFrame frameRect: NSRect) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RendererError.noMetalDevice
        }
        super.init(frame: frameRect, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        framebufferOnly = true
        autoResizeDrawable = true
        isPaused = true
        enableSetNeedsDisplay = true

        renderer = try Renderer(view: self)
        delegate = renderer
        renderer.onFrameCompleted = { [weak self] in self?.updateHUD() }

        hud.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hud)
        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            hud.topAnchor.constraint(equalTo: topAnchor, constant: 12),
        ])
        updateHUD()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Coordinates

    /// Drawable pixels per view point (2 on Retina).
    private var backingRatio: Double {
        bounds.width > 0 ? Double(drawableSize.width / bounds.width) : 1
    }

    /// Cursor position in drawable pixels relative to the view centre, y up.
    private func pixelOffset(of event: NSEvent) -> SIMD2<Double> {
        let point = convert(event.locationInWindow, from: nil)
        let ratio = backingRatio
        return SIMD2(
            Double(point.x) * ratio - Double(drawableSize.width) / 2,
            Double(point.y) * ratio - Double(drawableSize.height) / 2
        )
    }

    private func changed() {
        needsDisplay = true
        updateHUD()
    }

    private func zoom(by factor: Double, around pixel: SIMD2<Double>) {
        guard factor.isFinite, factor > 0 else { return }
        renderer.viewport.zoom(by: factor, around: pixel)
        changed()
    }

    // MARK: - Trackpad and mouse

    override func scrollWheel(with event: NSEvent) {
        // Normalise to physical finger direction: positive = fingers moving up = zoom in.
        var delta = Double(event.scrollingDeltaY)
        if event.isDirectionInvertedFromDevice { delta = -delta }
        if invertScroll { delta = -delta }
        // Trackpads report points (many small events, with momentum after lift-off);
        // mouse wheels report lines.
        let sensitivity = event.hasPreciseScrollingDeltas ? 0.006 : 0.15
        zoom(by: exp(-delta * sensitivity), around: pixelOffset(of: event))
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1.0 / (1.0 + Double(event.magnification)), around: pixelOffset(of: event))
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let zoomOut = event.modifierFlags.contains(.shift)
            zoom(by: zoomOut ? 2.0 : 0.5, around: pixelOffset(of: event))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let ratio = backingRatio
        // Mouse deltaY is positive downwards; the viewport works y up.
        renderer.viewport.pan(byPixels: SIMD2(Double(event.deltaX) * ratio, -Double(event.deltaY) * ratio))
        changed()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: // ↑
            renderer.iterationFactor = min(renderer.iterationFactor * 1.5, 64)
        case 125: // ↓
            renderer.iterationFactor = max(renderer.iterationFactor / 1.5, 1.0 / 16)
        case 124: // →
            renderer.colorDensity = min(renderer.colorDensity * 1.25, 2)
        case 123: // ←
            renderer.colorDensity = max(renderer.colorDensity / 1.25, 0.001)
        default:
            if !handleCharacter(event) {
                super.keyDown(with: event)
                return
            }
        }
        changed()
    }

    private func handleCharacter(_ event: NSEvent) -> Bool {
        guard let characters = event.characters?.lowercased() else { return false }
        switch characters {
        case "c":
            renderer.colorMode = renderer.colorMode == .smooth ? .banded : .smooth
        case "p":
            renderer.palette = (renderer.palette + 1) % Renderer.paletteCount
        case "h":
            hud.isHidden.toggle()
        case "r":
            renderer.reset()
        case "i":
            invertScroll.toggle()
        case "+", "=":
            zoom(by: 0.5, around: .zero)
        case "-":
            zoom(by: 2.0, around: .zero)
        case "]":
            renderer.iterationFactor = min(renderer.iterationFactor * 1.5, 64)
        case "[":
            renderer.iterationFactor = max(renderer.iterationFactor / 1.5, 1.0 / 16)
        default:
            return false
        }
        return true
    }

    // MARK: - HUD

    private func updateHUD() {
        guard !hud.isHidden, let renderer else { return }
        let viewport = renderer.viewport
        let factor = renderer.iterationFactor
        let iterationNote = abs(factor - 1) < 1e-9 ? "auto" : String(format: "auto ×%.2f", factor)
        var lines = [
            String(format: "Zoom  %.3e×", renderer.currentZoom),
            String(format: "Re   %+.17f", viewport.centerX),
            String(format: "Im   %+.17f", viewport.centerY),
            "Iter  \(renderer.maxIterations) (\(iterationNote))",
            "Mode  \(renderer.usesDoubleFloat ? "DF64" : "FP32") · \(renderer.colorMode == .smooth ? "smooth" : "banded") · palette \(renderer.palette + 1)/\(Renderer.paletteCount)",
            String(format: "GPU   %.1f ms  ", renderer.lastGPUTime * 1000)
                + "\(Int(renderer.drawableSize.width))×\(Int(renderer.drawableSize.height)) px",
        ]
        if viewport.isAtPrecisionLimit {
            lines.append("⚠︎ precision limit reached")
        }
        lines.append("")
        lines.append("scroll zoom · drag pan · double-click zoom (⇧ out)")
        lines.append("C colour · P palette · ↑↓ iterations · ←→ density")
        lines.append("+/- zoom · I invert scroll · R reset · H hide")
        hud.text = lines.joined(separator: "\n")
    }
}
