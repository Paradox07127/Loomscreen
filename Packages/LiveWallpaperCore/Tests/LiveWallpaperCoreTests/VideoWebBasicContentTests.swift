import CoreGraphics
import Testing
@testable import LiveWallpaperCore

@Suite("VideoWeb content")
struct VideoWebBasicContentTests {

    @Test("PlaybackTransitionRegistry bump generates monotonically increasing tokens")
    @MainActor
    func transitionBumpMonotonic() {
        let registry = PlaybackTransitionRegistry()
        let screen: CGDirectDisplayID = 12345
        let first = registry.bumpTransition(for: screen)
        let second = registry.bumpTransition(for: screen)
        #expect(second == first &+ 1)
        #expect(registry.isCurrentTransition(second, for: screen))
        #expect(!registry.isCurrentTransition(first, for: screen))
    }
}
