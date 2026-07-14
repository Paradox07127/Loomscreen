import SwiftUI
import LiveWallpaperCore

/// Power widget — a native port of the mock's Power section (index.html §7),
/// re-laid for Apple's fixed widget frames (S 170×170, M 364×170 → content box
/// ≈ 138×125 / 332×125 at cellHeight 85). The battery GLYPH is the reading: it
/// fills to charge level so the shape is legible before the number. A desktop
/// (no battery) renders a plug badge and an "AC" hero — never a fabricated
/// 100%. M rides the status word on the hero baseline (the mock's separate
/// status line doesn't fit the 125pt budget), then a time-to-full / remaining
/// line (hidden when unknown), Low-Power / thermal chips (only when serious),
/// and a quiet connected-accessory battery row capped at two rows.
///
/// Data honesty (SPEC §3.4): every field is read straight from the snapshot;
/// missing sensors degrade (no battery → plug, unknown time → line hidden,
/// no accessories → row absent). No uptime / load / package power.
struct MonitorPowerWidgetView: View {
    let context: MonitorWidgetContext

    init(context: MonitorWidgetContext) {
        self.context = context
    }

    private var system: MonitorSystemSnapshot? { context.snapshot.system }
    private var model: MonitorPowerModel { .init(system: system) }

    /// SoC temperature (falls back to CPU die) for the thermal readout beside the
    /// existing Low-Power / thermal-state chips. nil when the SMC read missed.
    private var socTempC: Double? {
        system?.sensors?.socTempC ?? system?.sensors?.cpuTempC
    }

    var body: some View {
        GeometryReader { geo in
            let cellHeight = geo.size.height / 2   // both sizes are 2 rows tall
            MonitorWidgetContainer(label: "Power", systemImage: powerSymbol, cellHeight: cellHeight) {
                EmptyView()
            } content: {
                switch context.placement.size {
                case .small:  smallBody(cellHeight: cellHeight)
                case .medium: mediumBody(cellHeight: cellHeight)
                case .large:  mediumBody(cellHeight: cellHeight)
                }
            }
        }
    }

    /// Header glyph reflects the ACTUAL level (never a fabricated full battery —
    /// the same honesty rule the glyph/hero themselves follow). Desktop → plug.
    private var powerSymbol: String {
        guard let level = model.level else { return "powerplug" }
        if model.charging { return "battery.100.bolt" }
        switch level {
        case 0.9...:   return "battery.100"
        case 0.65..<0.9: return "battery.75"
        case 0.4..<0.65: return "battery.50"
        case 0.15..<0.4: return "battery.25"
        default:       return "battery.0"
        }
    }

    // MARK: - S (2×2)

