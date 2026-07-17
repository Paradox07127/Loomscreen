import Foundation
import LiveWallpaperCore

enum SchedulePolicy {
    enum Decision: Equatable {
        case none
        case applySlot(slot: ScheduleSlot, bookmarkData: Data)
        case restorePrimary(bookmarkData: Data)
    }

    static func activeSlot(in slots: [ScheduleSlot], hour: Int) -> ScheduleSlot? {
        let normalizedHour = ((hour % 24) + 24) % 24
        return slots.first { $0.containsHour(normalizedHour) }
    }

    static func decision(for configuration: ScreenConfiguration, hour: Int) -> Decision {
        guard configuration.wallpaperMode == .schedule,
              let slots = configuration.scheduleSlots, !slots.isEmpty else {
            return .none
        }

        let activeBookmark = configuration.activeWallpaper.activeVideoBookmarkData

        if let slot = activeSlot(in: slots, hour: hour),
           let bookmark = slot.videoBookmarkData {
            if activeBookmark == bookmark {
                return .none
            }
            return .applySlot(slot: slot, bookmarkData: bookmark)
        }

        if let activeBookmark,
           slots.contains(where: { $0.videoBookmarkData == activeBookmark }),
           let primary = configuration.savedVideoBookmarkData,
           activeBookmark != primary {
            return .restorePrimary(bookmarkData: primary)
        }

        return .none
    }

    // MARK: - Conflict Detection

    static func conflicts(slot: ScheduleSlot, against others: [ScheduleSlot]) -> Set<UUID> {
        let ours = hourRanges(for: slot)
        guard !ours.isEmpty else { return [] }

        var conflicting: Set<UUID> = []
        for other in others where other.id != slot.id {
            let theirs = hourRanges(for: other)
            outer: for ourRange in ours {
                for theirRange in theirs where ourRange.overlaps(theirRange) {
                    conflicting.insert(other.id)
                    break outer
                }
            }
        }
        return conflicting
    }

    /// Decompose a slot into `[start, end)` half-open ranges within 0-24.
    static func hourRanges(for slot: ScheduleSlot) -> [Range<Int>] {
        let s = clampHour(slot.startHour)
        let e = clampHour(slot.endHour)
        if s == e { return [] }
        if s < e { return [s..<e] }
        return [s..<24, 0..<e]
    }

    /// Longest contiguous free range outside `slots`, at least `minHours` long.
    ///
    /// Returns `(start, end)` where `start` is in `0..<24` and `end` may exceed
    /// 24 to encode a midnight-wrap gap (e.g. `(22, 28)` = 22:00 → 04:00).
    /// Callers should compute the slot's `endHour` as `end % 24`.
    static func findFreeRange(in slots: [ScheduleSlot], minHours: Int = 2) -> (start: Int, end: Int)? {
        var occupied = Array(repeating: false, count: 24)
        for slot in slots {
            for range in hourRanges(for: slot) {
                for h in range where h >= 0 && h < 24 {
                    occupied[h] = true
                }
            }
        }

        if !occupied.contains(true) {
            return minHours <= 24 ? (0, 24) : nil
        }
        if !occupied.contains(false) {
            return nil
        }

        var runs: [(start: Int, end: Int)] = []
        var index = 0
        while index < 24 {
            guard !occupied[index] else { index += 1; continue }
            let runStart = index
            while index < 24, !occupied[index] { index += 1 }
            runs.append((runStart, index))
        }

        // Stitch a leading 0-anchored run with a trailing 24-anchored run into a
        // single wrap-around range so the gap `23 → 1` is discoverable.
        if runs.count >= 2,
           let first = runs.first, first.start == 0,
           let last = runs.last, last.end == 24 {
            let leadingLength = first.end - first.start
            let trailingLength = last.end - last.start
            let wrap = (start: last.start, end: last.start + trailingLength + leadingLength)
            runs.removeFirst()
            runs.removeLast()
            runs.append(wrap)
        }

        var best: (start: Int, end: Int)?
        for run in runs {
            let length = run.end - run.start
            if length < minHours { continue }
            if let currentBest = best {
                if length > (currentBest.end - currentBest.start) {
                    best = run
                }
            } else {
                best = run
            }
        }
        return best
    }

    private static func clampHour(_ hour: Int) -> Int {
        ((hour % 24) + 24) % 24
    }
}
