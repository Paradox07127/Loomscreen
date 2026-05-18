import Foundation

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

    /// Decide whether to apply a slot, restore primary, or do nothing.
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

    /// Legacy helper kept for backward compatibility.
    static func scheduledBookmark(
        in configuration: ScreenConfiguration,
        hour: Int
    ) -> (slot: ScheduleSlot, bookmarkData: Data)? {
        guard case .applySlot(let slot, let bookmarkData) = decision(for: configuration, hour: hour) else {
            return nil
        }
        return (slot, bookmarkData)
    }

    // MARK: - Conflict Detection

    /// IDs of slots overlapping the given slot (excluding itself).
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
    static func findFreeRange(in slots: [ScheduleSlot], minHours: Int = 2) -> (start: Int, end: Int)? {
        var occupied = Array(repeating: false, count: 24)
        for slot in slots {
            for range in hourRanges(for: slot) {
                for h in range where h >= 0 && h < 24 {
                    occupied[h] = true
                }
            }
        }

        var bestStart = -1
        var bestLength = 0
        var index = 0
        while index < 24 {
            if !occupied[index] {
                var probe = index
                while probe < 24, !occupied[probe] { probe += 1 }
                let length = probe - index
                if length > bestLength {
                    bestLength = length
                    bestStart = index
                }
                index = probe
            } else {
                index += 1
            }
        }

        guard bestLength >= minHours, bestStart >= 0 else { return nil }
        return (bestStart, bestStart + bestLength)
    }

    private static func clampHour(_ hour: Int) -> Int {
        ((hour % 24) + 24) % 24
    }
}
