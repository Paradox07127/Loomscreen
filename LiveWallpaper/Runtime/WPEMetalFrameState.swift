#if !LITE_BUILD
import CoreGraphics
import Foundation
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
    var latestSceneTexture: MTLTexture?
    var latestNamedTextures: [String: MTLTexture] = [:]
    var writtenTargets: Set<WPEMetalTargetID> = []
    /// Per-physical-texture init tracking. Phase 2C audit fix: ping-pong's
    /// secondary texture is allocated lazily and may contain garbage on
    /// first use. Tracking by texture identity (not target) lets us decide
    /// whether `.load` is safe or whether we need `.clear` (or a blit-copy
    /// from the previous primary) before rendering a same-target pass that
    /// blends, culls, or rejects fragments via depth.
    var initializedTextures: Set<ObjectIdentifier> = []
    var depthTextures: [WPEMetalDepthTextureKey: MTLTexture] = [:]

    init(
        output: MTLTexture,
        sceneSize: CGSize,
        previousSceneTexture: MTLTexture? = nil,
        previousNamedTextures: [String: MTLTexture] = [:]
    ) {
        self.output = output
        self.sceneSize = sceneSize
        self.latestSceneTexture = previousSceneTexture
        self.latestNamedTextures = previousNamedTextures
    }

    func latestTexture(for targetID: WPEMetalTargetID) -> MTLTexture? {
        switch targetID {
        case .scene:
            return latestSceneTexture
        case .named(let name):
            return latestNamedTextures[name]
        }
    }

    mutating func registerWrite(texture: MTLTexture, targetID: WPEMetalTargetID) {
        writtenTargets.insert(targetID)
        initializedTextures.insert(ObjectIdentifier(texture))
        switch targetID {
        case .scene:
            latestSceneTexture = texture
        case .named(let name):
            latestNamedTextures[name] = texture
        }
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
    /// Phase 2C audit fix: every PSO must declare the SAME depth attachment
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