    @ViewBuilder
    private func smallBody(cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        VStack(spacing: max(6, cellHeight * 0.06)) {
            Spacer(minLength: 0)
            // Glyph sized for the fixed 138pt S content box (mock proportions:
            // battery aspect 3:1, plug 0.72×) — the old 118×40 left 10pt margins.
            glyph(width: model.hasBattery ? 100 : 72, height: 32)
                .frame(maxWidth: .infinity)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                hero(size: model.hasBattery ? scale.hero * 0.86 : scale.hero * 0.7)
                // Status word (Battery/Charging/…) — mock `.klbl`: label-sized,
                // tracked, uppercase (localized via its catalog key). The longest
                // word ("Power Adapter") can outrun the 138pt content box; shrink
                // rather than wrap/clip so it never overlaps the glyph above it.
                Text(LocalizedStringKey(model.status))
                    .font(MonitorDesign.labelFont(size: scale.label))
                    .tracking(MonitorDesign.labelTracking(size: scale.label))
                    .foregroundStyle(MonitorDesign.inkFaint)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - M (4×2)

    @ViewBuilder
    private func mediumBody(cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        let accessories = model.displayAccessories()
        // Budget vs the fixed 125pt content box: hero row ~53 + chips ~16 +
        // two accessory rows ~35 + 2×6 spacing ≈ 116. The mock's 3-line stat
        // column (hero / status / time) was ~15pt taller and overflowed.
        VStack(alignment: .leading, spacing: max(6, cellHeight * 0.05)) {
            Spacer(minLength: 0)   // mock `.body` justify-content:center
            HStack(alignment: .center, spacing: 10) {
                glyph(width: model.hasBattery ? 74 : 60, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        hero(size: model.hasBattery ? scale.hero : scale.hero * 0.82)
                        Text(LocalizedStringKey(model.status))
                            .font(.system(size: scale.caption, weight: .semibold, design: .rounded))
                            .foregroundStyle(MonitorDesign.inkPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    if let time = model.timeLine {
                        timeLine(time, size: scale.caption)
                    }
                }
                Spacer(minLength: 0)
                temperatureChip(scale: scale)
            }

            if !model.chips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.chips, id: \.self) { chip in
                        warnChip(chip, size: scale.label)
                    }
                }
            }

            if !accessories.isEmpty {
                accessoryBlock(accessories, size: scale.caption)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Pieces

    /// Compact SoC-temperature chip (thermometer glyph + the user's temperature
    /// unit, band-coloured), shown in the M header's trailing corner when a reading
    /// is present. Pure data — no new localized strings.
    @ViewBuilder
    private func temperatureChip(scale: MonitorDesign.TypeScale) -> some View {
        if let temp = socTempC {
            HStack(spacing: scale.caption * 0.4) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: scale.caption * 0.95))
                    .foregroundStyle(MonitorDesign.temperatureColor(temp))
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(verbatim: MonitorTemperature.valueText(temp))
                        .font(MonitorDesign.subFont(size: scale.caption))
                        .monospacedDigit()
                        .foregroundStyle(MonitorDesign.inkPrimary)
                    Text(verbatim: MonitorTemperature.symbol)
                        .font(MonitorDesign.captionFont(size: scale.caption * 0.7))
                        .foregroundStyle(MonitorDesign.inkFaint)
                }
                .lineLimit(1)
            }
            .monitorChip(scale)
        }
    }

    @ViewBuilder
    private func glyph(width: CGFloat, height: CGFloat) -> some View {
        if let level = model.level {
            BatteryGlyph(level: level, charging: model.charging, charged: model.charged)
                .frame(width: width, height: height)
        } else {
            PowerPlugBadge().frame(width: width, height: height)
        }
    }

    @ViewBuilder
    private func hero(size: CGFloat) -> some View {
        if let pct = model.heroPercent {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: "\(pct)")
                    .font(MonitorDesign.heroFont(size: size))
                    .monospacedDigit()
                    .foregroundStyle(MonitorDesign.inkPrimary)
                Text(verbatim: "%")
                    .font(MonitorDesign.subFont(size: size * 0.4))
                    .foregroundStyle(MonitorDesign.inkFaint)
            }
            .lineLimit(1)
        } else {
            Text(verbatim: "AC")
                .font(MonitorDesign.heroFont(size: size))
                .foregroundStyle(MonitorDesign.inkPrimary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func timeLine(_ time: MonitorPowerModel.TimeLine, size: CGFloat) -> some View {
        HStack(spacing: 3) {
            Text(verbatim: time.value)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkPrimary)
            // "to full" / "remaining" — a word, localized via its catalog key.
            Text(LocalizedStringKey(time.suffix))
                .font(.system(size: size, weight: .regular, design: .rounded))
                .foregroundStyle(MonitorDesign.inkMuted)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// Mock `.pill.warn` — the same chip Network's `constrained`/`expensive`
    /// pills use, plus the `.pdot` (mock `--run`, i.e. amber, not coral: LPM/
    /// thermal are cautions, not failures). Padding matches `.monitorChip`'s
    /// proportions (board-wide chip shape) but keeps its own amber tint since
    /// the fill/stroke carry the warning semantics.
    @ViewBuilder
    private func warnChip(_ chip: MonitorPowerModel.WarnChip, size: CGFloat) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(MonitorDesign.signalAmber)
                .frame(width: size * 0.5, height: size * 0.5)
            Text(verbatim: chip.localizedText)
                .font(MonitorDesign.labelFont(size: size))
                .tracking(MonitorDesign.labelTracking(size: size) * 0.4)
                .foregroundStyle(MonitorDesign.oklch(0.9, 0.03, 44))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, size * 0.5)
        .padding(.vertical, size * 0.24)
        .background(
            Capsule(style: .continuous)
                .fill(MonitorDesign.oklch(0.3, 0.05, 44, alpha: 0.28))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(MonitorDesign.oklch(0.5, 0.11, 40, alpha: 0.75), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func accessoryBlock(_ list: [MonitorAccessoryBattery], size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(list.enumerated()), id: \.offset) { _, acc in
                accessoryRow(acc, size: size)
            }
        }
        .padding(.top, 5)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MonitorDesign.hairline.opacity(0.45))
                .frame(height: MonitorDesign.hairlineWidth)
        }
    }

    @ViewBuilder
    private func accessoryRow(_ acc: MonitorAccessoryBattery, size: CGFloat) -> some View {
        let tint = MonitorPowerModel.accessoryTint(acc.percent)
        HStack(spacing: 7) {
            Image(systemName: MonitorPowerModel.accessorySymbol(acc.kind))
                .font(.system(size: size * 1.05))
                .foregroundStyle(MonitorDesign.inkMuted)
                .frame(width: size * 1.3, alignment: .center)
            Text(verbatim: acc.name)
                .font(.system(size: size, weight: .regular, design: .rounded))
                .foregroundStyle(MonitorDesign.inkMuted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            accessoryBar(percent: acc.percent, tint: tint)
                .frame(width: 34, height: 6)
            Text(verbatim: "\(Int(acc.percent.rounded()))%")
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint.label)
                .lineLimit(1)
                .frame(minWidth: size * 2.6, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func accessoryBar(percent: Double, tint: MonitorPowerModel.AccessoryTint) -> some View {
        GeometryReader { geo in
            let clamped = min(1, max(0, percent / 100))
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(MonitorDesign.track)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.black.opacity(0.25), lineWidth: 1)
                    )
                LinearGradient(colors: tint.barGradient, startPoint: .leading, endPoint: .trailing)
                    .frame(width: max(0, geo.size.width * clamped))
                    .clipShape(Capsule(style: .continuous))
            }
        }
    }
}

