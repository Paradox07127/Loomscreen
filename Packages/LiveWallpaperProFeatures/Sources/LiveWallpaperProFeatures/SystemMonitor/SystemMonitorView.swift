import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

public struct SystemMonitorView: View {
    private var monitor = SystemMonitor.shared
    @State private var powerSource: PowerMonitor.PowerSource = PowerMonitor.shared.currentPowerSource
    @AppStorage("Dashboard.RAMScope") private var ramScopeRaw: String = "system"

    /// Snapshot of how many displays are currently playing a wallpaper, and
    /// how many displays are connected in total. Passed in from the caller
    /// because `SystemMonitorView` lives in the Pro features package and
    /// cannot import the main-app `ScreenManager` type directly.
    private let activeDisplayCount: Int
    private let totalDisplayCount: Int

    public init(activeDisplayCount: Int = 0, totalDisplayCount: Int = 0) {
        self.activeDisplayCount = activeDisplayCount
        self.totalDisplayCount = totalDisplayCount
    }

    private var ramPercent: Double {
        ramScopeRaw == "app" ? monitor.memoryPercentage() : monitor.systemMemoryUsage * 100
    }
    private var cpuPercent: Double {
        ramScopeRaw == "app" ? monitor.cpuUsage : monitor.systemCpuUsage
    }
    private var ramTitle: String {
        String(localized: "RAM", defaultValue: "RAM", comment: "Dashboard memory gauge title. Industry-standard abbreviation; kept verbatim across locales.")
    }

    private var ramDetailText: Text {
        if ramScopeRaw == "app" {
            return Text("App: \(monitor.formattedMemoryUsage()) / \(monitor.formattedTotalMemory())", comment: "Dashboard memory detail. Placeholders are used and total memory.")
        }
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let usedBytes = UInt64(Double(totalBytes) * monitor.systemMemoryUsage)
        return Text("Sys: \(FormatUtils.formatBytes(usedBytes)) / \(monitor.formattedTotalMemory())", comment: "Dashboard system memory detail. Placeholders are used and total memory.")
    }

    public var body: some View {
        VStack(spacing: 8) {
            RAMScopePicker(selection: $ramScopeRaw)

            gaugeGrid
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)

            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    if totalDisplayCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "play.tv")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(verbatim: "\(activeDisplayCount)/\(totalDisplayCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    Spacer(minLength: 0)

                    // Reflects ProcessInfo.thermalState — a coarse OS thermal-pressure
                    // level, NOT a measured temperature. A flame + "Thermal" label
                    // (instead of a thermometer) keeps users from reading the state
                    // word as a °C reading; the API stays nominal at normal-but-warm
                    // die temps (e.g. 70°C) by design.
                    HStack(spacing: 4) {
                        Image(systemName: "flame")
                            .font(.caption2)
                            .foregroundStyle(thermalColor)
                        Text("Thermal", comment: "Dashboard label for the macOS thermal-pressure state (ProcessInfo.thermalState) — an OS load level, not a measured temperature.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(verbatim: monitor.thermalStateDescription)
                            .font(.caption)
                            .foregroundStyle(thermalColor)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "memorychip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ramDetailText
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 2)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: 220, alignment: .leading)
        .clipped()
        .onAppear {
            monitor.startMonitoring()
            powerSource = PowerMonitor.shared.currentPowerSource
        }
        .onDisappear {
            monitor.stopMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: PowerMonitor.powerSourceDidChangeNotification)) { notification in
            if let newSource = notification.userInfo?["newSource"] as? PowerMonitor.PowerSource {
                powerSource = newSource
            }
        }
    }

    private func colorForPercent(_ pct: Double) -> Color {
        if pct >= 80 { return DesignTokens.Colors.Gauge.high }
        if pct >= 50 { return DesignTokens.Colors.Gauge.medium }
        return DesignTokens.Colors.Gauge.low
    }

    private var thermalColor: Color {
        switch monitor.thermalState {
        case .nominal:  return DesignTokens.Colors.Gauge.low
        case .fair:     return DesignTokens.Colors.Gauge.medium
        case .serious:  return DesignTokens.Colors.Gauge.high
        case .critical: return DesignTokens.Colors.Gauge.high
        @unknown default: return DesignTokens.Colors.textTertiary
        }
    }

    private var gaugeGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                MiniGaugeCard(title: "CPU", value: cpuPercent, color: colorForPercent(cpuPercent), icon: "cpu")
                    .accessibilityLabel(Text("CPU usage"))
                    .accessibilityValue(Text(verbatim: FormatUtils.formatPercent(cpuPercent)))

                MiniGaugeCard(title: "GPU", value: monitor.gpuUsage, color: colorForPercent(monitor.gpuUsage), icon: "square.stack.3d.up.fill")
                    .accessibilityLabel(Text("GPU usage"))
                    .accessibilityValue(Text(verbatim: FormatUtils.formatPercent(monitor.gpuUsage)))
            }

            HStack(spacing: 8) {
                MiniGaugeCard(title: ramTitle, value: ramPercent, color: colorForPercent(ramPercent), icon: "memorychip")
                    .accessibilityLabel(Text("\(ramTitle) usage"))
                    .accessibilityValue(Text(verbatim: FormatUtils.formatPercent(ramPercent)))

                PowerStatusCard(powerSource: powerSource)
                    .accessibilityLabel(Text("Power source"))
                    .accessibilityValue(powerSource.accessibilitySummary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - MiniGaugeCard

/// `icon + value` sit centered slightly above the geometric middle so the
/// static `title` can drop into the ring's empty bottom 90° gap, so no element
/// ever shares vertical space with another (avoids the old offset-stack overlap).
struct MiniGaugeCard: View {
    let title: String
    let value: Double
    let color: Color
    let icon: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.0, to: 0.75)
                .stroke(Color.gray.opacity(0.12), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(135))

            Circle()
                .trim(from: 0.0, to: CGFloat(displayedPercent) / 100 * 0.75)
                .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(DesignTokens.motion(reduceMotion, .spring(response: 0.5, dampingFraction: 0.8)), value: displayedPercent)

            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color)
                Text(verbatim: FormatUtils.formatPercent(Double(displayedPercent)))
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .monospacedDigit()
            }
            .offset(y: -4)
            .dynamicTypeSize(...DynamicTypeSize.large)

            Text(verbatim: title)
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
                .offset(y: 19)
                .dynamicTypeSize(...DynamicTypeSize.large)
        }
        .frame(width: 54, height: 54)
        .frame(maxWidth: .infinity)
    }

    private var displayedPercent: Int {
        Int(min(max(value, 0), 100).rounded())
    }
}

