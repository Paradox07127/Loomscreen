import AppKit
import SwiftUI

// MARK: - Signal palette

private enum HUDSignal {
    static let running = Color(red: 0.921, green: 0.701, blue: 0.334)   // amber  oklch(.80 .128 78)
    static let needsInput = Color(red: 0.959, green: 0.453, blue: 0.340) // coral  oklch(.705 .165 34)
    static let done = Color(red: 0.469, green: 0.771, blue: 0.599)       // sage   oklch(.76 .10 158)
    static let idle = Color(red: 0.470, green: 0.454, blue: 0.432)       // neutral oklch(.56 .010 76)
    /// Warnings (tool-loop / stale) reuse the warm amber attention signal — "burning / stuck" is an attention cue, distinct from the coral "needs you" but not a new colour in the capsule's vocabulary.
    static let warning = running

    static let ink = Color(red: 0.924, green: 0.907, blue: 0.875)
    static let inkFaint = Color(red: 0.413, green: 0.391, blue: 0.361)

    /// Warm graphite tint laid over the vibrancy base so the capsule reads as
    /// the app's dark HUD rather than raw system material.
    static let graphiteTint = Color(red: 0.090, green: 0.075, blue: 0.055)

    static func color(for status: MonitorAgentStatus) -> Color {
        switch status {
        case .running: return running
        case .needsInput: return needsInput
        case .ended: return done
        case .idle, .unknown: return idle
        }
    }
}

// MARK: - Glass base

/// `NSVisualEffectView` wrapper providing the floating-chrome GLASS base. Uses
/// `.hudWindow` material behind-window so the desktop/app underneath refracts.
private struct HUDVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - HUD view

/// Native capsule shown in the floating panel.
struct MonitorHUDView: View {
    let model: MonitorHUDModel
    /// Filled by the router at integration; nil = no-op (button hidden).
    var onFocus: ((String) -> Void)?

    @State private var isHovering = false
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotionEnv

    /// AppKit's global Reduce-Motion switch — authoritative for a desktop
    /// accessory that isn't inside the normal SwiftUI accessibility environment.
    private var reduceMotion: Bool {
        reduceMotionEnv || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var cornerRadius: CGFloat { 15 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsedRow
            if model.presentation == .needsInput, let blocked = model.blocked {
                urgentSection(blocked)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(minWidth: 220, maxWidth: 340, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
        .background(glassBackground)
        .overlay(breathingGlow)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .opacity(overallOpacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isHovering)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.8), value: model.presentation)
        .onHover { isHovering = $0 }
        .onAppear { startBreathingIfNeeded() }
        .onChange(of: model.presentation) { _, _ in startBreathingIfNeeded() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: Collapsed pill

    private var collapsedRow: some View {
        HStack(spacing: 9) {
            Text(aggregateText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(HUDSignal.ink)
                .lineLimit(1)
                .fixedSize()

            if model.isStale {
                Text("stale", comment: "Fleet HUD: shown when the monitor pipeline hasn't published recently.")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(HUDSignal.inkFaint)
            }

            // Subtle "who's stuck" affordance: one amber glyph when any live
            // session is spinning-in-place (toolLoop) or quietly stalled (stale).
            if let warning = model.warning {
                Image(systemName: warningGlyph(warning))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(HUDSignal.warning)
                    .help(warningLabel(warning))
                    .accessibilityLabel(warningLabel(warning))
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                ForEach(model.providerDots) { dot in
                    Circle()
                        .fill(HUDSignal.color(for: dot.status))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityHidden(true)
        }
    }

    // MARK: Urgent (needs input) section

    private func urgentSection(_ blocked: MonitorHUDModel.BlockedSession) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
                .overlay(Color.white.opacity(0.14))
                .padding(.vertical, 4)

            Text("NEEDS YOU", comment: "Fleet HUD: uppercase label above the blocked session that is waiting for the user.")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(HUDSignal.needsInput)

            HStack(spacing: 7) {
                Image(systemName: providerGlyph(blocked.provider))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HUDSignal.needsInput)
                Text(verbatim: blocked.projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HUDSignal.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let waited = waitLabel(blocked) {
                    Text(verbatim: "· \(waited)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(HUDSignal.needsInput.opacity(0.85))
                        .fixedSize()
                        .accessibilityLabel(Text("waiting \(waited)", comment: "Fleet HUD: accessibility label for how long the blocked session has waited; %@ is a short duration like 4m."))
                }
            }

            if let detail = blocked.detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(HUDSignal.inkFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if blocked.warning != nil || blocked.showsContextPressure {
                HStack(spacing: 6) {
                    if let warning = blocked.warning {
                        warningChip(warning)
                    }
                    if blocked.showsContextPressure {
                        contextPressureChip
                    }
                }
                .padding(.top, 1)
            }

            if onFocus != nil {
                Button {
                    onFocus?(blocked.sessionID)
                } label: {
                    Text("Focus", comment: "Fleet HUD: button that jumps the user to the blocked agent session.")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HUDSignal.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(HUDSignal.needsInput.opacity(0.28))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(HUDSignal.needsInput.opacity(0.55), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .accessibilityLabel(Text("Focus \(blocked.projectName)", comment: "Fleet HUD: accessibility label for the Focus button; %@ is the project name."))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Backgrounds

    private var glassBackground: some View {
        HUDVisualEffect()
            .overlay(HUDSignal.graphiteTint.opacity(0.62))
    }

    @ViewBuilder
    private var breathingGlow: some View {
        if model.presentation == .needsInput {
            let intensity = model.blocked?.glowIntensity ?? 1
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(HUDSignal.needsInput, lineWidth: 1)
                .shadow(color: HUDSignal.needsInput.opacity(0.7 * intensity), radius: 18)
                .opacity(glowOpacity(intensity: intensity))
                .allowsHitTesting(false)
        }
    }

    // MARK: Derived visual state

    /// Dim at rest (60%), full on hover — brightening is the only hover effect.
    private var overallOpacity: Double {
        if model.presentation == .needsInput { return isHovering ? 1 : 0.95 }
        return isHovering ? 1 : 0.6
    }

    private func glowOpacity(intensity: Double) -> Double {
        guard !reduceMotion else { return 0.6 * intensity }
        return (breathe ? 0.85 : 0.28) * intensity
    }

    private func startBreathingIfNeeded() {
        guard !reduceMotion, model.presentation == .needsInput else {
            breathe = false
            return
        }
        breathe = false
        withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
            breathe = true
        }
    }

    // MARK: Copy

    private var aggregateText: String {
        switch model.aggregate {
        case .noSessions:
            return String(localized: "No active sessions", comment: "Fleet HUD collapsed pill: no agent sessions are active.")
        case .running(let count):
            return String(localized: "\(count) running", comment: "Fleet HUD collapsed pill: %lld agent sessions are running.")
        case .needsInput(let count):
            return String(localized: "\(count) waiting", comment: "Fleet HUD collapsed pill: %lld agent sessions need the user.")
        case .allIdle:
            return String(localized: "All idle", comment: "Fleet HUD collapsed pill: every agent session is idle.")
        case .mixed:
            return String(localized: "Standing by", comment: "Fleet HUD collapsed pill: a mix of idle/unknown sessions, none running or blocked.")
        }
    }

    private var accessibilitySummary: Text {
        if let blocked = model.blocked {
            return Text("Fleet needs input: \(blocked.projectName)", comment: "Fleet HUD accessibility summary when a session is blocked; %@ is the project name.")
        }
        return Text(verbatim: aggregateText)
    }

    private func providerGlyph(_ provider: MonitorAgentProvider) -> String {
        switch provider {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    // MARK: Warning + context-pressure affordances

    /// Amber pill naming the focused session's anomaly (glyph + short word).
    private func warningChip(_ warning: MonitorHUDModel.Warning) -> some View {
        HStack(spacing: 4) {
            Image(systemName: warningGlyph(warning))
                .font(.system(size: 9, weight: .bold))
            warningLabel(warning)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(HUDSignal.warning)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous).fill(HUDSignal.warning.opacity(0.16))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(HUDSignal.warning.opacity(0.4), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(warningLabel(warning))
    }

    /// Coral near-compaction hint — shown only past the context-pressure gate.
    private var contextPressureChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 9, weight: .bold))
            Text("context full", comment: "Fleet HUD: chip warning the focused session is near its context limit (compaction imminent).")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(HUDSignal.needsInput)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous).fill(HUDSignal.needsInput.opacity(0.14))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(HUDSignal.needsInput.opacity(0.38), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private func warningGlyph(_ warning: MonitorHUDModel.Warning) -> String {
        switch warning {
        case .toolLoop: return "arrow.triangle.2.circlepath"   // spinning in place
        case .stale: return "clock.badge.exclamationmark"      // quiet stall
        }
    }

    private func warningLabel(_ warning: MonitorHUDModel.Warning) -> Text {
        switch warning {
        case .toolLoop:
            return Text("looping", comment: "Fleet HUD: warning chip — the agent is retrying one tool over and over (spinning in place).")
        case .stale:
            return Text("stalled", comment: "Fleet HUD: warning chip — the agent is running but has gone quiet (no events for a while).")
        }
    }

    /// Compact wait duration in the HUD's existing age idiom (5s / 4m / 2h / 1d);
    /// nil when the wait is under a second so the "· …" suffix stays clean.
    private func waitLabel(_ blocked: MonitorHUDModel.BlockedSession) -> String? {
        guard let seconds = blocked.waitingSeconds, seconds >= 1 else { return nil }
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
