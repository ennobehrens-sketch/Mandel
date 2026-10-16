import MetalKit

enum RendererError: Error {
    case noMetalDevice
    case missingFunction(String)
}

enum ColorMode: UInt32 {
    case smooth = 0
    case banded = 1
}

/// Must match `Uniforms` in the shader source field for field.
struct Uniforms {
    var cxHi: Float
    var cxLo: Float
    var cyHi: Float
    var cyLo: Float
    var scaleHi: Float
    var scaleLo: Float
    var width: Float
    var height: Float
    var maxIter: UInt32
    var colorMode: UInt32
    var palette: UInt32
    var colorDensity: Float
}

final class Renderer: NSObject, MTKViewDelegate {
    static let paletteCount: UInt32 = 4
    /// Units per pixel below which plain float runs out of precision.
    static let doubleFloatThreshold = 1e-5
    static let maxIterationLimit = 50_000

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelineFP32: MTLRenderPipelineState
    private let pipelineDF64: MTLRenderPipelineState

    var viewport = Viewport()
    var colorMode: ColorMode = .smooth
    var palette: UInt32 = 0
    var colorDensity: Float = 0.02
    /// Manual multiplier on top of the automatic iteration count.
    var iterationFactor: Double = 1.0

    private(set) var drawableSize = CGSize.zero
    private(set) var lastGPUTime: Double = 0
    var onFrameCompleted: (() -> Void)?

    private var hasFitted = false
    // At most one frame in flight: input that arrives meanwhile is coalesced
    // into a single redraw, so slow deep frames never queue up behind each other.
    private var frameInFlight = false
    private var redrawPending = false

    init(view: MTKView) throws {
        guard let device = view.device, let queue = device.makeCommandQueue() else {
            throw RendererError.noMetalDevice
        }
        self.device = device
        self.queue = queue
        pipelineFP32 = try Self.makePipeline(device: device, pixelFormat: view.colorPixelFormat, doubleFloat: false)
        pipelineDF64 = try Self.makePipeline(device: device, pixelFormat: view.colorPixelFormat, doubleFloat: true)
        super.init()
    }

    private static func makePipeline(device: MTLDevice, pixelFormat: MTLPixelFormat, doubleFloat: Bool) throws -> MTLRenderPipelineState {
        let options = MTLCompileOptions()
        options.preprocessorMacros = ["MANDEL_DF": NSNumber(value: doubleFloat ? 1 : 0)]
        // Fast-math may reassociate (a + b) - a to b, which silently destroys the
        // error terms of double-float arithmetic. Only the FP32 path may use it.
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) {
            options.mathMode = doubleFloat ? .safe : .fast
        } else {
            options.fastMathEnabled = !doubleFloat
        }
        #else
        options.fastMathEnabled = !doubleFloat
        #endif

        let library = try device.makeLibrary(source: shaderSource, options: options)
        guard let vertexFunction = library.makeFunction(name: "vertex_main") else {
            throw RendererError.missingFunction("vertex_main")
        }
        guard let fragmentFunction = library.makeFunction(name: "fragment_main") else {
            throw RendererError.missingFunction("fragment_main")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: - Derived state

    var usesDoubleFloat: Bool { viewport.scale < Self.doubleFloatThreshold }

    var currentZoom: Double {
        let minDimension = Double(min(drawableSize.width, drawableSize.height))
        return minDimension > 0 ? viewport.zoomLevel(minDimension: minDimension) : 1
    }

    /// Deeper zooms need more iterations to resolve the boundary.
    var maxIterations: Int {
        let automatic = 200 + 250 * log10(max(currentZoom, 1))
        return Int(min(max(automatic * iterationFactor, 32), Double(Self.maxIterationLimit)))
    }

    func reset() {
        iterationFactor = 1
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        viewport.fit(width: Double(drawableSize.width), height: Double(drawableSize.height))
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        if frameInFlight {
            redrawPending = true
            return
        }
        let size = view.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        drawableSize = size
        if !hasFitted {
            viewport.fit(width: Double(size.width), height: Double(size.height))
            hasFitted = true
        }

        guard let passDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else { return }

        var uniforms = makeUniforms(size: size)
        encoder.setRenderPipelineState(usesDoubleFloat ? pipelineDF64 : pipelineFP32)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)

        frameInFlight = true
        commandBuffer.addCompletedHandler { [weak self, weak view] buffer in
            let gpuTime = buffer.gpuEndTime - buffer.gpuStartTime
            DispatchQueue.main.async {
                guard let self else { return }
                self.frameInFlight = false
                self.lastGPUTime = gpuTime
                self.onFrameCompleted?()
                if self.redrawPending {
                    self.redrawPending = false
                    view?.needsDisplay = true
                }
            }
        }
        commandBuffer.commit()
    }

    private func makeUniforms(size: CGSize) -> Uniforms {
        let (cxHi, cxLo) = splitDouble(viewport.centerX)
        let (cyHi, cyLo) = splitDouble(viewport.centerY)
        let (scaleHi, scaleLo) = splitDouble(viewport.scale)
        return Uniforms(
            cxHi: cxHi, cxLo: cxLo,
            cyHi: cyHi, cyLo: cyLo,
            scaleHi: scaleHi, scaleLo: scaleLo,
            width: Float(size.width), height: Float(size.height),
            maxIter: UInt32(maxIterations),
            colorMode: colorMode.rawValue,
            palette: palette,
            colorDensity: colorDensity
        )
    }
}