// MARK: - PowerStatusCard

struct PowerStatusCard: View {
    let powerSource: PowerMonitor.PowerSource

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.0, to: 0.75)
                .stroke(Color.gray.opacity(0.12), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(135))

            switch powerSource {
            case .battery(let level):
                Circle()
                    .trim(from: 0.0, to: CGFloat(level) * 0.75)
                    .stroke(statusColor, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(135))
            case .external:
                Circle()
                    .trim(from: 0.0, to: 0.75)
                    .stroke(statusColor, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(135))
            }

            VStack(spacing: 1) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(statusColor)
                Text(verbatim: powerSource.valueLabel)
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .monospacedDigit()
            }
            .offset(y: -4)
            .dynamicTypeSize(...DynamicTypeSize.large)

            Text(verbatim: powerSource.shortLabel)
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
                .offset(y: 19)
                .dynamicTypeSize(...DynamicTypeSize.large)
        }
        .frame(width: 54, height: 54)
        .frame(maxWidth: .infinity)
    }

    private var iconName: String {
        switch powerSource {
        case .battery(let level):
            if level <= 0.1 { return "battery.0" }
            if level <= 0.25 { return "battery.25" }
            if level <= 0.5 { return "battery.50" }
            if level <= 0.75 { return "battery.75" }
            return "battery.100"
        case .external:
            return "bolt.fill"
        }
    }

    private var statusColor: Color {
        switch powerSource {
        case .battery(let level):
            if level <= 0.2 { return DesignTokens.Colors.Gauge.high }
            if level <= 0.5 { return DesignTokens.Colors.Gauge.medium }
            return DesignTokens.Colors.Gauge.low
        case .external:
            return DesignTokens.Colors.Gauge.low
        }
    }
}

private extension PowerMonitor.PowerSource {
    var shortLabel: String {
        switch self {
        case .battery: return "BATT"
        case .external: return "PWR"
        }
    }

    var valueLabel: String {
        switch self {
        case .battery(let level): return FormatUtils.formatFractionAsPercent(level)
        case .external: return "AC"
        }
    }

    var accessibilitySummary: Text {
        switch self {
        case .battery(let level):
            return Text("Battery at \(FormatUtils.formatFractionAsPercent(level))", comment: "Power source accessibility summary. The placeholder is the formatted battery percent.")
        case .external:
            return Text("AC power", comment: "Power source accessibility summary.")
        }
    }
}
