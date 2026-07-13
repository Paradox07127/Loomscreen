import SwiftUI
import LiveWallpaperCore

/// Clock widget — a 1:1 native port of the mock's Clock section (index.html
/// `clock_s` / `clock_m`). Time *is* the visualization: a typographic hero
/// (SF Rounded, tabular) ticking off the real clock, with a short date beneath.
///
/// Zero system sampling (SPEC §3.1): the widget is pure client-side time. Ticking
/// is driven by `context.now`, which the single board-level 1 Hz `TimelineView`
/// advances (no per-widget Timer); seconds-mode updates on that same board tick.
/// Nothing here touches the snapshot. 12/24-hour presentation follows the system
/// locale (never hardcoded); DST and day boundaries are resolved by the system
/// `Calendar`/`TimeZone`, never by hand-written date math.
///
/// Options (`placement.options`):
///   - `showsSeconds` (.bool, default false) — fixed-width seconds so the hero
///     never jitters.
///   - `worldClocks` (.stringList of TimeZone identifiers, default []) — capped
///     at 2 (M only): city · that zone's local time · a ±day relative hint.
struct MonitorClockWidgetView: View {
    let context: MonitorWidgetContext

    init(context: MonitorWidgetContext) {
        self.context = context
    }

    private var showsSeconds: Bool {
        context.placement.options["showsSeconds"]?.boolValue ?? false
    }

    /// World-clock TimeZone identifiers, resolved to real zones and capped at 2
    /// (the mock shows 1–2). Unknown identifiers are dropped, never faked.
    private var worldClocks: [TimeZone] {
        let ids = context.placement.options["worldClocks"]?.stringListValue ?? []
        return ids.compactMap(TimeZone.init(identifier:)).prefix(2).map { $0 }
    }

    var body: some View {
        GeometryReader { geo in
            let cellHeight = geo.size.height / 2   // both sizes are 2 rows tall
            // Time comes from `context.now` (board-level 1 Hz tick), decoupled from
            // the snapshot. Seconds-mode ticks on that same board cadence.
            let now = context.now
            MonitorWidgetContainer(
                label: "Clock",
                systemImage: "clock",
                cellHeight: cellHeight
            ) {
                if context.placement.size == .medium, !worldClocks.isEmpty {
                    // Timezone whisper only appears alongside world clocks
                    // (mock: `chd("CLOCK", tzLabel)` in M). tzLabel is the LOCAL
                    // system zone (the reference the world-clock rows and their
                    // relative-day hints are measured against), not a remote city.
                    Text(verbatim: MonitorClockFormat.zoneAbbreviation(.current, at: now))
                        .foregroundStyle(MonitorDesign.inkFaint)
                } else {
                    EmptyView()
                }
            } content: {
                switch context.placement.size {
                case .small:  smallBody(now: now, cellHeight: cellHeight)
                case .medium: mediumBody(now: now, cellHeight: cellHeight)
                case .large:  mediumBody(now: now, cellHeight: cellHeight)
                }
            }
        }
    }

    // MARK: - S (2×2)

