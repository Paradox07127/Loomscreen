import SwiftUI

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
