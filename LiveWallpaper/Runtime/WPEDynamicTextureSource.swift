#if !LITE_BUILD
import Foundation
import Metal

/// Phase 2E: shared interface for renderer-side texture sources whose
/// content evolves over time. Animated `.tex` (multi-frame sprite sheets)
/// and `.tex`-embedded MP4 video both expose their current frame through
/// `texture(at:)`, take advice from `applyPerformanceProfile(_:)` on
/// pause/resume, and release decode resources on `invalidate()`.
@MainActor
protocol WPEDynamicTextureSource: AnyObject {
    func texture(at time: TimeInterval) -> MTLTexture?
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile)
    func invalidate()
}
#endif