// MARK: - View-model (pure logic; unit-tested)

/// Pure derivation of the Power widget's presentation from a system snapshot.
/// Mirrors the mock JS (`battClass` / `powStatus` / `powTimeLine` / `accRow`),
/// adapted to the Swift contract where `powerSource` is `battery|ac|ups` and a
/// desktop reports `batteryLevel == nil` (mock's `powerSource:"none"`).
struct MonitorPowerModel {
    let level: Double?
    let charging: Bool
    let charged: Bool
    let powerSource: String?
    let lowPowerMode: Bool
    let thermalState: String
    let minutesRemaining: Double?
    let minutesToFull: Double?
    let accessories: [MonitorAccessoryBattery]

    init(system: MonitorSystemSnapshot?) {
        level = system?.batteryLevel
        charging = system?.batteryCharging ?? false
        charged = system?.batteryIsCharged ?? false
        powerSource = system?.powerSource
        lowPowerMode = system?.lowPowerMode ?? false
        thermalState = system?.thermalState ?? "nominal"
        minutesRemaining = system?.batteryMinutesRemaining
        minutesToFull = system?.batteryMinutesToFull
        accessories = system?.accessories ?? []
    }

    /// A machine actually has a battery only when it reports a level. A desktop
    /// (level == nil) → plug badge + AC, never a fabricated 100%.
    var hasBattery: Bool { level != nil }

