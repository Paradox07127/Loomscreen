import Foundation

enum PlaylistPolicy {
    /// Combined playlist formed by `[primary] + additional`.
    /// Returns `nil` if there are fewer than two entries (no rotation possible).
    static func combinedPlaylist(primary: Data, additional: [Data]?) -> [Data]? {
        let full = [primary] + (additional ?? [])
        return full.count > 1 ? full : nil
    }

    /// Compute the next cursor position. Returns `nil` when rotation is impossible.
    ///
    /// `currentCursor` is clamped to the valid range so a stale persisted value
    /// (e.g. playlist shrank since last rotation) still yields a sensible next.
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
    /// Shuffle mode picks a random index different from the current one.
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
    /// Returns 0 (primary) if not found, so reorder doesn't visually skip tracks.
    static func resolveCursor(activeBookmark: Data?, in combined: [Data]) -> Int {
        guard let activeBookmark else { return 0 }
        return combined.firstIndex(of: activeBookmark) ?? 0
    }
}
