import SwiftUI

/// A real battery cell filled to level, with a charging-bolt overlay and
/// low-level tinting. Ported from the mock's `.batt` recipe: sage fill when
/// healthy, amber→coral when low (<20) and not charging, an amber sweep while
/// charging. `charging` overrides the low tint. Level is 0…1.
struct BatteryGlyph: View {
    var level: Double
    var charging: Bool = false
    var charged: Bool = false
    /// Low / critical thresholds (fractions). Below `low` → amber/coral tint
    /// (only when not charging); below `critical` → coral.
    var lowThreshold: Double = 0.20
    var criticalThreshold: Double = 0.10
    var cornerRadius: CGFloat = 5

    @Environment(\.monitorReduceMotion) private var reduceMotion

    init(level: Double, charging: Bool = false, charged: Bool = false,
         lowThreshold: Double = 0.20, criticalThreshold: Double = 0.10,
         cornerRadius: CGFloat = 5) {
        self.level = level
        self.charging = charging
        self.charged = charged
        self.lowThreshold = lowThreshold
        self.criticalThreshold = criticalThreshold
        self.cornerRadius = cornerRadius
    }

    private var isLow: Bool { level < lowThreshold && !charging }

    private var fillColors: [Color] {
        if charging { return [MonitorDesign.oklch(0.6, 0.06, 78), MonitorDesign.signalAmber] }
        if charged { return [MonitorDesign.oklch(0.7, 0.08, 158), MonitorDesign.signalSage] }
        if isLow { return [MonitorDesign.signalAmber, MonitorDesign.signalCoral] }
        return [MonitorDesign.oklch(0.66, 0.08, 158), MonitorDesign.signalSage]
    }

    private var glowColor: Color {
        if charging { return MonitorDesign.signalAmber }
        if isLow { return MonitorDesign.signalCoral }
        return MonitorDesign.signalSage
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let capWidth = max(3, w * 0.045)
            let bodyWidth = w - capWidth - 2
            let clamped = min(1, max(0, level))

            HStack(spacing: 2) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(colors: [MonitorDesign.bg0.opacity(0.6),
                                                    MonitorDesign.bg1.opacity(0.35)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(MonitorDesign.hairlineHi, lineWidth: 2)
                        )

                    LinearGradient(colors: fillColors, startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(0, (bodyWidth - 4) * CGFloat(clamped)))
                        .clipShape(RoundedRectangle(cornerRadius: max(1, cornerRadius - 2), style: .continuous))
                        .padding(2)
                        .shadow(color: glowColor.opacity(0.5), radius: 6)

                    if charging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: h * 0.42, weight: .heavy))
                            .foregroundStyle(MonitorDesign.oklch(0.18, 0.02, 78))
                            .frame(maxWidth: .infinity)
                    } else if charged {
                        Image(systemName: "powerplug.fill")
                            .font(.system(size: h * 0.34, weight: .heavy))
                            .foregroundStyle(MonitorDesign.oklch(0.2, 0.02, 158))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(width: bodyWidth)

                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(MonitorDesign.hairlineHi)
                    .frame(width: capWidth, height: h * 0.38)
            }
            .frame(width: w, height: h)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: clamped)
        }
    }
}

/// The no-battery (desktop) badge — a plug outline in neutral steel, shown
/// instead of a fabricated 100%.
struct PowerPlugBadge: View {
    var cornerRadius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(colors: [MonitorDesign.bg0.opacity(0.6), MonitorDesign.bg1.opacity(0.35)],
                               startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(MonitorDesign.hairlineHi, lineWidth: 1.5)
            )
            .overlay(
                Image(systemName: "powerplug")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(MonitorDesign.signalSteel)
                    .shadow(color: MonitorDesign.signalSteel.opacity(0.35), radius: 6)
            )
    }
}

#Preview("Battery glyph") {
    VStack(spacing: 18) {
        BatteryGlyph(level: 0.82).frame(width: 120, height: 46)
        BatteryGlyph(level: 0.55, charging: true).frame(width: 120, height: 46)
        BatteryGlyph(level: 0.14).frame(width: 120, height: 46)
        BatteryGlyph(level: 1.0, charged: true).frame(width: 120, height: 46)
        PowerPlugBadge().frame(width: 84, height: 44)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}
