import SwiftUI
import LiveWallpaperCore

/// Health widget — a 1:1 native port of the mock's Health section (index.html
/// §health, `health_s`/`health_m`). Per-source pipeline status as a colour-coded
/// dot matrix: sage = ok, amber = stale, coral = unauthorized/error, faint = off.
/// S shows the aggregate "N / M sources ok" count above a left-aligned dot-chip
/// row (the mock's `.body` only sets `justify-content:center`, never
/// `align-items:center`, unlike the centred gauge widgets e.g. Power). M reuses
/// the same wrapping chip matrix with each chip appending a colour-coded state
/// word, plus a summary hint line beneath. The header's corner dot (mock
/// `chd(…, un?"crit":"")`) always renders once there's data — sage baseline,
/// coral the moment any source needs attention — it never just appears on failure.
///
/// Data honesty (SPEC §3.4): state and count come straight from the snapshot's
/// `health[]`. The mock hard-codes "updated 1s ago"; the summary line's age here
/// is real (`MonitorFormat.ago(now − freshest lastUpdateAt)`) and drops silently
/// when no source carries a timestamp. `health` nil/empty → a quiet honest empty
/// state, never a fabricated "all clear".
struct MonitorHealthWidgetView: View {
    let context: MonitorWidgetContext

    init(context: MonitorWidgetContext) {
        self.context = context
    }

    private var sources: [MonitorSourceHealth] {
        MonitorHealthModel.ordered(context.snapshot.health ?? [])
    }
    private var needsAttention: Bool {
        sources.contains { MonitorHealthModel.needsAttention($0.state) }
    }

    /// System temperature for the thermal chip: SoC package reading, falling back
    /// to the CPU die. nil (no SMC reading) → the chip is omitted entirely.
    private var systemTempC: Double? {
        context.snapshot.system?.sensors?.socTempC ?? context.snapshot.system?.sensors?.cpuTempC
    }

    var body: some View {
        GeometryReader { geo in
            let cellHeight = geo.size.height / 2   // both sizes are 2 rows tall
            MonitorWidgetContainer(label: Self.title, systemImage: "checklist", cellHeight: cellHeight) {
                statusDot
            } content: {
                if sources.isEmpty {
                    emptyBody(cellHeight: cellHeight)
                } else {
                    switch context.placement.size {
                    case .small:  smallBody(cellHeight: cellHeight)
                    case .medium: mediumBody(cellHeight: cellHeight)
                    case .large:  mediumBody(cellHeight: cellHeight)
                    }
                }
            }
        }
    }

