import AppKit
import MetalKit

/// Uniforms passed to the Metal shader on every frame.
struct ShaderUniforms {
    var time: Float
    var resolution: SIMD2<Float>
    var shaderType: Int32
}

/// Metal-based procedural shader wallpaper renderer.
/// Embeds an `MTKView` and drives it at 30 FPS with a full-screen quad
/// rendered by a fragment shader that switches between visual presets.
final class MetalWallpaperView: NSView, MTKViewDelegate {

    // MARK: - Properties

    private var metalView: MTKView?
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?

    private var startTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var currentPreset: MetalShaderPreset = .waves

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupMetal()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Metal Setup

    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Logger.error("Metal is not supported on this device", category: .videoPlayer)
            return
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()

        // Create and configure the MTKView.
        let mtkView = MTKView(frame: bounds, device: device)
        mtkView.delegate = self
        mtkView.preferredFramesPerSecond = 30
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.autoresizingMask = [.width, .height]

        // Transparent layer so the window behind shows through if needed.
        mtkView.wantsLayer = true
        mtkView.layer?.isOpaque = true

        addSubview(mtkView)
        self.metalView = mtkView

        buildPipeline(device: device)
    }

    private func buildPipeline(device: MTLDevice) {
        guard let library = device.makeDefaultLibrary() else {
            Logger.error("Failed to load default Metal library", category: .videoPlayer)
            return
        }

        guard let vertexFunction = library.makeFunction(name: "vertexShader"),
              let fragmentFunction = library.makeFunction(name: "fragmentShader") else {
            Logger.error("Failed to find shader functions in Metal library", category: .videoPlayer)
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            Logger.error("Failed to create Metal pipeline state: \(error.localizedDescription)", category: .videoPlayer)
        }
    }

    // MARK: - Public API

    /// Switch the shader preset displayed by this view.
    func setPreset(_ preset: MetalShaderPreset) {
        currentPreset = preset
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        guard let metalView else { return }

        switch profile {
        case .quality:
            metalView.preferredFramesPerSecond = profile.shaderFramesPerSecond
            metalView.enableSetNeedsDisplay = false
            metalView.isPaused = false
        case .suspended:
            metalView.isPaused = true
            metalView.enableSetNeedsDisplay = false
            metalView.releaseDrawables()
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // No additional work needed; resolution is sent as a uniform.
    }

    func draw(in view: MTKView) {
        guard let pipelineState = pipelineState,
              let commandQueue = commandQueue,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else {
            return
        }

        let elapsed = Float(CFAbsoluteTimeGetCurrent() - startTime)
        let drawableSize = view.drawableSize

        var uniforms = ShaderUniforms(
            time: elapsed,
            resolution: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
            shaderType: shaderTypeIndex(for: currentPreset)
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)

        // Pass uniforms to the fragment shader at buffer index 0.
        // Use .stride (not .size) for proper Metal alignment
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)

        // Draw a full-screen quad (4 vertices as triangle strip -- vertex positions
        // are generated in the vertex shader from vertex_id).
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        SystemMonitor.shared.tickFrame()
    }

    // MARK: - Helpers

    private func shaderTypeIndex(for preset: MetalShaderPreset) -> Int32 {
        switch preset {
        case .waves:    return 0
        case .plasma:   return 1
        case .gradient: return 2
        case .noise:    return 3
        case .aurora:   return 4
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        metalView?.frame = bounds
    }

    // MARK: - Cleanup

    deinit {
        // AppKit handles subview cleanup when the view is deallocated.
        // Mutating delegate and calling removeFromSuperview() from nonisolated
        // deinit is not allowed under strict concurrency.
    }
}

extension MetalWallpaperView: WallpaperPerformanceConfigurable {}
