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

    /// Decide what to do for the given configuration at the given hour.
    ///
    /// - `.applySlot` — switch to the slot's bookmark (only when it differs
    ///   from what's currently playing).
    /// - `.restorePrimary` — currently playing is a scheduled bookmark whose
    ///   slot no longer covers the current hour; restore the user's primary.
    /// - `.none` — already playing the right thing, or no schedule configured.
    static func decision(for configuration: ScreenConfiguration, hour: Int) -> Decision {
        // Mode gate: schedule automation is silent unless the user picked
        // .schedule explicitly. Avoids restoring primary when the active
        // bookmark happens to coincide with a schedule slot bookmark while
        // the user is actually in playlist mode.
        guard configuration.wallpaperMode == .schedule,
              let slots = configuration.scheduleSlots, !slots.isEmpty else {
            return .none
        }

        let activeBookmark = configuration.videoBookmarkData

        if let slot = activeSlot(in: slots, hour: hour),
           let bookmark = slot.videoBookmarkData {
            if activeBookmark == bookmark {
                return .none
            }
            return .applySlot(slot: slot, bookmarkData: bookmark)
        }

        // No active slot. If we're CURRENTLY playing a scheduled-slot bookmark,
        // the slot window has ended — fall back to primary.
        if let activeBookmark,
           slots.contains(where: { $0.videoBookmarkData == activeBookmark }),
           let primary = configuration.savedVideoBookmarkData,
           activeBookmark != primary {
            return .restorePrimary(bookmarkData: primary)
        }

        return .none
    }

    /// Legacy helper kept for backward compatibility. Prefer `decision(for:hour:)`.
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
    /// Midnight-wrapping slots are decomposed into 1-2 non-wrapping ranges first.
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
    /// Returns 2 ranges when wrapping past midnight; empty when `start == end`.
    static func hourRanges(for slot: ScheduleSlot) -> [Range<Int>] {
        let s = clampHour(slot.startHour)
        let e = clampHour(slot.endHour)
        if s == e { return [] }
        if s < e { return [s..<e] }
        return [s..<24, 0..<e]
    }

    /// Longest contiguous free range outside `slots`, at least `minHours` long.
    /// Used by Add Slot to auto-pick a non-conflicting window.
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
