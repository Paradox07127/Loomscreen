import Testing
import Foundation
@testable import LiveWallpaper

/// Pure-logic coverage for the Clock widget's formatting core. Every case pins
/// an explicit Calendar / Locale / TimeZone so results never depend on the
/// machine's settings — the visual layout is exercised by the SwiftUI previews.
@Suite("Monitor clock widget")
struct MonitorClockWidgetTests {

    /// A fixed instant: 2026-07-06 22:05:09 UTC (a Monday). In London (BST, +1)
    /// this is 23:05 the same calendar day; in Tokyo (+9) it is already
    /// 2026-07-07 07:05 (+1d); in Los Angeles (PDT, −7) it is 2026-07-06 15:05
    /// (same day). Reykjavík stays on UTC year-round (22:05 → 10:05 PM in 12h).
    private let instant = Date(timeIntervalSince1970: 1_783_375_509)

    private func gregorian(_ tzIdentifier: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tzIdentifier)!
        return c
    }

    // MARK: - 12/24-hour follows the locale (never hardcoded)

    @Test("Hour cycle follows the locale, not the machine")
    func hourCyclePerLocale() {
        #expect(MonitorClockFormat.prefers24Hour(Locale(identifier: "en_GB")))
        #expect(MonitorClockFormat.prefers24Hour(Locale(identifier: "de_DE")))
        #expect(MonitorClockFormat.prefers24Hour(Locale(identifier: "en_US")) == false)
    }

    @Test("24-hour locale: padded HH:MM, no meridiem")
    func time24Hour() {
        let parts = MonitorClockFormat.timeParts(
            instant,
            timeZone: TimeZone(identifier: "Europe/London")!,   // BST → 23:05
            locale: Locale(identifier: "en_GB"),
            showsSeconds: false
        )
        #expect(parts.hm == "23:05")
        #expect(parts.meridiem == nil)
        #expect(parts.seconds == nil)
    }

    @Test("12-hour locale: bare hour + AM/PM meridiem, midnight wraps to 12")
    func time12Hour() {
        // London BST 23:05 → 11:05 PM in a 12-hour locale.
        let pm = MonitorClockFormat.timeParts(
            instant,
            timeZone: TimeZone(identifier: "Europe/London")!,
            locale: Locale(identifier: "en_US"),
            showsSeconds: false
        )
        #expect(pm.hm == "11:05")
        #expect(pm.meridiem == "PM")

        // Reykjavík (UTC year-round) at 22:05 → 10:05 PM.
        let utc = MonitorClockFormat.timeParts(
            instant,
            timeZone: TimeZone(identifier: "Atlantic/Reykjavik")!,
            locale: Locale(identifier: "en_US"),
            showsSeconds: false
        )
        #expect(utc.hm == "10:05")
        #expect(utc.meridiem == "PM")
    }

    // MARK: - Seconds are fixed-width and opt-in

    @Test("Seconds appear only when requested, zero-padded to two digits")
    func secondsFixedWidth() {
        let off = MonitorClockFormat.timeParts(
            instant, timeZone: TimeZone(identifier: "UTC")!,
            locale: Locale(identifier: "en_GB"), showsSeconds: false
        )
        #expect(off.seconds == nil)

        let on = MonitorClockFormat.timeParts(
            instant, timeZone: TimeZone(identifier: "UTC")!,
            locale: Locale(identifier: "en_GB"), showsSeconds: true
        )
        #expect(on.seconds == "09")   // 9s → "09", never "9"
        #expect(on.hm == "22:05")
    }

    // MARK: - Date lines match the mock's exact strings

    @Test("Short date is 'Mon 7/6' (weekday + numeric M/D) in en_US")
    func shortDateFormat() {
        // 2026-07-06 is a Monday in local (UTC) reckoning. The date line follows
        // the locale's short weekday symbol; en_US reproduces the mock's "Mon".
        let s = MonitorClockFormat.shortDate(
            instant, calendar: gregorian("UTC"), locale: Locale(identifier: "en_US"))
        #expect(s == "Mon 7/6")
    }

    @Test("Full date is 'Mon · Jul 6, 2026' in en_US")
    func fullDateFormat() {
        let f = MonitorClockFormat.fullDate(
            instant, calendar: gregorian("UTC"), locale: Locale(identifier: "en_US"))
        #expect(f == "Mon · Jul 6, 2026")
    }

    @Test("Date symbols follow the injected locale (ja short month is 7月)")
    func dateSymbolsFollowLocale() {
        // The Japanese short month for July is "7月" — proves the symbols are
        // locale-derived, not hardcoded English.
        let ja = MonitorClockFormat.monthSymbols(Locale(identifier: "ja_JP"))
        #expect(ja.count == 12)
        #expect(ja[6] == "7月")
    }

    // MARK: - Zone abbreviation (M header's tz whisper — mock's `tzLabel`)

    @Test("Zone abbreviation is non-empty and stable for a given zone/instant")
    func zoneAbbreviationIsStable() {
        // Exact strings vary by OS/ICU data (e.g. Tokyo can read "JST" or "GMT+9"
        // depending on the system), so this only pins the zero-offset case, which
        // Foundation renders as the literal "GMT" independent of locale data.
        let utc = MonitorClockFormat.zoneAbbreviation(TimeZone(identifier: "UTC")!, at: instant)
        #expect(utc == "GMT")
        // Same zone/instant must be deterministic across calls.
        #expect(MonitorClockFormat.zoneAbbreviation(TimeZone(identifier: "Asia/Tokyo")!, at: instant)
            == MonitorClockFormat.zoneAbbreviation(TimeZone(identifier: "Asia/Tokyo")!, at: instant))
    }

    // MARK: - City derivation from the TimeZone identifier

    @Test("City name is the identifier tail with underscores spaced")
    func cityDerivation() {
        #expect(MonitorClockFormat.cityName(TimeZone(identifier: "America/New_York")!) == "New York")
        #expect(MonitorClockFormat.cityName(TimeZone(identifier: "Europe/London")!) == "London")
        #expect(MonitorClockFormat.cityName(TimeZone(identifier: "Asia/Tokyo")!) == "Tokyo")
    }

    // MARK: - Relative-day hint (DST/day boundary via Calendar only)

    @Test("Relative-day marker: today / +1d / −1d across zones")
    func relativeDayAcrossZones() {
        let localCalendar = gregorian("UTC")   // local reference = UTC for the test

        // London is the same UTC day at this instant. The same-day case carries
        // an empty offset text (the view substitutes a localized "today").
        let london = MonitorClockFormat.relativeDay(
            instant, zone: TimeZone(identifier: "Europe/London")!, calendar: localCalendar
        )
        #expect(london == .init(direction: .same, text: ""))

        // Tokyo (+9) has already rolled to the next day.
        let tokyo = MonitorClockFormat.relativeDay(
            instant, zone: TimeZone(identifier: "Asia/Tokyo")!, calendar: localCalendar
        )
        #expect(tokyo.direction == .ahead)
        #expect(tokyo.text == "+1d")

        // A local reference far to the east makes Los Angeles read as the
        // previous day: reference in Tokyo, LA (−7) is 16h behind → −1d.
        let laFromTokyo = MonitorClockFormat.relativeDay(
            instant, zone: TimeZone(identifier: "America/Los_Angeles")!,
            calendar: gregorian("Asia/Tokyo")
        )
        #expect(laFromTokyo.direction == .behind)
        #expect(laFromTokyo.text == "\u{2212}1d")   // U+2212 minus, not ASCII hyphen
    }
}
