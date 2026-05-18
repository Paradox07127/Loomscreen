import Foundation

enum PlaylistPolicy {
    /// Combined playlist formed by `[primary] + additional`.
    static func combinedPlaylist(primary: Data, additional: [Data]?) -> [Data]? {
        let full = [primary] + (additional ?? [])
        return full.count > 1 ? full : nil
    }

    /// Compute the next cursor position.
    static func nextCursor(
        currentCursor: Int,
        playlistCount: Int,
        shuffle: Bool,
        randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> Int? {
        guard playlistCount > 1 else { return nil }
        let normalized = ((currentCursor % playlistCount) + playlistCount) % playlistCount

        if shuffle {
            var candidate = randomIndex(playlistCount)
            if candidate == normalized {
                candidate = (candidate + 1) % playlistCount
            }
            return candidate
        }

        return (normalized + 1) % playlistCount
    }

    /// Symmetric counterpart of `nextCursor` for the Previous button.
    static func previousCursor(
        currentCursor: Int,
        playlistCount: Int,
        shuffle: Bool,
        randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> Int? {
        guard playlistCount > 1 else { return nil }
        let normalized = ((currentCursor % playlistCount) + playlistCount) % playlistCount

        if shuffle {
            var candidate = randomIndex(playlistCount)
            if candidate == normalized {
                candidate = (candidate + playlistCount - 1) % playlistCount
            }
            return candidate
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

    /// Map the active bookmark to its index in a re-ordered playlist.
    static func resolveCursor(activeBookmark: Data?, in combined: [Data]) -> Int {
        guard let activeBookmark else { return 0 }
        return combined.firstIndex(of: activeBookmark) ?? 0
    }
}
