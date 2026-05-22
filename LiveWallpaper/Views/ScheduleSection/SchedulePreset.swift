import Foundation
import SwiftUI
import LiveWallpaperCore

/// Time-of-day preset users can apply from the `+ Add Slot ▾` menu.
///
/// Each preset suggests a default `(start, end)` matching common waking
/// rhythms. The label is stored verbatim in `ScheduleSlot.label` so it
/// rounds-trips through `localizedLabel` and renders in the user's locale.
enum SchedulePreset: String, Identifiable, CaseIterable {
    case morning
    case midday
    case afternoon
    case evening
    case night

    var id: String { rawValue }

    /// Canonical `(startHour, endHour)` for the preset. Storage matches
    /// `ScheduleSlot.containsHour` semantics — `endHour` is exclusive and
    /// the night preset deliberately wraps midnight.
    var hours: (start: Int, end: Int) {
        switch self {
        case .morning:   return (6, 12)
        case .midday:    return (11, 14)
        case .afternoon: return (12, 18)
        case .evening:   return (18, 22)
        case .night:     return (22, 6)
        }
    }

    /// English key written to `ScheduleSlot.label`. Resolved at display
    /// time by `ScheduleSlot.localizedLabel` so every locale renders the
    /// translated form.
    var labelKey: String {
        switch self {
        case .morning:   return "Morning"
        case .midday:    return "Midday"
        case .afternoon: return "Afternoon"
        case .evening:   return "Evening"
        case .night:     return "Night"
        }
    }

    var localized: String {
        switch self {
        case .morning:
            return String(localized: "Morning", defaultValue: "Morning", comment: "Default schedule slot name.")
        case .midday:
            return String(localized: "Midday", defaultValue: "Midday", comment: "Default schedule slot name.")
        case .afternoon:
            return String(localized: "Afternoon", defaultValue: "Afternoon", comment: "Default schedule slot name.")
        case .evening:
            return String(localized: "Evening", defaultValue: "Evening", comment: "Default schedule slot name.")
        case .night:
            return String(localized: "Night", defaultValue: "Night", comment: "Default schedule slot name.")
        }
    }

    /// SF Symbol for menu icons. Picked to evoke the time of day without
    /// requiring a colored asset.
    var systemImage: String {
        switch self {
        case .morning:   return "sun.horizon"
        case .midday:    return "sun.max"
        case .afternoon: return "sun.haze"
        case .evening:   return "moon.haze"
        case .night:     return "moon.stars"
        }
    }

    /// True when this preset's hours would collide with any existing slot.
    /// Drives "disabled" state on the Add Slot menu so users see at a
    /// glance which presets are already filled.
    func conflicts(with existing: [ScheduleSlot]) -> Bool {
        let candidate = ScheduleSlot(startHour: hours.start, endHour: hours.end, label: labelKey)
        return !SchedulePolicy.conflicts(slot: candidate, against: existing).isEmpty
    }

    func makeSlot() -> ScheduleSlot {
        ScheduleSlot(startHour: hours.start, endHour: hours.end, label: labelKey)
    }

    /// Best-fit preset for a free hour cursor — used when the user
    /// double-taps an empty timeline cell to insert.
    static func suggestion(forStartHour hour: Int) -> SchedulePreset {
        switch hour {
        case 5..<11:  return .morning
        case 11..<14: return .midday
        case 14..<18: return .afternoon
        case 18..<22: return .evening
        default:      return .night
        }
    }
}

/// Locale-aware hour formatting shared across the schedule UI.
///
/// Uses `Date.FormatStyle.dateTime.hour()` — a `Sendable` format style —
/// rather than a long-lived `DateFormatter` static. `DateFormatter` is
/// thread-safe for `.string(from:)` after configuration but is not
/// `Sendable`; a static reference of one tripwires Swift 6 strict
/// concurrency the moment another call site reaches it off the main
/// actor.
enum ScheduleTimeFormatter {
    /// Locale-aware label for an hour cursor in `[0, 24]`. `24` is rendered
    /// the same as `0` ("12 AM") — the "(next day)" suffix is added by
    /// `rangeLabel` when wrap context matters.
    static func hourLabel(_ hour: Int) -> String {
        let calendar = Calendar.autoupdatingCurrent
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = ((hour % 24) + 24) % 24
        components.minute = 0
        guard let date = calendar.date(from: components) else { return "\(hour)" }
        return date.formatted(.dateTime.hour())
    }

    /// Full `"<start> — <end>"` label, suffixing `(next day)` whenever the
    /// slot wraps midnight so users immediately see the "+1 day" semantic.
    static func rangeLabel(startHour: Int, endHour: Int) -> String {
        let start = hourLabel(startHour)
        let end = hourLabel(endHour)
        if startHour > endHour {
            let nextDay = String(
                localized: "next day",
                defaultValue: "next day",
                comment: "Suffix appended to a schedule end-time when the slot wraps past midnight."
            )
            return "\(start) — \(end) (\(nextDay))"
        }
        return "\(start) — \(end)"
    }

    /// Compact end-hour label for picker rows: appends "(next day)" only
    /// when the candidate end would wrap from the current start.
    static func endHourMenuLabel(end: Int, start: Int) -> String {
        let base = hourLabel(end)
        if end <= start && start > 0 {
            let nextDay = String(
                localized: "next day",
                defaultValue: "next day",
                comment: "Suffix appended to a schedule end-time when the slot wraps past midnight."
            )
            return "\(base) (\(nextDay))"
        }
        return base
    }
}
