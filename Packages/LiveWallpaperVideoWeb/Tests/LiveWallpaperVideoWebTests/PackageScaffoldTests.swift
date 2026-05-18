import CoreGraphics
import Testing
@testable import LiveWallpaperVideoWeb

/// Phase 2b smoke tests — first real content types in the VideoWeb package.
@Suite("LiveWallpaperVideoWeb basic content")
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

    @Test("VideoAudioLeadershipPolicy mutes all duplicate-source followers")
    func leadershipPolicyMutesFollowers() {
        let entries: [VideoAudioLeadershipPolicy.Entry] = [
            .init(screenID: 1, urlKey: "alpha", userMuted: false),
            .init(screenID: 2, urlKey: "alpha", userMuted: false),
            .init(screenID: 3, urlKey: "beta", userMuted: false)
        ]
        let result = VideoAudioLeadershipPolicy.effectiveMutedStates(for: entries)
        let leaderIDs = [result[1], result[2]].compactMap { $0 }.filter { !$0 }.count
        let mutedCount = [result[1], result[2]].compactMap { $0 }.filter { $0 }.count
        #expect(leaderIDs == 1, "Exactly one screen in the duplicate group must remain unmuted.")
        #expect(mutedCount == 1, "The other duplicate-group entry must be muted.")
        #expect(result[3] == false, "Singletons keep the user's mute preference.")
    }
}