    @ViewBuilder
    private func smallBody(now: Date, cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        VStack(alignment: .leading, spacing: max(3, cellHeight * 0.04)) {
            Spacer(minLength: 0)
            timeHero(now: now, in: .current, size: scale.hero * 1.02)
            Text(verbatim: MonitorClockFormat.shortDate(now, calendar: .current, locale: .current))
                .font(.system(size: scale.caption, weight: .regular, design: .rounded))
                .tracking(scale.caption * 0.03)
                .foregroundStyle(MonitorDesign.inkFaint)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - M (4×2)

    @ViewBuilder
    private func mediumBody(now: Date, cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        let zones = worldClocks
        VStack(alignment: .leading, spacing: max(6, cellHeight * 0.06)) {
            VStack(alignment: .leading, spacing: max(2, cellHeight * 0.02)) {
                timeHero(now: now, in: .current, size: scale.hero * 0.94)
                Text(verbatim: MonitorClockFormat.fullDate(now, calendar: .current, locale: .current))
                    .font(.system(size: scale.caption, weight: .regular, design: .rounded))
                    .tracking(scale.caption * 0.03)
                    .foregroundStyle(MonitorDesign.inkFaint)
            }
            if !zones.isEmpty {
                VStack(alignment: .leading, spacing: max(4, cellHeight * 0.05)) {
                    ForEach(Array(zones.enumerated()), id: \.offset) { _, tz in
                        worldClockRow(tz, now: now, size: scale.caption)
                    }
                }
                .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Pieces

    /// The typographic time hero: tabular HH:MM (+ optional fixed-width seconds,
    /// + a small AM/PM meridiem in 12-hour locales). Mirrors the mock's `.ct`.
    @ViewBuilder
    private func timeHero(now: Date, in zone: TimeZone, size: CGFloat) -> some View {
        let parts = MonitorClockFormat.timeParts(
            now, timeZone: zone, locale: .current, showsSeconds: showsSeconds
        )
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: parts.hm)
                .font(MonitorDesign.heroFont(size: size))
                .monospacedDigit()
                .kerning(-size * 0.02)
                .foregroundStyle(MonitorDesign.inkPrimary)
            if let seconds = parts.seconds {
                Text(verbatim: seconds)
                    .font(MonitorDesign.subFont(size: size * 0.42))
                    .monospacedDigit()
                    .foregroundStyle(MonitorDesign.inkFaint)
                    .padding(.leading, size * 0.14)
            }
            if let meridiem = parts.meridiem {
                Text(verbatim: meridiem)
                    .font(MonitorDesign.subFont(size: size * 0.34))
                    .tracking(size * 0.34 * 0.06)
                    .foregroundStyle(MonitorDesign.inkFaint)
                    .padding(.leading, size * 0.18)
            }
        }
    }

    /// One world-clock row: city (flex, truncating) · local time · relative-day
    /// hint. Mirrors the mock's `.wcrow` (city / wtime / wrel).
    @ViewBuilder
    private func worldClockRow(_ tz: TimeZone, now: Date, size: CGFloat) -> some View {
        let parts = MonitorClockFormat.timeParts(
            now, timeZone: tz, locale: .current, showsSeconds: false
        )
        let rel = MonitorClockFormat.relativeDay(now, zone: tz, calendar: .current)
        HStack(alignment: .firstTextBaseline, spacing: size * 0.6) {
            Text(verbatim: MonitorClockFormat.cityName(tz))
                .font(.system(size: size, weight: .medium, design: .rounded))
                .tracking(size * 0.04)
                .foregroundStyle(MonitorDesign.inkMuted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: parts.hm)
                    .monospacedDigit()
                    .kerning(-size * 0.01)
                if let meridiem = parts.meridiem {
                    Text(verbatim: meridiem)
                        .font(.system(size: size * 0.72, weight: .semibold, design: .rounded))
                        .tracking(size * 0.72 * 0.06)
                        .foregroundStyle(MonitorDesign.inkFaint)
                        .padding(.leading, size * 0.16)
                }
            }
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .foregroundStyle(MonitorDesign.inkPrimary)
            relativeText(rel)
                .font(.system(size: size * 0.82, weight: .regular, design: .rounded))
                .tracking(size * 0.82 * 0.03)
                .foregroundStyle(relativeColor(rel.direction))
                .frame(minWidth: size * 2.6, alignment: .trailing)
        }
    }

    /// The relative-day hint: a localized "today" for the same day (a word), or the
    /// numeric "+Nd" / "−Nd" offset verbatim (notation).
    private func relativeText(_ rel: MonitorClockFormat.RelativeDay) -> Text {
        rel.direction == .same
            ? Text("today", comment: "Clock world-clock row: the remote zone is on the same calendar day.")
            : Text(verbatim: rel.text)
    }

    private func relativeColor(_ direction: MonitorClockFormat.DayDirection) -> Color {
        switch direction {
        case .ahead: return MonitorDesign.oklch(0.72, 0.06, 78)   // .wrel.pos
        case .behind: return MonitorDesign.signalSteel            // .wrel.neg (--cool)
        case .same: return MonitorDesign.inkFaint
        }
    }
}

// MARK: - Formatting core (pure logic; unit-tested)

/// Pure clock formatting — a 1:1 port of the mock's `fmtClock` / `data-clock`
/// / `data-wclock` / `data-wrel` runtime, but built on the system `Calendar`,
/// `TimeZone` and `Locale` so 12/24-hour choice, DST and day boundaries are all
/// resolved by Foundation, never hand-written. Every entry point takes explicit
/// `Calendar`/`Locale`/`TimeZone` so tests never depend on machine settings.
enum MonitorClockFormat {

    /// Short weekday / month symbols for a locale, derived from the system
    /// `DateFormatter` (Sun…Sat, Jan…Dec in en; the localized forms elsewhere) so
    /// the date lines follow the user's language instead of hardcoded English.
    /// `en_US` reproduces the mock's exact "Mon"/"Jul" abbreviations.
    nonisolated static func weekdaySymbols(_ locale: Locale) -> [String] {
        let df = DateFormatter()
        df.locale = locale
        return df.shortStandaloneWeekdaySymbols ?? df.shortWeekdaySymbols
            ?? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    }

    nonisolated static func monthSymbols(_ locale: Locale) -> [String] {
        let df = DateFormatter()
        df.locale = locale
        return df.shortStandaloneMonthSymbols ?? df.shortMonthSymbols
            ?? ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    }

    struct TimeParts: Equatable {
        var hm: String
        /// Two-digit seconds when requested, else nil.
        var seconds: String?
        /// "AM"/"PM" in 12-hour locales, else nil.
        var meridiem: String?
    }

    enum DayDirection { case same, ahead, behind }

    struct RelativeDay: Equatable {
        var direction: DayDirection
        /// The numeric offset text ("+Nd" / "−Nd") — notation, rendered verbatim.
        /// The same-day case carries an empty string; the view substitutes a
        /// localized "today" (a word, not notation) when `direction == .same`.
        var text: String
    }

    /// Whether `locale` prefers a 24-hour clock. Derived from the locale's own
    /// time template (skeleton "j" resolves to the locale's hour field), so this
    /// follows the system rather than hardcoding — SPEC §3.1.
    nonisolated static func prefers24Hour(_ locale: Locale) -> Bool {
        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "H"
        // A 12-hour locale uses an 'h'/'K' hour FIELD; 24-hour uses 'H'/'k'.
        // Quoted literals must be skipped first — some 24-hour locales embed a
        // lowercase 'h' inside literal text (de_DE "HH 'Uhr'", fr_FR "HH 'h'"),
        // which a naive scan would misread as a 12-hour field.
        var inQuote = false
        for ch in template {
            if ch == "'" { inQuote.toggle(); continue }
            if inQuote { continue }
            if ch == "h" || ch == "K" { return false }
        }
        return true
    }

    /// Time-of-day components split into a tabular HH:MM core, optional
    /// fixed-width seconds, and an optional meridiem — the pieces the hero
    /// composes. Hours/minutes/seconds come from a `Calendar` pinned to `zone`,
    /// so DST is applied correctly for that instant.
    nonisolated static func timeParts(
        _ date: Date,
        timeZone: TimeZone,
        locale: Locale,
        showsSeconds: Bool
    ) -> TimeParts {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let comps = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour24 = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let second = comps.second ?? 0

        let use24 = prefers24Hour(locale)
        var meridiem: String?
        let displayHour: Int
        if use24 {
            displayHour = hour24
        } else {
            meridiem = hour24 < 12 ? "AM" : "PM"
            var h = hour24 % 12
            if h == 0 { h = 12 }
            displayHour = h
        }
        // 24h pads the hour to two digits; 12h shows a bare hour (mock parity).
        let hourString = use24 ? pad2(displayHour) : String(displayHour)
        return TimeParts(
            hm: "\(hourString):\(pad2(minute))",
            seconds: showsSeconds ? pad2(second) : nil,
            meridiem: meridiem
        )
    }

    /// Short date line "Mon 7/6" — localized weekday abbrev + numeric month/day
    /// (mock's `data-clock="short"`). The weekday symbol follows `locale`; the
    /// numeric M/D stay digits (the mock's compact form).
    nonisolated static func shortDate(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let comps = calendar.dateComponents([.weekday, .month, .day], from: date)
        let weekday = weekdaySymbols(locale)[safe: (comps.weekday ?? 1) - 1] ?? "?"
        return "\(weekday) \(comps.month ?? 0)/\(comps.day ?? 0)"
    }

    /// Full-ish date line "Sun · Jul 6, 2026" (mock's `data-clock="full"`), with
    /// localized weekday + month symbols.
    nonisolated static func fullDate(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let comps = calendar.dateComponents([.weekday, .month, .day, .year], from: date)
        let weekday = weekdaySymbols(locale)[safe: (comps.weekday ?? 1) - 1] ?? "?"
        let month = monthSymbols(locale)[safe: (comps.month ?? 1) - 1] ?? "?"
        return "\(weekday) · \(month) \(comps.day ?? 0), \(comps.year ?? 0)"
    }

    /// City label from a TimeZone identifier's last path component with "_"
    /// spaced ("America/New_York" → "New York"). Mirrors the mock's `city`
    /// field, derived rather than stored.
    nonisolated static func cityName(_ tz: TimeZone) -> String {
        let last = tz.identifier.split(separator: "/").last.map(String.init) ?? tz.identifier
        return last.replacingOccurrences(of: "_", with: " ")
    }

    /// Localized abbreviation for a zone at an instant (e.g. "PDT"/"BST"),
    /// respecting DST. Used as the M header's timezone whisper.
    nonisolated static func zoneAbbreviation(_ tz: TimeZone, at date: Date) -> String {
        tz.abbreviation(for: date) ?? tz.identifier
    }

    /// Relative-day hint for a zone vs the *local* calendar day (mock's
    /// `data-wrel`): "today" / "+Nd" / "−Nd". Compares calendar days across
    /// zones via `Calendar`, so day boundaries and DST are Foundation's job.
    nonisolated static func relativeDay(
        _ date: Date,
        zone: TimeZone,
        calendar localCalendar: Calendar
    ) -> RelativeDay {
        var zoneCalendar = localCalendar
        zoneCalendar.timeZone = zone
        let localDay = localCalendar.startOfDay(for: date)
        let zoneDayComps = zoneCalendar.dateComponents([.year, .month, .day], from: date)
        // Anchor the zone's wall-clock day back onto the local calendar so the
        // day delta is a pure date difference, not an hour-offset guess.
        var anchor = DateComponents()
        anchor.year = zoneDayComps.year
        anchor.month = zoneDayComps.month
        anchor.day = zoneDayComps.day
        let zoneDay = localCalendar.date(from: anchor).map(localCalendar.startOfDay(for:)) ?? localDay
        let diff = localCalendar.dateComponents([.day], from: localDay, to: zoneDay).day ?? 0
        // Same-day → empty text; the view renders a localized "today" instead.
        if diff == 0 { return RelativeDay(direction: .same, text: "") }
        if diff > 0 { return RelativeDay(direction: .ahead, text: "+\(diff)d") }
        return RelativeDay(direction: .behind, text: "\u{2212}\(-diff)d")   // U+2212 minus
    }

    nonisolated static func pad2(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Previews

private func clockContext(
    size: MonitorWidgetSize,
    showsSeconds: Bool = false,
    worldClocks: [String] = []
) -> MonitorWidgetContext {
    var options: [String: MonitorWidgetOptionValue] = [:]
    if showsSeconds { options["showsSeconds"] = .bool(true) }
    if !worldClocks.isEmpty { options["worldClocks"] = .stringList(worldClocks) }
    return MonitorWidgetContext(
        snapshot: MonitorSnapshot(),
        history: MonitorHistorySnapshot(),
        placement: MonitorWidgetPlacement(kind: .clock, size: size, options: options),
        isEditing: false,
        isAgentFleetEnabled: false,
        reduceMotion: false,
        now: Date()
    )
}

// Wrap previews in a TimelineView (the board supplies `context.now` in production)
// so the clock ticks in isolation.
#Preview("Clock · S") {
    TimelineView(.periodic(from: .now, by: 1)) { t in
        HStack(spacing: 24) {
            MonitorClockWidgetView(context: clockContext(size: .small).at(t.date))
                .frame(width: 168, height: 168)
            MonitorClockWidgetView(context: clockContext(size: .small, showsSeconds: true).at(t.date))
                .frame(width: 168, height: 168)
        }
        .padding(32)
        .background(MonitorDesign.boardWash)
    }
}

#Preview("Clock · M") {
    TimelineView(.periodic(from: .now, by: 1)) { t in
        VStack(spacing: 24) {
            MonitorClockWidgetView(context: clockContext(
                size: .medium,
                worldClocks: ["Asia/Tokyo", "Europe/London"]
            ).at(t.date))
            .frame(width: 348, height: 168)

            MonitorClockWidgetView(context: clockContext(
                size: .medium,
                showsSeconds: true,
                worldClocks: ["Asia/Tokyo", "Europe/London"]
            ).at(t.date))
            .frame(width: 348, height: 168)
        }
        .padding(32)
        .background(MonitorDesign.boardWash)
    }
}
