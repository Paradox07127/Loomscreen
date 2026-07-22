import CoreGraphics
import Testing
@testable import LiveWallpaperCore

@Suite("Video audio leadership policy")
struct VideoAudioLeadershipPolicyTests {

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