    /// Whole-number hero percent, or nil for the "AC" (no-battery) hero.
    var heroPercent: Int? {
        guard let level else { return nil }
        return Int((min(1, max(0, level)) * 100).rounded())
    }

    /// Status word (mock `powStatus`): Battery / Power Adapter / Charging / Charged.
    var status: String {
        if !hasBattery { return "Power Adapter" }
        if charged { return "Charged" }
        if charging { return "Charging" }
        if powerSource == "ac" { return "Power Adapter" }
        return "Battery"
    }

    struct TimeLine { let value: String; let suffix: String }

    /// The time line (mock `powTimeLine`): "Xh Ym to full" while charging,
    /// "Xh Ym remaining" while discharging, or nil (hidden) when unknown.
    /// Minutes are converted to seconds so the shared `MonitorFormat.countdown`
    /// port produces the SPEC §3.1 wording.
    var timeLine: TimeLine? {
        if charging, let m = minutesToFull, m > 0 {
            return TimeLine(value: MonitorFormat.countdown(m * 60), suffix: "to full")
        }
        if !charging, let m = minutesRemaining, m > 0 {
            return TimeLine(value: MonitorFormat.countdown(m * 60), suffix: "remaining")
        }
        return nil
    }

    enum WarnChip: Hashable {
        case lowPower
        case thermal(String)

        /// English composition (kept for tests / non-UI callers).
        var text: String {
            switch self {
            case .lowPower: return "Low Power"
            case .thermal(let state): return "Thermal " + state.capitalized
            }
        }

        /// Localized display string. "Low Power" is one phrase; the thermal chip is
        /// the localized word "Thermal" + the localized severity (serious/critical).
        var localizedText: String {
            switch self {
            case .lowPower:
                return String(localized: "Low Power", comment: "Power widget: Low Power Mode is on.")
            case .thermal(let state):
                let thermal = String(localized: "Thermal", comment: "Power widget: thermal-pressure chip prefix.")
                let severity = String(localized: String.LocalizationValue(state),
                                      comment: "Thermal severity word (serious / critical).")
                return "\(thermal) \(severity)"
            }
        }
    }

    /// LPM chip whenever Low Power Mode is on; thermal chip ONLY when the state
    /// is serious/critical (fair/nominal never warn).
    var chips: [WarnChip] {
        var out: [WarnChip] = []
        if lowPowerMode { out.append(.lowPower) }
        if thermalState == "serious" || thermalState == "critical" {
            out.append(.thermal(thermalState))
        }
        return out
    }

    // MARK: Accessories

    /// M's fixed 125pt content box fits two accessory rows beside the hero row
    /// and warn chips. When more accessories report, keep the LOWEST-percent
    /// ones (the rows that need attention), in their original order — dropping
    /// a critical trackpad to show a healthy mouse would defeat the row.
    func displayAccessories(limit: Int = 2) -> [MonitorAccessoryBattery] {
        guard accessories.count > limit else { return accessories }
        let kept = accessories.enumerated()
            .sorted { $0.element.percent < $1.element.percent }
            .prefix(limit)
            .map(\.offset)
            .sorted()
        return kept.map { accessories[$0] }
    }

    /// SF Symbol for an accessory kind (`mouse|keyboard|trackpad|other`), the
    /// native stand-in for the mock's 🖱️/⌨️ emoji.
    nonisolated static func accessorySymbol(_ kind: String?) -> String {
        switch kind {
        case "mouse":    return "magicmouse"
        case "keyboard": return "keyboard"
        case "trackpad": return "trackpad"
        default:         return "dot.radiowaves.left.and.right"
        }
    }

    struct AccessoryTint { let barGradient: [Color]; let label: Color }

