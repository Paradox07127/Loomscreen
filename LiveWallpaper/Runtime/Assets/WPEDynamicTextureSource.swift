#if !LITE_BUILD
import Foundation
import Metal

/// Shared interface for renderer-side texture sources whose content evolves
/// over time. Animated `.tex` (multi-frame sprite sheets) and `.tex`-embedded
/// MP4 video both implement it: current frame via `texture(at:)`, pause/resume
/// via `applyPerformanceProfile(_:)`, decode-resource release via `invalidate()`.
@MainActor
protocol WPEDynamicTextureSource: AnyObject {
    func texture(at time: TimeInterval) -> MTLTexture?
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile)
    func invalidate()
}
#endif
