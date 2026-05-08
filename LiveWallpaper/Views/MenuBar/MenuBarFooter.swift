import SwiftUI
import AppKit

/// Bottom action row: Settings · Reload · Quit · Customise · Monitor dot.
/// The customise menu owns Tier-2 visibility toggles + popover-size picker.
struct MenuBarFooter: View {
    let openSettings: () -> Void
    let onReload: () -> Void

    @Binding var diagnosticsVisible: Bool
    @Binding var effectsVisible: Bool
    @Binding var bookmarksVisible: Bool
    @Binding var automationVisible: Bool
    @Binding var otherDisplaysVisible: Bool
    @Binding var popoverModeRaw: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button(action: openSettings) {
                Label("Settings", systemImage: "gearshape")
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .keyboardShortcut(",", modifiers: .command)
            .help(Text("Open settings"))

            Button(action: onReload) {
                Label("Reload", systemImage: "arrow.clockwise")
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .keyboardShortcut("r", modifiers: .command)
            .help(Text("Reload all wallpapers"))

            Button(role: .destructive, action: { NSApp.terminate(nil) }) {
                Label("Quit", systemImage: "power")
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .keyboardShortcut("q", modifiers: .command)
            .help(Text("Quit LiveWallpaper"))

            Spacer(minLength: 4)

            customisationMenu
            MonitorDot()
        }
    }

    private var customisationMenu: some View {
        Menu {
            Section("Sections") {
                Toggle("Diagnostics", isOn: $diagnosticsVisible)
                Toggle("Effects", isOn: $effectsVisible)
                Toggle("Bookmarks", isOn: $bookmarksVisible)
                Toggle("Automation", isOn: $automationVisible)
                Toggle("Other Displays", isOn: $otherDisplaysVisible)
            }
            Section("Size") {
                Picker("Size", selection: $popoverModeRaw) {
                    ForEach(MenuBarPopoverMode.allCases) { mode in
                        Text(mode.displayLabel).tag(mode.rawValue)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: .circle)
        .help(Text("Customise menu bar"))
        .accessibilityLabel(Text("Customise menu bar"))
    }
}

/// Footer dot showing aggregated CPU/GPU pressure. Tap opens the diagnostics
/// popover; the colour itself acts as a passive temperature indicator.
private struct MonitorDot: View {
    @State private var showDetails = false

    private var monitor: SystemMonitor { .shared }

    var body: some View {
        Button {
            showDetails = true
        } label: {
            Image(systemName: "circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(stateColor)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(stateColor.opacity(0.35)).interactive(),
            in: .circle
        )
        .help(stateLabel)
        .accessibilityLabel(Text("System pressure: \(stateLabel)"))
        .popover(isPresented: $showDetails, arrowEdge: .top) {
            MenuBarDiagnosticsPopover()
        }
    }

    private var pressure: Double {
        max(monitor.systemCpuUsage, monitor.gpuUsage)
    }

    private var stateColor: Color {
        if pressure >= 80 { return .red }
        if pressure >= 50 { return .orange }
        return .green
    }

    private var stateLabel: String {
        if pressure >= 80 { return "High" }
        if pressure >= 50 { return "Moderate" }
        return "Healthy"
    }
}
