import CoreGraphics

/// Computes the effective mute state for video sessions that are rendering
/// the same media on multiple displays. User intent stays persisted per
/// screen; this policy only prevents duplicate runtime audio output.
public enum VideoAudioLeadershipPolicy {
    public struct Entry: Equatable, Sendable {
        public let screenID: CGDirectDisplayID
        public let urlKey: String?
        public let userMuted: Bool

        public init(screenID: CGDirectDisplayID, urlKey: String?, userMuted: Bool) {
            self.screenID = screenID
            self.urlKey = urlKey
            self.userMuted = userMuted
        }
    }

    public static func effectiveMutedStates(for entries: [Entry]) -> [CGDirectDisplayID: Bool] {
        var result = Dictionary(uniqueKeysWithValues: entries.map { ($0.screenID, $0.userMuted) })
        let groupedByURL = Dictionary(grouping: entries.filter { $0.urlKey != nil }, by: { $0.urlKey! })

        for group in groupedByURL.values where group.count > 1 {
            guard let leader = group.first(where: { !$0.userMuted }) else {
                for entry in group {
                    result[entry.screenID] = true
                }
                continue
            }

            for entry in group {
                result[entry.screenID] = entry.userMuted || entry.screenID != leader.screenID
            }
        }

        return result
    }
}
