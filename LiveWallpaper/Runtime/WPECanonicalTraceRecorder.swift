#if !LITE_BUILD && DEBUG
import CryptoKit
import Foundation
import Metal

/// DEBUG-only accumulator that mirrors the Windows RenderDoc oracle into the
/// shared `wpe.trace.v1` schema from the Mac Metal path.
///
/// The recorder is fed from the existing scene-debug hooks (not `.gputrace`):
/// the Swift render path still carries semantic names for passes, materials,
/// samplers, uniforms, texture fallbacks, and render targets — exactly what the
/// divergence engine needs to align against the Windows ground truth.
///
/// One `mac/trace.json` is written per scene load: passes accumulate during the
/// first rendered frame, then `finishFrame` serialises once and latches so the
/// live render loop never re-accumulates.
///
/// `@unchecked Sendable`: all mutable state (scene/frameComplete/passes/resources)
/// is guarded by `lock`, so the shared singleton is safe to touch from the render
/// thread and the end-of-frame flush. Mirrors `WPESceneDebugArtifacts`.
final class WPECanonicalTraceRecorder: @unchecked Sendable {
    static let shared = WPECanonicalTraceRecorder()

    struct TextureBindingInput {
        let slot: Int
        let name: String?
        let reference: WPETextureReference?
        let texture: MTLTexture?
        let fallbackToPrimary: Bool
    }

    private let lock = NSLock()
    private var scene: SceneContext?
    private var frameComplete = false
    private var passes: [[String: Any]] = []
    private var resources: ResourceTables = ResourceTables()

    private init() {}

    func beginScene(workshopID: String, projectJsonPath: String?, descriptor: String) {
        guard WPESceneDebugArtifacts.shared.isEnabled else { return }
        lock.lock()
        scene = SceneContext(workshopID: workshopID, projectJsonPath: projectJsonPath, descriptor: descriptor)
        frameComplete = false
        passes.removeAll(keepingCapacity: true)
        resources = ResourceTables()
        lock.unlock()
    }

