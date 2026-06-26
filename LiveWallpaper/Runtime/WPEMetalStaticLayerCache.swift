#if !LITE_BUILD
import CoreGraphics
import Foundation
import Metal

/// Plan describing how a static layer's composites are cached: every named
/// target the layer produces (FBO/layerComposite) mapped to the index of its
/// last producer pass. ALL of them are cached + re-seeded, because skipping the
/// layer's compose/effect passes means a downstream consumer of ANY of them
/// (not just the final one) must still resolve to frame-invariant pixels.
struct WPEMetalStaticLayerCachePlan: Equatable, Sendable {
    let cachedTargets: [String: Int]
    let compositePassCount: Int
}

/// Decides whether a layer's composites are provably frame-invariant, so they
/// can be rendered once and reused. The cache is exact BY CONSTRUCTION only for
/// layers whose composite is a pure function of static inputs, so this is
/// deliberately ULTRA-conservative — anything it can't prove invariant is left
/// on the normal per-frame path (slower, never wrong).
///
/// A layer qualifies only when EVERY pass:
///   - uses a BUILTIN shader (a custom material shader could sample
///     g_Time/g_Pointer/g_AudioSpectrum/g_ModelMatrix even outside effects/);
///   - is not an effects/ or workshop/ animated shader;
///   - carries no animated authored constant;
///   - reads only frame-invariant textures: a non-dynamic image/asset, or an
///     FBO THIS layer already produced — never `.previous` (feedback) and never
///     a scene-alias FBO (`_rt_FullFrameBuffer`, which is the live scene output).
/// …and the layer itself has no puppet, no `animationLayers`, no animated alpha,
/// exactly one `.scene` pass, and ≥2 composite passes (the cost gate).
enum WPEMetalStaticLayerClassifier {
    static func cachePlan(
        for layer: WPEPreparedRenderLayer,
        dynamicTextureNames: Set<String>
    ) -> WPEMetalStaticLayerCachePlan? {
        guard layer.puppetModel == nil,
              layer.graphLayer.animationLayers.isEmpty,
              layer.graphLayer.geometry.alphaAnimation == nil,
              layer.graphLayer.localGeometry?.alphaAnimation == nil,
              !layer.passes.isEmpty else { return nil }

        var produced: Set<String> = []
        var lastProducer: [String: Int] = [:]
        var compositePassCount = 0
        var scenePassCount = 0

        for (index, pass) in layer.passes.enumerated() {
            guard let program = pass.shader,
                  program.isBuiltin,
                  !usesAnimatedShader(pass),
                  !hasAnimatedConstant(pass) else { return nil }

            for reference in textureReferences(for: pass) {
                switch reference {
                case .previous:
                    return nil
                case .image(let name), .asset(let name):
                    if dynamicTextureNames.contains(name) { return nil }
                case .fbo(let name):
                    if WPEMetalShaderInputs.isSceneAliasName(name) { return nil }
                    // An FBO this layer hasn't produced yet is another (possibly
                    // dynamic) layer's output → not invariant from here.
                    if !produced.contains(name) { return nil }
                }
            }

            switch pass.pass.target {
            case .scene:
                scenePassCount += 1
            case .layerComposite(let name), .fbo(let name):
                compositePassCount += 1
                produced.insert(name)
                lastProducer[name] = index
            }
        }

        guard scenePassCount == 1,
              compositePassCount >= 2,
              !lastProducer.isEmpty else { return nil }
        return WPEMetalStaticLayerCachePlan(
            cachedTargets: lastProducer,
            compositePassCount: compositePassCount
        )
    }

    static func usesAnimatedShader(_ pass: WPEPreparedRenderPass) -> Bool {
        let shader = pass.pass.shader.lowercased()
        return shader.contains("effects/") || shader.contains("workshop/")
    }

    /// An authored `.animated` constant evaluates per frame, so its composite is
    /// not invariant. (Runtime uniforms like g_Time are merged into every pass
    /// but unused by builtin static shaders; authored constants are the signal.)
    private static func hasAnimatedConstant(_ pass: WPEPreparedRenderPass) -> Bool {
        pass.pass.constants.values.contains { value in
            if case .animated = value { return true }
            return false
        }
    }

