#if !LITE_BUILD
import AppKit
import MetalKit
import LiveWallpaperCore

struct ShaderUniforms {
    var time: Float
    var resolution: SIMD2<Float>
    var shaderType: Int32
}

/// MSAA sample count. 4x is the sweet spot — kills smoothstep edge aliasing
/// on procedural shaders (Aurora bands, Waves foam, Noise transitions) at
/// retina backing-store rates without doubling shader cost like 8x would.
/// Tied to the pipeline `rasterSampleCount` and `MTKView.sampleCount`; both
/// must match or pipeline-state creation fails at runtime.
private let kMetalShaderSampleCount: Int = 4

enum CustomShaderCompileError: LocalizedError {
    case metalUnsupported
    case missingMainImage
    case compileFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .metalUnsupported:
            return String(localized: "Metal is not supported on this device.")
        case .missingMainImage:
            return String(localized: "Shader must define `mainImage(uv, time, resolution)`.")
        case .compileFailed(let message):
            return message
        }
    }
}

final class MetalWallpaperView: NSView, MTKViewDelegate {

    // MARK: - Properties

    private var metalView: MTKView?
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?

    /// Shaders.metal — cached so the custom-shader path can rebuild against it
    /// without re-loading.
    private var defaultLibrary: MTLLibrary?

    /// True when the pipeline currently bound to `pipelineState` was built
    /// from a runtime-compiled custom-shader library. `draw(in:)` skips the
    /// shaderType uniform write in that case (custom shaders don't dispatch).
    private var isUsingCustomPipeline: Bool = false

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
        self.defaultLibrary = device.makeDefaultLibrary()

        let mtkView = MTKView(frame: bounds, device: device)
        mtkView.delegate = self
        mtkView.preferredFramesPerSecond = 30
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.autoresizingMask = [.width, .height]
        mtkView.sampleCount = kMetalShaderSampleCount

        mtkView.wantsLayer = true
        mtkView.layer?.isOpaque = true

        addSubview(mtkView)
        self.metalView = mtkView

        rebuildBuiltinPipeline()
    }

    private func rebuildBuiltinPipeline() {
        guard let device, let library = defaultLibrary else {
            Logger.error("Failed to load default Metal library", category: .videoPlayer)
            return
        }
        do {
            pipelineState = try Self.makePipeline(
                device: device,
                library: library,
                vertexName: "vertexShader",
                fragmentName: "fragmentShader"
            )
            isUsingCustomPipeline = false
        } catch {
            Logger.error("Failed to create builtin Metal pipeline: \(error.localizedDescription)", category: .videoPlayer)
        }
    }

    nonisolated static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertexName: String,
        fragmentName: String
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunction = library.makeFunction(name: vertexName) else {
            throw CustomShaderCompileError.compileFailed(
                message: "Vertex function `\(vertexName)` not found."
            )
        }
        guard let fragmentFunction = library.makeFunction(name: fragmentName) else {
            throw CustomShaderCompileError.compileFailed(
                message: "Fragment function `\(fragmentName)` not found."
            )
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.rasterSampleCount = kMetalShaderSampleCount

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: - Public API

    /// Apply a `ShaderSource` — switches between builtin preset (default
    /// metallib) and user-imported shader (runtime compile). Builtin
    /// pipelines are pre-compiled, so the switch is synchronous; custom
    /// shaders compile off-main and swap the pipeline once ready.
    func apply(source: ShaderSource) {
        switch source {
        case .builtin(let preset):
            currentPreset = preset
            rebuildBuiltinPipeline()
        case .custom(let id):
            guard let entry = CustomShaderStore.shared.shader(for: id) else {
                Logger.warning("Custom shader \(id) not found in store — falling back to Waves", category: .videoPlayer)
                currentPreset = .waves
                rebuildBuiltinPipeline()
                return
            }
            scheduleCustomShaderInstall(source: entry.source, name: entry.displayName)
        }
    }

    private func scheduleCustomShaderInstall(source: String, name: String) {
        guard let device else {
            currentPreset = .waves
            rebuildBuiltinPipeline()
            return
        }
        let compileGeneration = nextCompileGeneration()
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let library = try Self.compileCustomShader(source: source, on: device)
                let pipeline = try Self.makePipeline(
                    device: device,
                    library: library,
                    vertexName: "vertexShader",
                    fragmentName: "fragmentShader"
                )
                await self?.adoptCustomPipeline(pipeline, name: name, generation: compileGeneration)
            } catch {
                Logger.error("Custom shader \(name) failed to compile: \(error.localizedDescription)", category: .videoPlayer)
                await self?.fallbackToWaves(generation: compileGeneration)
            }
        }
    }

    private func adoptCustomPipeline(_ pipeline: MTLRenderPipelineState, name: String, generation: Int) {
        guard generation == compileGeneration else { return }
        pipelineState = pipeline
        isUsingCustomPipeline = true
        Logger.info("Loaded custom shader '\(name)'", category: .videoPlayer)
    }

    private func fallbackToWaves(generation: Int) {
        guard generation == compileGeneration else { return }
        currentPreset = .waves
        rebuildBuiltinPipeline()
    }

    /// Monotonic token so an in-flight compile that finishes after the
    /// user has switched to another shader doesn't clobber the new state.
    private var compileGeneration: Int = 0
    private func nextCompileGeneration() -> Int {
        compileGeneration += 1
        return compileGeneration
    }

    /// Also used by the importer's pre-save validation step (the inspector
    /// calls this before persisting).
    nonisolated static func compileCustomShader(source: String, on device: MTLDevice) throws -> MTLLibrary {
        guard source.range(of: #"\bmainImage\b"#, options: .regularExpression) != nil else {
            throw CustomShaderCompileError.missingMainImage
        }

        let wrapped = Self.wrap(userSource: source)
        let options = MTLCompileOptions()

        do {
            return try device.makeLibrary(source: wrapped, options: options)
        } catch let error as NSError {
            let message = (error.userInfo["MTLLibraryErrorKey"] as? String)
                ?? error.localizedDescription
            throw CustomShaderCompileError.compileFailed(message: message)
        }
    }

    /// Canonical wrapper for user shaders. User code must define:
    ///
    ///     half4 mainImage(float2 uv, float time, float2 resolution) { ... }
    ///
    /// Everything else (vertex shader, uniforms struct, fragment dispatch)
    /// is supplied by the wrapper so users only write the fragment math.
    nonisolated private static func wrap(userSource: String) -> String {
        """
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
            float  time;
            float2 resolution;
            int    shaderType;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        vertex VertexOut vertexShader(uint vertexID [[vertex_id]]) {
            float2 positions[4] = {
                float2(-1.0, -1.0), float2( 1.0, -1.0),
                float2(-1.0,  1.0), float2( 1.0,  1.0)
            };
            float2 texCoords[4] = {
                float2(0.0, 1.0), float2(1.0, 1.0),
                float2(0.0, 0.0), float2(1.0, 0.0)
            };
            VertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.texCoord = texCoords[vertexID];
            return out;
        }

        // --- USER SHADER ----------------------------------------------------
        \(userSource)
        // --- END USER SHADER ------------------------------------------------

        fragment half4 fragmentShader(VertexOut in [[stage_in]],
                                      constant Uniforms &uniforms [[buffer(0)]]) {
            return mainImage(in.texCoord, uniforms.time, uniforms.resolution);
        }
        """
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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

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
            shaderType: isUsingCustomPipeline ? 0 : currentPreset.shaderTypeIndex
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        metalView?.frame = bounds
    }

}

extension MetalWallpaperView: WallpaperPerformanceConfigurable {}
#endif