    /// The header's right-hand micro readout (mock `chd(…, un?"crit":"")`): the
    /// dot renders whenever there's data — sage baseline (mock's default `.dot`),
    /// coral the instant any source needs attention (mock `.dot.crit`). Only a
    /// truly empty snapshot suppresses it — there's nothing to certify as healthy.
    @ViewBuilder
    private var statusDot: some View {
        if !sources.isEmpty {
            let color = MonitorHealthModel.headerDotColor(needsAttention: needsAttention)
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.7), radius: 3)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
        } else {
            EmptyView()
        }
    }

    // MARK: - S (2×2)

    @ViewBuilder
    private func smallBody(cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        let okCount = MonitorHealthModel.okCount(sources)
        // Mock's health_s body only sets `justify-content:center` (vertical, the
        // column main-axis) — never `align-items:center` — so the hero row and
        // dot matrix stay left-edge aligned, unlike the centred gauge widgets.
        VStack(alignment: .leading, spacing: max(8, cellHeight * 0.08)) {
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: "\(okCount)")
                    .font(MonitorDesign.heroFont(size: scale.hero))
                    .monospacedDigit()
                    .foregroundStyle(MonitorDesign.inkPrimary)
                Text(verbatim: "/ \(sources.count)")
                    .font(MonitorDesign.subFont(size: scale.sub))
                    .foregroundStyle(MonitorDesign.inkFaint)
                Text(LocalizedStringKey(Self.sourcesOK))
                    .font(MonitorDesign.labelFont(size: scale.label))
                    .tracking(MonitorDesign.labelTracking(size: scale.label))
                    .foregroundStyle(MonitorDesign.inkFaint)
                    .padding(.leading, 4)
                Spacer(minLength: 4)
                temperatureChip(scale: scale)
            }
            dotMatrix(scale: scale, showsState: false)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The wrapping dot field (mock `.dotmx`, shared by S's `health_dots()` and
    /// M's `health_m`): one dot + uppercase source name per source, colour-coded
    /// by state. `showsState` appends the trailing colour-coded state word — the
    /// M-only span in the mock's markup; S omits it. Gaps mirror the mock's own
    /// em values (`.dotmx` default `.5em .9em`; M's inline override `.7em 1.1em`),
    /// both scaled off `--t-cap` (`scale.caption`, the dot-matrix's local em).
    @ViewBuilder
    private func dotMatrix(scale: MonitorDesign.TypeScale, showsState: Bool) -> some View {
        FlowLayout(
            hSpacing: scale.caption * (showsState ? 1.1 : 0.9),
            vSpacing: scale.caption * (showsState ? 0.7 : 0.5)
        ) {
            ForEach(sources, id: \.sourceID) { source in
                HStack(spacing: 6) {
                    stateDot(source.state, size: scale.caption * 0.55)
                    Text(verbatim: MonitorHealthModel.displayName(source.sourceID).uppercased())
                        .font(MonitorDesign.captionFont(size: scale.caption))
                        .tracking(scale.caption * 0.06)
                        .foregroundStyle(MonitorDesign.inkMuted)
                    if showsState {
                        Self.stateWordText(source.state)
                            .font(MonitorDesign.captionFont(size: scale.caption))
                            .foregroundStyle(MonitorHealthModel.wordColor(source.state))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - M (4×2)

    /// M reuses the exact same dot-chip matrix as S (mock: `health_m`'s `.dotmx`
    /// is the identical wrapping-flex idiom, just with `showsState: true` chips
    /// and a wider gap) plus the summary hint line beneath.
    @ViewBuilder
    private func mediumBody(cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        VStack(alignment: .leading, spacing: max(5, cellHeight * 0.045)) {
            Spacer(minLength: 0)
            dotMatrix(scale: scale, showsState: true)
            HStack(alignment: .firstTextBaseline, spacing: scale.caption) {
                summaryLine(scale: scale)
                Spacer(minLength: 0)
                temperatureChip(scale: scale)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Compact system-temperature chip (thermometer glyph + °C, coloured by band).
    /// Only drawn when the SMC read returned a reading — pure data, no new strings.
    @ViewBuilder
    private func temperatureChip(scale: MonitorDesign.TypeScale) -> some View {
        if let temp = systemTempC {
            HStack(spacing: scale.caption * 0.4) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: scale.caption * 0.95))
                    .foregroundStyle(MonitorDesign.temperatureColor(temp))
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(verbatim: "\(Int(temp.rounded()))")
                        .font(MonitorDesign.subFont(size: scale.caption))
                        .monospacedDigit()
                        .foregroundStyle(MonitorDesign.inkPrimary)
                    Text(verbatim: "°C")
                        .font(MonitorDesign.captionFont(size: scale.caption * 0.7))
                        .foregroundStyle(MonitorDesign.inkFaint)
                }
            }
        }
    }

    /// The summary hint line beneath the rows (mock `health_m` tail). When a
    /// source needs attention it names the reconnect affordance in coral; when
    /// everything is nominal it reports the freshest update, honestly derived.
    @ViewBuilder
    private func summaryLine(scale: MonitorDesign.TypeScale) -> some View {
        if let attention = sources.first(where: { MonitorHealthModel.needsAttention($0.state) }) {
            // Source name is data (verbatim); the reconnect hint is a phrase (localized).
            (Text(verbatim: "\(MonitorHealthModel.displayName(attention.sourceID)) ")
             + Text(LocalizedStringKey(Self.reconnectHint)))
                .font(MonitorDesign.captionFont(size: scale.caption))
                .foregroundStyle(MonitorDesign.oklch(0.86, 0.05, 40))
                .padding(.top, 2)
        } else {
            Text(verbatim: nominalSummary)
                .font(MonitorDesign.captionFont(size: scale.caption))
                .foregroundStyle(MonitorDesign.inkFaint)
                .padding(.top, 2)
        }
    }

    /// "all sources nominal" plus the freshest real update age, e.g.
    /// "all sources nominal · updated 3s ago" — each word localized, the age
    /// dropped if no source carries a timestamp (never a fabricated "1s ago").
    private var nominalSummary: String {
        let allNominal = String(localized: String.LocalizationValue(Self.allNominal),
                                comment: "Health widget: every source is reporting normally.")
        guard let freshest = MonitorHealthModel.freshestAge(sources, now: context.now.timeIntervalSince1970) else {
            return allNominal
        }
        let updated = String(localized: String.LocalizationValue(Self.updated),
                             comment: "Health widget: freshness prefix, e.g. 'updated 3s ago'.")
        let agoWord = String(localized: String.LocalizationValue(Self.agoWord),
                             comment: "Relative-age suffix, e.g. '3s ago'.")
        return "\(allNominal) · \(updated) \(MonitorFormat.ago(freshest)) \(agoWord)"
    }

    // MARK: - Empty state

    @ViewBuilder
    private func emptyBody(cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: "checklist.unchecked")
                .font(.system(size: scale.hero * 0.5, weight: .regular))
                .foregroundStyle(MonitorDesign.inkFaint)
            Text(LocalizedStringKey(Self.noSources))
                .font(MonitorDesign.captionFont(size: scale.caption))
                .foregroundStyle(MonitorDesign.inkFaint)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Shared dot

    @ViewBuilder
    private func stateDot(_ state: String, size: CGFloat) -> some View {
        let color = MonitorHealthModel.dotColor(state)
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .modifier(HealthDotGlow(color: color, glowing: MonitorHealthModel.glows(state), radius: size * 0.7))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
    }

    /// Localized state word for the M-size chips. "ok" renders verbatim (a
    /// universal status token); "off"/"error" reuse the app's existing catalog
    /// keys; the rest use their own keys; unknown raw states surface verbatim.
    private static func stateWordText(_ state: String) -> Text {
        switch state {
        case "ok":           return Text(verbatim: "ok")
        case "off":          return Text("Off")
        case "error":        return Text("Error")
        case "stale":        return Text("stale")
        case "unauthorized": return Text("unauthorized")
        default:             return Text(verbatim: MonitorHealthModel.stateWord(state))
        }
    }

    // MARK: - Strings (LISTed for i18n; verbatim data uses Text(verbatim:))

    private static let title = "Health"
    private static let sourcesOK = "sources ok"
    private static let allNominal = "all sources nominal"
    private static let updated = "updated"
    private static let agoWord = "ago"
    private static let reconnectHint = "unauthorized · open to reconnect"
    private static let noSources = "No sources reporting"
}

/// The mock gives ok/stale/unauthorized dots a soft outer glow but leaves error
/// (flat `--err`) and off (flat `--idle`) matte. This mirrors that split.
private struct HealthDotGlow: ViewModifier {
    var color: Color
    var glowing: Bool
    var radius: CGFloat

    func body(content: Content) -> some View {
        if glowing {
            content.shadow(color: color.opacity(0.75), radius: radius)
        } else {
            content
        }
    }
}

// MARK: - View-model (pure logic; unit-tested)

/// Pure derivation of the Health widget's presentation from `health[]`. Mirrors
/// the mock's per-state colour map (`.dotmx .hs i.<state>`) and word-colour logic
/// (`health_m`), plus the worst-first ordering the board reads at a glance.
enum MonitorHealthModel {

    /// State → dot colour (mock `.dotmx .hs i.<state>`): ok = sage/`--done`,
    /// stale = amber/`--run`, unauthorized = coral/`--need`, error = red/`--err`,
    /// off/unknown = idle/`--idle`.
    nonisolated static func dotColor(_ state: String) -> Color {
        switch state {
        case "ok":           return MonitorDesign.signalSage
        case "stale":        return MonitorDesign.signalAmber
        case "unauthorized": return MonitorDesign.signalCoral
        case "error":        return MonitorDesign.signalRed
        default:             return MonitorDesign.signalIdle   // off / unknown
        }
    }

    /// State → trailing word colour (mock `health_m`): ok = sage, unauthorized =
    /// coral, everything else faint. (The dot, not the word, carries stale/error
    /// hue — matching the mock exactly.)
    nonisolated static func wordColor(_ state: String) -> Color {
        switch state {
        case "ok":           return MonitorDesign.signalSage
        case "unauthorized": return MonitorDesign.signalCoral
        default:             return MonitorDesign.inkFaint
        }
    }

    /// Whether the state's dot carries a glow (ok/stale/unauthorized) or renders
    /// matte (error/off) — the mock's box-shadow split.
    nonisolated static func glows(_ state: String) -> Bool {
        switch state {
        case "ok", "stale", "unauthorized": return true
        default:                            return false
        }
    }

    /// State word shown in the M rows: "ok" for ok, otherwise the raw state
    /// string (mock `s.st==="ok"?"ok":s.st`).
    nonisolated static func stateWord(_ state: String) -> String {
        state == "ok" ? "ok" : state
    }

    /// A source "needs attention" when it is unauthorized or errored — the
    /// coral/red family that drives the header crit dot and the reconnect hint.
    nonisolated static func needsAttention(_ state: String) -> Bool {
        state == "unauthorized" || state == "error"
    }

    /// Header corner-dot colour (mock `chd(…, un?"crit":"")` → `.dot`/`.dot.crit`):
    /// sage baseline once there's data, coral the moment any source needs
    /// attention. The mock's dot span always renders (`dotCls` is `""` or
    /// `"crit"`, never omitted) — only a genuinely empty snapshot hides it, and
    /// that's handled at the view level, not here.
    nonisolated static func headerDotColor(needsAttention: Bool) -> Color {
        needsAttention ? MonitorDesign.signalCoral : MonitorDesign.signalSage
    }

    /// Sort weight — worst first. Coral (unauthorized) and red (error) failures
    /// lead, then amber stale, then off, then healthy ok. Higher sorts earlier.
    nonisolated static func priority(_ state: String) -> Int {
        switch state {
        case "unauthorized": return 5
        case "error":        return 4
        case "stale":        return 3
        case "off":          return 2
        case "ok":           return 1
        default:             return 0
        }
    }

    /// Worst-first ordering, stable within a priority band (preserves the source
    /// registration order the pipeline emitted for equal-severity sources).
    nonisolated static func ordered(_ sources: [MonitorSourceHealth]) -> [MonitorSourceHealth] {
        sources.enumerated()
            .sorted { lhs, rhs in
                let lp = priority(lhs.element.state), rp = priority(rhs.element.state)
                return lp == rp ? lhs.offset < rhs.offset : lp > rp
            }
            .map(\.element)
    }

    nonisolated static func okCount(_ sources: [MonitorSourceHealth]) -> Int {
        sources.filter { $0.state == "ok" }.count
    }

    /// Friendly source label (mock renders the raw id uppercased; the view still
    /// uppercases, so this only needs to supply nicer casing/spelling).
    nonisolated static func displayName(_ sourceID: String) -> String {
        switch sourceID {
        case "system": return "System"
        case "claude": return "Claude"
        case "codex":  return "Codex"
        case "usage":  return "Usage"
        default:
            guard let first = sourceID.first else { return sourceID }
            return first.uppercased() + sourceID.dropFirst()
        }
    }

    /// Freshest (smallest) update age across sources that carry a timestamp, in
    /// seconds; nil when none do — so the summary never invents an age.
    nonisolated static func freshestAge(_ sources: [MonitorSourceHealth], now: Double) -> Double? {
        let ages = sources.compactMap { source -> Double? in
            guard let last = source.lastUpdateAt else { return nil }
            let age = now - last
            return age.isFinite && age >= 0 ? age : nil
        }
        return ages.min()
    }
}

// MARK: - Flow layout

/// A minimal wrapping HStack for the S dot matrix — items flow left-to-right and
/// wrap to the next line when they run out of width (the mock's `flex-wrap`).
/// macOS 14-safe: hand-rolled rather than iOS-16 `Layout` sugar to keep the
/// arithmetic obvious and testable-by-eye.
private struct FlowLayout: Layout {
    var hSpacing: CGFloat = 12
    var vSpacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + hSpacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + vSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? hSpacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width - bounds.minX > maxWidth {
                x = bounds.minX
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Previews

private func healthContext(_ health: [MonitorSourceHealth], size: MonitorWidgetSize) -> MonitorWidgetContext {
    var snapshot = MonitorSnapshot()
    snapshot.health = health
    snapshot.timestamp = Date().timeIntervalSince1970
    return MonitorWidgetContext(
        snapshot: snapshot,
        history: MonitorHistorySnapshot(),
        placement: MonitorWidgetPlacement(kind: .health, size: size),
        isEditing: false,
        isAgentFleetEnabled: false,
        reduceMotion: false,
        now: Date()
    )
}

private func mixedHealth() -> [MonitorSourceHealth] {
    let now = Date().timeIntervalSince1970
    return [
        MonitorSourceHealth(sourceID: "system", state: "ok", detail: nil, lastUpdateAt: now - 1),
        MonitorSourceHealth(sourceID: "claude", state: "ok", detail: nil, lastUpdateAt: now - 4),
        MonitorSourceHealth(sourceID: "codex", state: "unauthorized",
                            detail: "Grant access to ~/.codex", lastUpdateAt: now - 12),
    ]
}

private func nominalHealth() -> [MonitorSourceHealth] {
    let now = Date().timeIntervalSince1970
    return [
        MonitorSourceHealth(sourceID: "system", state: "ok", detail: nil, lastUpdateAt: now - 1),
        MonitorSourceHealth(sourceID: "claude", state: "ok", detail: nil, lastUpdateAt: now - 2),
        MonitorSourceHealth(sourceID: "codex", state: "stale", detail: nil, lastUpdateAt: now - 90),
    ]
}

#Preview("Health · S") {
    HStack(spacing: 24) {
        MonitorHealthWidgetView(context: healthContext(mixedHealth(), size: .small))
            .frame(width: 168, height: 168)
        MonitorHealthWidgetView(context: healthContext(nominalHealth(), size: .small))
            .frame(width: 168, height: 168)
        MonitorHealthWidgetView(context: healthContext([], size: .small))
            .frame(width: 168, height: 168)
    }
    .padding(32)
    .background(MonitorDesign.boardWash)
}

#Preview("Health · M") {
    VStack(spacing: 24) {
        MonitorHealthWidgetView(context: healthContext(mixedHealth(), size: .medium))
            .frame(width: 348, height: 168)
        MonitorHealthWidgetView(context: healthContext(nominalHealth(), size: .medium))
            .frame(width: 348, height: 168)
        MonitorHealthWidgetView(context: healthContext([], size: .medium))
            .frame(width: 348, height: 168)
    }
    .padding(32)
    .background(MonitorDesign.boardWash)
}
