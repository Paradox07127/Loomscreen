#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal

/// Logical identity for a render target during one `render(...)` call.
/// `.scene` is the persistent output texture; `.named(_)` covers FBOs and
/// layer composites resolved through the pool.
enum WPEMetalTargetID: Hashable {
    case scene
    case named(String)

    init(target: WPERenderTarget) {
        switch target {
        case .scene:
            self = .scene
        case .fbo(let name), .layerComposite(let name):
            self = .named(name)
        }
    }
}

/// Frame-local state carried through one render pass dispatch. Tracks the
/// most recent texture written per logical target so `.previous` and
/// `.fbo(name)` references resolve to live data, and so a new render pass
/// can decide between `.clear` and `.load` for its color attachment.
struct WPEMetalFrameState {
    let output: MTLTexture
    let sceneSize: CGSize
    let cameraUniforms: WPEMetalCameraUniforms
    var latestSceneTexture: MTLTexture?
    var latestNamedTextures: [String: MTLTexture] = [:]
    var writtenTargets: Set<WPEMetalTargetID> = []
    /// Bumped on every scene-target write. Scene-alias snapshots
    /// (`_rt_FullFrameBuffer` etc.) are stamped with this so a later
    /// referencing pass can tell a stale capture from a current one — WPE
    /// re-captures the frame for every sampling layer, so a snapshot taken
    /// for one layer must not be reused after other layers drew to the scene
    /// (3521337568's filmgrain erased the beams/halo drawn after the shine
    /// chain's capture).
    var sceneWriteGeneration: Int = 0
    /// `sceneWriteGeneration` at the time each scene-alias snapshot was taken.
    /// An entry exists ONLY for snapshot-created textures; a real write to the
    /// same name (a chain rendering into `_rt_HalfFrameBuffer` as an actual
    /// target) removes it so the snapshot logic never clobbers real content.
    var sceneAliasSnapshotGenerations: [String: Int] = [:]
    /// Per-physical-texture initialization tracking: ping-pong's
    /// secondary texture is allocated lazily and may contain garbage on
    /// first use. Tracking by texture identity (not target) lets us decide
    /// whether `.load` is safe or whether we need `.clear` (or a blit-copy
    /// from the previous primary) before rendering a same-target pass that
    /// blends, culls, or rejects fragments via depth.
    var initializedTextures: Set<ObjectIdentifier> = []
    var depthTextures: [WPEMetalDepthTextureKey: MTLTexture] = [:]
    /// Identity of the output texture whose REFRACT snapshot is still current.
    /// Cleared the moment that same physical texture is written again, so a
    /// recycled output never inherits a stale snapshot.
    private var freshRefractionSnapshotOutputID: ObjectIdentifier?
    /// Scene-level camera parallax for this frame; object-quad (scene-targeted)
    /// draws translate each layer by `cameraParallax.pixelOffset(depth:…)`.
    var cameraParallax: WPECameraParallaxFrame = .neutral
    /// The executor's target pool, threaded so `resolve()` can honor a first-frame
    /// read of an unwritten but declared local FBO (see `resolve(.fbo)`). Optional
    /// so hand-built frame states (tests) omit it and keep the strict miss→throw.
    let renderTargetPool: WPEMetalRenderTargetPool?

    init(
        output: MTLTexture,
        sceneSize: CGSize,
        cameraUniforms: WPEMetalCameraUniforms = .identity,
        previousSceneTexture: MTLTexture? = nil,
        previousNamedTextures: [String: MTLTexture] = [:],
        renderTargetPool: WPEMetalRenderTargetPool? = nil
    ) {
        self.output = output
        self.sceneSize = sceneSize
        self.cameraUniforms = cameraUniforms
        self.latestSceneTexture = previousSceneTexture
        self.latestNamedTextures = previousNamedTextures
        self.renderTargetPool = renderTargetPool
    }

    func latestTexture(for targetID: WPEMetalTargetID) -> MTLTexture? {
        switch targetID {
        case .scene:
            return latestSceneTexture
        case .named(let name):
            return latestNamedTextures[name]
        }
    }

    var currentFrameSceneTexture: MTLTexture? {
        writtenTargets.contains(.scene) ? latestSceneTexture : nil
    }

    mutating func registerWrite(texture: MTLTexture, targetID: WPEMetalTargetID) {
        let textureID = ObjectIdentifier(texture)
        writtenTargets.insert(targetID)
        initializedTextures.insert(textureID)
        if freshRefractionSnapshotOutputID == textureID {
            freshRefractionSnapshotOutputID = nil
        }
        switch targetID {
        case .scene:
            latestSceneTexture = texture
            sceneWriteGeneration += 1
        case .named(let name):
            latestNamedTextures[name] = texture
            sceneAliasSnapshotGenerations.removeValue(forKey: name)
        }
    }

    mutating func markRefractionSnapshotFresh(for texture: MTLTexture) {
        freshRefractionSnapshotOutputID = ObjectIdentifier(texture)
    }

    func hasFreshRefractionSnapshot(for texture: MTLTexture) -> Bool {
        freshRefractionSnapshotOutputID == ObjectIdentifier(texture)
    }

    mutating func seedPreviousTexture(_ texture: MTLTexture, targetID: WPEMetalTargetID) {
        switch targetID {
        case .scene:
            latestSceneTexture = texture
        case .named(let name):
            latestNamedTextures[name] = texture
        }
    }

    mutating func markInitialized(_ texture: MTLTexture) {
        initializedTextures.insert(ObjectIdentifier(texture))
    }

    func hasInitialized(_ texture: MTLTexture) -> Bool {
        initializedTextures.contains(ObjectIdentifier(texture))
    }
}

struct WPEMetalPipelineKey: Hashable {
    let vertexName: String
    let fragmentName: String
    let blendMode: String
    let colorPixelFormat: MTLPixelFormat
    /// Every pipeline state must declare the same depth attachment
    /// format as the render pass that drives it. We default to `.invalid`
    /// for non-depth passes so Metal's API validation does not fail when a
    /// fullscreen copy without depth meets a pipeline that thought it had
    /// `.depth32Float` attached.
    let depthPixelFormat: MTLPixelFormat
}

struct WPEMetalDepthKey: Hashable {
    let depthTest: String
    let depthWrite: String
}

/// Per-frame depth-texture identity. Keys by (target, exact size) so a
/// scaled FBO's depth attachment matches its color attachment dimensions.
struct WPEMetalDepthTextureKey: Hashable {
    let targetID: WPEMetalTargetID
    let width: Int
    let height: Int
}
#endif
