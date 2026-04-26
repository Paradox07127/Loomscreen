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

    /// `nextCursor` 的对称版本：用户按 Previous 按钮时返回上一首。
    /// 在 shuffle 模式下随机选取一个不同于当前的索引（与 `nextCursor`
    /// 行为一致，避免连续两次落在同一首）。
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
}