    func recordCustomPass(
        pass: WPEPreparedRenderPass,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        result: WPEShaderCompileResult,
        textureBindings: [TextureBindingInput],
        packedUniformSlots: [SIMD4<Float>],
        usesObjectQuad: Bool
    ) {
        guard WPESceneDebugArtifacts.shared.isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard scene != nil, !frameComplete else { return }

        let ordinal = passes.count
        let target = destination.id
        let targetTexture = destination.texture
        let targetResource = renderTargetResourceID(target)
        let fragmentShaderID = shaderID(stage: "fs", stableInput: result.mslSource)
        let vertexShaderID = shaderID(stage: "vs", stableInput: result.vertexFunctionName)
        let packedBytes = packedUniformBytes(packedUniformSlots)
        let bufferResource = "buf-mac-pass-\(ordinal)"

        resources.renderTargets[targetResource] = renderTargetResource(target: target, texture: targetTexture, ordinal: ordinal)
        resources.buffers[bufferResource] = [
            "label": "Mac flat uniform slots pass \(ordinal)",
            "byteLength": packedBytes.count,
            "sha256": sha256Hex(packedBytes)
        ]
        resources.shaders[fragmentShaderID] = shaderResource(
            stage: "fragment",
            entryPoint: result.fragmentFunctionName,
            source: result.mslSource,
            path: "msl-\(pass.pass.id)-\(pass.pass.shader).metal",
            layout: result.uniformLayout,
            samplers: result.samplerNames
        )
        resources.shaders[vertexShaderID] = shaderResource(
            stage: "vertex",
            entryPoint: result.vertexFunctionName,
            source: result.vertexFunctionName,
            path: nil,
            layout: [],
            samplers: []
        )

        var textures: [[String: Any]] = []
        for binding in textureBindings.sorted(by: { $0.slot < $1.slot }) {
            let texID = textureResourceID(texture: binding.texture, fallbackKey: "\(ordinal)-\(binding.slot)")
            resources.textures[texID] = textureResource(
                id: texID, name: binding.name, reference: binding.reference, texture: binding.texture
            )
            textures.append([
                "stage": "fragment",
                "slot": binding.slot,
                "name": jsonOrNull(binding.name),
                "resource": texID,
                "reference": jsonOrNull(Self.describe(reference: binding.reference)),
                "fallback": binding.fallbackToPrimary,
                "width": jsonOrNull(binding.texture?.width),
                "height": jsonOrNull(binding.texture?.height),
                "format": jsonOrNull(binding.texture.map { pixelFormatName($0.pixelFormat) })
            ])
        }

        let draw: [String: Any] = [
            "topology": usesObjectQuad ? "object-quad" : "fullscreen-quad",
            "vertexCount": 4,
            "indexCount": NSNull(),
            "instanceCount": 1,
            "viewport": [0, 0, Double(targetTexture.width), Double(targetTexture.height), 0, 1] as [Double],
            "scissor": [Double]()
        ]
        let colorTargets: [[String: Any]] = [[
            "slot": 0,
            "resource": targetResource,
            "load": NSNull(),
            "store": "store",
            "target": describe(target: target)
        ]]
        let constantBuffer: [String: Any] = [
            "name": "mac_flat_slots",
            "stage": "fragment",
            "slot": 0,
            "resource": bufferResource,
            "rawBytesSha256": sha256Hex(packedBytes),
            "variables": uniformVariables(layout: result.uniformLayout, slots: packedUniformSlots),
            "packedSlots": packedUniformSlots.map { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] }
        ]
        let samplers: [[String: Any]] = result.samplerNames.enumerated().map { index, name in
            ["stage": "fragment", "slot": index, "name": name]
        }
        let state: [String: Any] = [
            "blend": NSNull(),
            "depth": NSNull(),
            "raster": NSNull(),
            "samplers": samplers
        ]
        let output: [String: Any] = [
            "resource": targetResource,
            "png": NSNull(),
            "sha256": NSNull(),
            "visualStats": ["note": "Per-pass RT hash filled from scenePassDumps when WPEDumpScenePasses captured this pass."]
        ]
        let passRecord: [String: Any] = [
            "ordinal": ordinal,
            "eventId": NSNull(),
            "layerId": jsonOrNull(layerID(forPassID: pass.pass.id)),
            "passId": pass.pass.id,
            "shaderName": pass.pass.shader,
            "draw": draw,
            "targets": ["color": colorTargets, "depth": NSNull()] as [String: Any],
            "textures": textures,
            "shaders": ["vs": vertexShaderID, "fs": fragmentShaderID],
            "constantBuffers": [constantBuffer],
            "state": state,
            "output": output
        ]
        passes.append(passRecord)
    }

    /// Best-effort: fill per-pass output hashes from the scene-target snapshots
    /// the executor collected. Only populated when `WPEDumpScenePasses` is on and
    /// this runs before `finishFrame` latches the trace.
    func recordPassOutputs(_ entries: [(label: String, texture: MTLTexture)]) {
        guard WPESceneDebugArtifacts.shared.isEnabled else { return }
        lock.lock()
        let shouldRecord = !frameComplete
        lock.unlock()
        guard shouldRecord else { return }

        // Read back + hash OUTSIDE the lock: getBytes on a scene-pass snapshot is
        // expensive and must never block recordCustomPass on the render thread.
        let hashed: [(label: String, sha256: String, visualStats: [String: Any])] = entries.compactMap { entry in
            guard let metrics = textureMetrics(entry.texture) else { return nil }
            return (entry.label, metrics.sha256, metrics.visualStats)
        }
        guard !hashed.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !frameComplete else { return }
        for item in hashed {
            // Match the first still-unhashed pass with this id, so repeated pass
            // ids (e.g. ping-pong blur) fill in draw order instead of colliding.
            guard let index = passes.firstIndex(where: {
                ($0["passId"] as? String) == item.label
                    && (($0["output"] as? [String: Any])?["sha256"] is NSNull)
            }) else { continue }
            var record = passes[index]
            var output = record["output"] as? [String: Any] ?? [:]
            output["sha256"] = item.sha256
            output["visualStats"] = item.visualStats
            record["output"] = output
            passes[index] = record
        }
    }

    /// Record one particle-system draw as a pass so the divergence engine can
    /// align it against WPE's POINTLIST particle passes. Particles render via a
    /// separate path (`drawParticles`) from the effect chain, so without this hook
    /// they show up only as "missing" WPE passes even though we render them.
    func recordParticlePass(
        index: Int,
        particleCount: Int,
        sprite: MTLTexture?,
        blendMode: String,
        target: MTLTexture,
        spriteSheet: (cols: Int, rows: Int, frames: Int, alphaMask: Bool)?
    ) {
        guard WPESceneDebugArtifacts.shared.isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard scene != nil, !frameComplete else { return }

        let ordinal = passes.count
        let targetResource = "rt-scene"
        resources.renderTargets[targetResource] = [
            "label": "scene", "width": target.width, "height": target.height,
            "format": pixelFormatName(target.pixelFormat), "lineage": [String]()
        ]
        let spriteID = textureResourceID(texture: sprite, fallbackKey: "particle-\(index)")
        resources.textures[spriteID] = textureResource(id: spriteID, name: "g_Texture0", reference: nil, texture: sprite)

        let textures: [[String: Any]] = [[
            "stage": "fragment", "slot": 0, "name": "g_Texture0", "resource": spriteID,
            "reference": NSNull(), "fallback": false,
            "width": jsonOrNull(sprite?.width), "height": jsonOrNull(sprite?.height),
            "format": jsonOrNull(sprite.map { pixelFormatName($0.pixelFormat) })
        ]]
        let draw: [String: Any] = [
            "topology": "particle", "vertexCount": particleCount, "indexCount": NSNull(),
            "instanceCount": particleCount,
            "viewport": [0, 0, Double(target.width), Double(target.height), 0, 1] as [Double],
            "scissor": [Double]()
        ]
        let colorTargets: [[String: Any]] = [[
            "slot": 0, "resource": targetResource, "load": "load", "store": "store"
        ]]
        var variables: [[String: Any]] = []
        if let sheet = spriteSheet {
            variables = [[
                "name": "g_SpriteSheet", "type": "vec4",
                "value": [Double(sheet.cols), Double(sheet.rows), Double(sheet.frames), sheet.alphaMask ? 1.0 : 0.0]
            ]]
        }
        let constantBuffer: [String: Any] = [
            "name": "particle", "stage": "fragment", "slot": 0, "variables": variables
        ]
        let state: [String: Any] = [
            "blend": ["mode": blendMode] as [String: Any], "depth": NSNull(), "raster": NSNull(),
            "samplers": [["stage": "fragment", "slot": 0, "name": "g_Texture0"]] as [[String: Any]]
        ]
        let output: [String: Any] = [
            "resource": targetResource, "png": NSNull(), "sha256": NSNull(),
            "visualStats": ["note": "particle pass (instanced quads, \(particleCount) alive)"]
        ]
        let passRecord: [String: Any] = [
            "ordinal": ordinal, "eventId": NSNull(), "layerId": NSNull(),
            "passId": "particle.\(index)", "shaderName": "particle/\(blendMode)",
            "draw": draw,
            "targets": ["color": colorTargets, "depth": NSNull()] as [String: Any],
            "textures": textures,
            "shaders": ["vs": "shader-vs-particle", "fs": "shader-fs-particle"],
            "constantBuffers": [constantBuffer],
            "state": state,
            "output": output
        ]
        passes.append(passRecord)
    }

    func finishFrame(
        outputTexture: MTLTexture,
        runtimeUniforms: WPEMetalRuntimeUniforms?,
        firstFrameStats: WPEMetalTextureVisualStats?,
        resolutionDiagnostics: WPEResolutionDiagnosticsSnapshot
    ) {
        guard WPESceneDebugArtifacts.shared.isEnabled else { return }
        lock.lock()
        guard let scene, !frameComplete else { lock.unlock(); return }
        frameComplete = true
        let passSnapshot = passes
        let resourceSnapshot = resources
        lock.unlock()

        // Everything below runs WITHOUT the lock: the final-texture readback and
        // JSON serialization must not stall a concurrent render-thread call.
        let width = outputTexture.width
        let height = outputTexture.height
        let finalHash = textureMetrics(outputTexture)?.sha256
        let missedRefs = resolutionDiagnostics.missedRefs

        let producer: [String: Any] = [
            "side": "mac-metal",
            "tool": "WPECanonicalTraceRecorder",
            "toolVersion": "1",
            "wpeVersion": "2.8.26",
            "appBuild": jsonOrNull(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        ]
        let assetRoots: [String] = scene.projectJsonPath.map { [URL(fileURLWithPath: $0).deletingLastPathComponent().path] } ?? []
        let sceneBlock: [String: Any] = [
            "workshopId": scene.workshopID,
            "projectJson": scene.projectJsonPath ?? "",
            "projectJsonSha256": jsonOrNull(scene.projectJsonPath.flatMap { sha256File(path: $0) }),
            "entryFile": jsonOrNull(scene.projectJsonPath.map { URL(fileURLWithPath: $0).lastPathComponent }),
            "assetRoots": assetRoots
        ]
        let determinism: [String: Any] = [
            "time": jsonOrNull(runtimeUniforms?.time),
            "daytime": jsonOrNull(runtimeUniforms?.daytime),
            "pointer": [runtimeUniforms?.pointerPosition.x ?? 0.5, runtimeUniforms?.pointerPosition.y ?? 0.5] as [Double],
            "audioMode": "zeroed",
            "mouseParallax": "centered"
        ]
        let firstMisses: [[String: Any]] = missedRefs.prefix(16).map {
            ["ref": $0.ref, "outcome": $0.finalOutcome.debugLabel]
        }
        let resolutionSummary: [String: Any] = [
            "events": resolutionDiagnostics.events.count,
            "resolved": resolutionDiagnostics.resolvedCount,
            "missing": missedRefs.count,
            "firstMisses": firstMisses
        ]
        let capture: [String: Any] = [
            "jobId": scene.workshopID,
            "mode": "shader-first",
            "frameOrdinal": 0,
            "resolution": ["width": width, "height": height],
            "wallpaperWindow": ["class": "MTKView", "hwnd": NSNull(), "pid": NSNull()] as [String: Any],
            "determinism": determinism,
            "resolutionSummary": resolutionSummary,
            "descriptor": scene.descriptor
        ]
        let renderTargets: [String: [String: Any]] = resourceSnapshot.renderTargets.isEmpty
            ? ["rt-scene": [
                "label": "scene", "width": width, "height": height,
                "format": pixelFormatName(outputTexture.pixelFormat), "lineage": [String]()
            ]]
            : resourceSnapshot.renderTargets
        let resourceBlock: [String: Any] = [
            "textures": resourceSnapshot.textures,
            "renderTargets": renderTargets,
            "buffers": resourceSnapshot.buffers,
            "shaders": resourceSnapshot.shaders
        ]
        let finalBlock: [String: Any] = [
            "resource": "rt-scene",
            "png": NSNull(),
            "sha256": jsonOrNull(finalHash),
            "visualStats": firstFrameStats.map(Self.visualStats) ?? NSNull()
        ]
        let trace: [String: Any] = [
            "schema": "wpe.trace.v1",
            "producer": producer,
            "scene": sceneBlock,
            "capture": capture,
            "resources": resourceBlock,
            "passes": passSnapshot,
            "final": finalBlock
        ]
        let passCount = passSnapshot.count

        guard JSONSerialization.isValidJSONObject(trace),
              let data = try? JSONSerialization.data(withJSONObject: trace, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            WPESceneDebugArtifacts.shared.appendLog("[canonical-trace] trace.json serialization failed", level: .error)
            return
        }
        WPESceneDebugArtifacts.shared.recordNote(name: "trace.json", contents: text)
        WPESceneDebugArtifacts.shared.appendLog("[canonical-trace] wrote trace.json passes=\(passCount)", level: .info)
    }

    // MARK: - Description helpers (mirror WPESceneDebugArtifacts)

    static func describe(reference: WPETextureReference?) -> String? {
        guard let reference else { return nil }
        switch reference {
        case .image(let path): return "image(\(path))"
        case .asset(let path): return "asset(\(path))"
        case .fbo(let name): return "fbo(\(name))"
        case .previous: return "previous"
        }
    }

    private func describe(target: WPEMetalTargetID) -> String {
        switch target {
        case .scene: return "scene"
        case .named(let name): return name
        }
    }

    private func renderTargetResourceID(_ target: WPEMetalTargetID) -> String {
        switch target {
        case .scene: return "rt-scene"
        case .named(let name): return "rt-\(safeID(name))"
        }
    }

    // MARK: - Resource builders

    private func shaderResource(
        stage: String, entryPoint: String, source: String,
        path: String?, layout: [WPEUniformSlot], samplers: [String]
    ) -> [String: Any] {
        let sourceHash = sha256Hex(Data(source.utf8))
        let reflectionSamplers: [[String: Any]] = samplers.enumerated().map { index, name in
            ["name": name, "slot": index, "type": "SAMPLER"]
        }
        let reflectionTextures: [[String: Any]] = samplers.enumerated().map { index, name in
            ["name": name, "slot": index, "type": "TEXTURE"]
        }
        let constantBlocks: [[String: Any]] = layout.isEmpty ? [] : [["name": "mac_flat_slots", "slot": 0, "type": "CBUFFER"]]
        let uniforms: [[String: Any]] = layout.map { slot in
            [
                "name": slot.name,
                "type": slot.glslType,
                "slot": slot.slot,
                "slotCount": slot.slotCount,
                "startOffset": slot.slot * MemoryLayout<SIMD4<Float>>.stride,
                "arrayLength": jsonOrNull(slot.arrayLength),
                "materialName": jsonOrNull(slot.materialName)
            ]
        }
        let reflection: [String: Any] = [
            "samplers": reflectionSamplers,
            "textures": reflectionTextures,
            "constantBlocks": constantBlocks,
            "uniforms": uniforms
        ]
        return [
            "stage": stage,
            "sourceLanguage": "MSL",
            "entryPoint": entryPoint,
            "sourcePath": jsonOrNull(path),
            "sourceSha256": sourceHash,
            "disassembly": ["path": jsonOrNull(path), "sha256": sourceHash] as [String: Any],
            "reflection": reflection
        ]
    }

    private func uniformVariables(layout: [WPEUniformSlot], slots: [SIMD4<Float>]) -> [[String: Any]] {
        layout.map { uniform in
            let floats: [Double] = (0..<max(uniform.slotCount, 0)).flatMap { offset -> [Double] in
                let index = uniform.slot + offset
                guard slots.indices.contains(index) else { return [] }
                let v = slots[index]
                return [Double(v.x), Double(v.y), Double(v.z), Double(v.w)]
            }
            var variable: [String: Any] = [
                "name": uniform.name,
                "type": uniform.glslType,
                "slot": uniform.slot,
                "slotCount": uniform.slotCount,
                "arrayLength": jsonOrNull(uniform.arrayLength),
                "materialName": jsonOrNull(uniform.materialName),
                "rawSlotFloats": floats
            ]
            switch uniform.glslType {
            case "float", "int", "bool":
                variable["value"] = jsonOrNull(floats.first)
            case "vec2": variable["value"] = Array(floats.prefix(2))
            case "vec3": variable["value"] = Array(floats.prefix(3))
            case "vec4": variable["value"] = Array(floats.prefix(4))
            case "mat4":
                let m = Array(floats.prefix(16))
                variable["value"] = m
                if m.count == 16 {
                    variable["matrix4x4"] = m
                    variable["matrixMajor"] = "row"
                }
            default:
                variable["value"] = floats
            }
            return variable
        }
    }

    private func textureResource(id: String, name: String?, reference: WPETextureReference?, texture: MTLTexture?) -> [String: Any] {
        [
            "label": name ?? Self.describe(reference: reference) ?? id,
            "sourcePath": jsonOrNull(Self.describe(reference: reference)),
            "width": jsonOrNull(texture?.width),
            "height": jsonOrNull(texture?.height),
            "format": jsonOrNull(texture.map { pixelFormatName($0.pixelFormat) }),
            "mips": jsonOrNull(texture?.mipmapLevelCount),
            "sha256": NSNull(),
            "png": NSNull()
        ]
    }

    private func renderTargetResource(target: WPEMetalTargetID, texture: MTLTexture, ordinal: Int) -> [String: Any] {
        [
            "label": describe(target: target),
            "width": texture.width,
            "height": texture.height,
            "format": pixelFormatName(texture.pixelFormat),
            "lineage": ["pass-\(String(format: "%04d", ordinal))"]
        ]
    }

    // MARK: - Texture metrics (best-effort, post-commit only)

    private func textureMetrics(_ texture: MTLTexture) -> (sha256: String, visualStats: [String: Any])? {
        guard let data = rgba8Bytes(texture) else { return nil }
        let stats = WPEMetalTextureVisualStats.analyze(texture: texture)
        let pixels = max(texture.width * texture.height, 1)
        let visualStats: [String: Any] = [
            "coverage": jsonOrNull(stats.map { Double($0.nonBlackPixelCount) / Double(pixels) }),
            "meanRGBA": NSNull(),
            "width": texture.width,
            "height": texture.height,
            "nonBlackPixelCount": jsonOrNull(stats?.nonBlackPixelCount),
            "nonTransparentPixelCount": jsonOrNull(stats?.nonTransparentPixelCount)
        ]
        return (sha256Hex(data), visualStats)
    }

    private static func visualStats(_ stats: WPEMetalTextureVisualStats) -> [String: Any] {
        [
            "coverage": Double(stats.nonBlackPixelCount) / Double(max(stats.width * stats.height, 1)),
            "meanRGBA": NSNull(),
            "width": stats.width,
            "height": stats.height,
            "nonBlackPixelCount": stats.nonBlackPixelCount,
            "nonTransparentPixelCount": stats.nonTransparentPixelCount,
            "nonBlackCoversFullFrame": stats.nonBlackCoversFullFrame
        ]
    }

    private func rgba8Bytes(_ texture: MTLTexture) -> Data? {
        // 4-byte RGBA/BGRA unorm only. Channel order does not matter for the hash
        // (it is self-consistent across Mac runs); HDR/float RTs are skipped.
        switch texture.pixelFormat {
        case .rgba8Unorm, .rgba8Unorm_srgb, .bgra8Unorm, .bgra8Unorm_srgb:
            break
        default:
            return nil
        }
        // getBytes is only valid for CPU-visible storage. Reading a private or
        // managed texture directly would return stale/garbage bytes on a discrete
        // GPU, so skip (and log) rather than hashing nonsense.
        guard texture.storageMode == .shared else {
            WPESceneDebugArtifacts.shared.appendLog(
                "[canonical-trace] skipped getBytes for non-shared texture (storageMode=\(texture.storageMode.rawValue))",
                level: .warning
            )
            return nil
        }
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        bytes.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            texture.getBytes(
                base,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
        }
        return Data(bytes)
    }

    // MARK: - Small helpers

    private func packedUniformBytes(_ slots: [SIMD4<Float>]) -> Data {
        var data = Data(capacity: slots.count * MemoryLayout<SIMD4<Float>>.stride)
        for slot in slots {
            for value in [slot.x, slot.y, slot.z, slot.w] {
                withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    private func pixelFormatName(_ format: MTLPixelFormat) -> String { "\(format.rawValue)" }

    private func layerID(forPassID passID: String) -> String? {
        guard let prefix = passID.split(separator: ".").first.map(String.init), prefix != passID else { return nil }
        return prefix
    }

    private func shaderID(stage: String, stableInput: String) -> String {
        "shader-\(stage)-\(sha256Hex(Data(stableInput.utf8)).prefix(16))"
    }

    private func textureResourceID(texture: MTLTexture?, fallbackKey: String) -> String {
        guard let texture else { return "tex-missing-\(safeID(fallbackKey))" }
        return "tex-\(UInt(bitPattern: ObjectIdentifier(texture).hashValue))"
    }

    private func safeID(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sha256File(path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return sha256Hex(data)
    }

    /// JSON-safe value: `NSNull` when `nil`, otherwise the wrapped value.
    private func jsonOrNull<T>(_ value: T?) -> Any { value ?? NSNull() }
    private static func jsonOrNull<T>(_ value: T?) -> Any { value ?? NSNull() }

    private struct SceneContext {
        let workshopID: String
        let projectJsonPath: String?
        let descriptor: String
    }

    private struct ResourceTables {
        var textures: [String: [String: Any]] = [:]
        var renderTargets: [String: [String: Any]] = [:]
        var buffers: [String: [String: Any]] = [:]
        var shaders: [String: [String: Any]] = [:]
    }
}
#endif
