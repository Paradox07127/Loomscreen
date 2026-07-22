import Foundation

enum PlaylistPolicy {
    static func combinedPlaylist(primary: Data, additional: [Data]?) -> [Data]? {
        let full = [primary] + (additional ?? [])
        return full.count > 1 ? full : nil
    }

    static func nextCursor(
        currentCursor: Int,
        playlistCount: Int,
        shuffle: Bool,
        randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> Int? {
        guard playlistCount > 1 else { return nil }
        let normalized = ((currentCursor % playlistCount) + playlistCount) % playlistCount

        if shuffle {
            // A nonzero offset gives every alternative item equal probability.
            let offset = randomIndex(playlistCount - 1) + 1
            return (normalized + offset) % playlistCount
        }

        return (normalized + 1) % playlistCount
    }

    static func previousCursor(
        currentCursor: Int,
        playlistCount: Int,
        shuffle: Bool,
        randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> Int? {
        guard playlistCount > 1 else { return nil }
        let normalized = ((currentCursor % playlistCount) + playlistCount) % playlistCount

        if shuffle {
            let offset = randomIndex(playlistCount - 1) + 1
            return (normalized + offset) % playlistCount
        }

        return (normalized - 1 + playlistCount) % playlistCount
    }

    static func shouldRotate(
        now: Date,
        lastRotation: Date,
        rotationMinutes: Int
    ) -> Bool {
        guard rotationMinutes > 0 else { return false }
        return now.timeIntervalSince(lastRotation) >= Double(rotationMinutes) * 60.0
    }

    static func resolveCursor(activeBookmark: Data?, in combined: [Data]) -> Int {
        guard let activeBookmark else { return 0 }
        return combined.firstIndex(of: activeBookmark) ?? 0
    }
}