    /// Accessory battery tint: healthy flat sage, low(<20) amber-ramp, crit(<10)
    /// run→need ramp — mirrors mock `.accrow.low/.crit .abar i` gradients exactly
    /// (and their `.ap` label colours).
    nonisolated static func accessoryTint(_ percent: Double) -> AccessoryTint {
        if percent < 10 {
            return AccessoryTint(barGradient: [MonitorDesign.signalAmber, MonitorDesign.signalCoral],
                                 label: MonitorDesign.oklch(0.9, 0.06, 40))
        }
        if percent < 20 {
            return AccessoryTint(barGradient: [MonitorDesign.oklch(0.62, 0.06, 78), MonitorDesign.signalAmber],
                                 label: MonitorDesign.oklch(0.86, 0.06, 70))
        }
        return AccessoryTint(barGradient: [MonitorDesign.signalSage], label: MonitorDesign.inkMuted)
    }
}

// MARK: - Previews

private func powerContext(_ system: MonitorSystemSnapshot?, size: MonitorWidgetSize) -> MonitorWidgetContext {
    var snapshot = MonitorSnapshot()
    snapshot.system = system
    return MonitorWidgetContext(
        snapshot: snapshot,
        history: MonitorHistorySnapshot(),
        placement: MonitorWidgetPlacement(kind: .power, size: size),
        isEditing: false,
        isAgentFleetEnabled: false,
        reduceMotion: false,
        now: Date()
    )
}

private func laptopSystem() -> MonitorSystemSnapshot {
    var s = MonitorSystemSnapshot()
    s.batteryLevel = 0.62
    s.batteryCharging = true
    s.batteryIsCharged = false
    s.powerSource = "ac"
    s.thermalState = "nominal"
    s.batteryMinutesToFull = 48
    s.batteryMinutesRemaining = nil
    s.lowPowerMode = false
    s.accessories = [
        MonitorAccessoryBattery(name: "Magic Mouse", kind: "mouse", percent: 96),
        MonitorAccessoryBattery(name: "Magic Keyboard", kind: "keyboard", percent: 14),
    ]
    return s
}

private func lowBatterySystem() -> MonitorSystemSnapshot {
    var s = MonitorSystemSnapshot()
    s.batteryLevel = 0.08
    s.batteryCharging = false
    s.powerSource = "battery"
    s.thermalState = "serious"
    s.batteryMinutesRemaining = 22
    s.lowPowerMode = true
    s.accessories = [
        MonitorAccessoryBattery(name: "Magic Trackpad", kind: "trackpad", percent: 7),
    ]
    return s
}

private func desktopSystem() -> MonitorSystemSnapshot {
    var s = MonitorSystemSnapshot()
    s.batteryLevel = nil
    s.powerSource = nil
    s.thermalState = "nominal"
    return s
}

// Preview frames are Apple's official visible widget frames: S 170×170, M 364×170.

#Preview("Power · S") {
    HStack(spacing: 24) {
        MonitorPowerWidgetView(context: powerContext(laptopSystem(), size: .small))
            .frame(width: 170, height: 170)
        MonitorPowerWidgetView(context: powerContext(lowBatterySystem(), size: .small))
            .frame(width: 170, height: 170)
        MonitorPowerWidgetView(context: powerContext(desktopSystem(), size: .small))
            .frame(width: 170, height: 170)
    }
    .padding(32)
    .background(MonitorDesign.boardWash)
}

#Preview("Power · M") {
    VStack(spacing: 24) {
        MonitorPowerWidgetView(context: powerContext(laptopSystem(), size: .medium))
            .frame(width: 364, height: 170)
        MonitorPowerWidgetView(context: powerContext(lowBatterySystem(), size: .medium))
            .frame(width: 364, height: 170)
        MonitorPowerWidgetView(context: powerContext(desktopSystem(), size: .medium))
            .frame(width: 364, height: 170)
    }
    .padding(32)
    .background(MonitorDesign.boardWash)
}
