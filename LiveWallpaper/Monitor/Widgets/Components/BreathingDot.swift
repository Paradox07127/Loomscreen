import SwiftUI

/// A small status dot with a gentle opacity/scale "breathe" for running states.
/// Ported from the mock's one animation: `breathe 3s ease-in-out infinite`
/// (opacity .5→1, scale .86→1). Respects Reduce Motion — static (at rest
/// opacity/scale) when reduced, exactly like `MonitorHUDView`'s dot.
///
/// This is the board's only `repeatForever` primitive, and because it drives
/// itself rather than following the data, stopping the data pump does NOT stop it
/// — it is the board's one animation that keeps a display awake on its own. So it
/// also honours `monitorSuspended`: while the wallpaper is suspended the dot
/// freezes into the same still state Reduce Motion gives it.
struct BreathingDot: View {
    var color: Color = MonitorDesign.signalSage
    var size: CGFloat = 7
    /// When false, the dot renders solid and still regardless of motion setting
    /// (e.g. an idle/ended session).
    var animated: Bool = true

    @State private var phase = false
    @Environment(\.monitorReduceMotion) private var reduceMotion
    @Environment(\.monitorSuspended) private var suspended

    init(color: Color = MonitorDesign.signalSage, size: CGFloat = 7, animated: Bool = true) {
        self.color = color
        self.size = size
        self.animated = animated
    }

    /// Every condition that must hold for the dot to run its repeating animation.
    /// Any one of them is enough to still it — in particular `suspended`, which no
    /// caller passes: the busiest call site is `animated: pct > 60`, i.e. the dot
    /// breathes precisely when the machine is already hot.
    static func shouldBreathe(animated: Bool, reduceMotion: Bool, suspended: Bool) -> Bool {
        animated && !reduceMotion && !suspended
    }

    private var breathing: Bool {
        Self.shouldBreathe(animated: animated, reduceMotion: reduceMotion, suspended: suspended)
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.7), radius: size * 0.5)
            .overlay(
                Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1)
            )
            .scaleEffect(breathing && phase ? 1.0 : 0.86)
            .opacity(breathing ? (phase ? 1.0 : 0.5) : 1.0)
            .animation(breathing ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true) : nil,
                       value: phase)
            .onAppear { if breathing { phase = true } }
            // Suspend/resume flips `breathing` on a live dot, and `onAppear` won't
            // fire again to restart the repeat — so drive the phase from it.
            .onChange(of: breathing) { _, isBreathing in phase = isBreathing }
    }
}

#Preview("Breathing dot") {
    HStack(spacing: 20) {
        BreathingDot(color: MonitorDesign.signalAmber)
        BreathingDot(color: MonitorDesign.signalCoral)
        BreathingDot(color: MonitorDesign.signalSage)
        BreathingDot(color: MonitorDesign.signalIdle, animated: false)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}