    private static func textureReferences(for pass: WPEPreparedRenderPass) -> [WPETextureReference] {
        var references: [WPETextureReference] = [pass.pass.source]
        references.append(contentsOf: pass.pass.textures.values)
        references.append(contentsOf: pass.pass.binds.values)
        references.append(contentsOf: pass.textureBindings.values)
        return references
    }
}

/// LRU bookkeeping for the cache's VRAM budget, separated from the texture store.
struct WPEMetalStaticLayerCacheLRU: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let bytes: Int
        let lastAccess: Int
    }

    let budgetBytes: Int
    private(set) var totalBytes = 0
    private(set) var entries: [String: Entry] = [:]
    private var clock = 0

    init(budgetBytes: Int) {
        self.budgetBytes = max(0, budgetBytes)
    }

    mutating func touch(_ key: String) {
        guard let entry = entries[key] else { return }
        clock += 1
        entries[key] = Entry(bytes: entry.bytes, lastAccess: clock)
    }

    @discardableResult
    mutating func admit(_ key: String, bytes: Int) -> [String] {
        guard bytes > 0, bytes <= budgetBytes else {
            remove(key)
            return []
        }
        clock += 1
        if let existing = entries[key] {
            totalBytes -= existing.bytes
        }
        entries[key] = Entry(bytes: bytes, lastAccess: clock)
        totalBytes += bytes

        var evicted: [String] = []
        while totalBytes > budgetBytes,
              let victim = entries.min(by: { lhs, rhs in
                  if lhs.value.lastAccess != rhs.value.lastAccess {
                      return lhs.value.lastAccess < rhs.value.lastAccess
                  }
                  return lhs.key < rhs.key
              })?.key {
            remove(victim)
            evicted.append(victim)
        }
        return evicted
    }

    mutating func remove(_ key: String) {
        if let existing = entries.removeValue(forKey: key) {
            totalBytes -= existing.bytes
        }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        totalBytes = 0
        clock = 0
    }
}

/// Retains every snapshot composite a static layer produces (keyed by FBO name),
/// bounded by an LRU VRAM budget over whole layers. Invalidated on scene reload /
/// sceneSize change.
final class WPEMetalStaticLayerCompositeCache {
    /// All cached composites for one layer (final + intermediate targets).
    struct CachedLayer {
        var texturesByTarget: [String: MTLTexture]
        let bytes: Int
    }

    private var cachedByLayerID: [String: CachedLayer] = [:]
    private var lru: WPEMetalStaticLayerCacheLRU

    init(budgetBytes: Int) {
        self.lru = WPEMetalStaticLayerCacheLRU(budgetBytes: budgetBytes)
    }

    func updateBudget(_ budgetBytes: Int) {
        guard lru.budgetBytes != max(0, budgetBytes) else { return }
        removeAll()
        lru = WPEMetalStaticLayerCacheLRU(budgetBytes: budgetBytes)
    }

    /// Returns the full set of cached composites for a layer ONLY when every
    /// planned target is present (a partial cache from a previous over-budget
    /// frame must not be used — it would leave some skipped target unseeded).
    func cachedLayer(for layerID: String, requiredTargets: Set<String>) -> CachedLayer? {
        guard let cached = cachedByLayerID[layerID],
              requiredTargets.isSubset(of: Set(cached.texturesByTarget.keys)) else {
            return nil
        }
        lru.touch(layerID)
        return cached
    }

    func canAdmit(bytes: Int) -> Bool {
        bytes > 0 && bytes <= lru.budgetBytes
    }

    @discardableResult
    func insert(
        layerID: String,
        texturesByTarget: [String: MTLTexture],
        bytes: Int
    ) -> [String] {
        cachedByLayerID[layerID] = CachedLayer(texturesByTarget: texturesByTarget, bytes: bytes)
        let evicted = lru.admit(layerID, bytes: bytes)
        for id in evicted where id != layerID {
            cachedByLayerID.removeValue(forKey: id)
        }
        return evicted
    }

    func removeAll() {
        cachedByLayerID.removeAll(keepingCapacity: false)
        lru.removeAll()
    }
}
#endif
