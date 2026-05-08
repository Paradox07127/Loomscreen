import SwiftUI

/// Folded drawer holding the global automation knobs that previously lived in
/// the always-visible "Quick Toggles" block. Mutate-then-save semantics keep
/// `GlobalSettings` fields untouched outside the two booleans bound here.
struct MenuBarAutomationDrawer: View {
    @Environment(ScreenManager.self) private var screenManager

    @State private var isExpanded: Bool = false
    @State private var globalPauseOnBattery: Bool = SettingsManager.shared.loadGlobalSettings().globalPauseOnBattery
    @State private var pauseOnFullScreen: Bool = SettingsManager.shared.loadGlobalSettings().pauseOnFullScreen

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $globalPauseOnBattery) {
                    Label("Pause on Battery", systemImage: "bolt.slash")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 11))
                }
                .onChange(of: globalPauseOnBattery) { _, _ in commit() }

                Toggle(isOn: $pauseOnFullScreen) {
                    Label("Pause on Full-Screen Apps", systemImage: "macwindow")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 11))
                }
                .onChange(of: pauseOnFullScreen) { _, _ in commit() }

                SnoozeRow()
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .padding(.top, 4)
        } label: {
            Label("Automation", systemImage: "wand.and.stars")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 11, weight: .medium))
        }
        .onAppear { reload() }
    }

    private func reload() {
        let settings = SettingsManager.shared.loadGlobalSettings()
        globalPauseOnBattery = settings.globalPauseOnBattery
        pauseOnFullScreen = settings.pauseOnFullScreen
    }

    private func commit() {
        var settings = SettingsManager.shared.loadGlobalSettings()
        settings.globalPauseOnBattery = globalPauseOnBattery
        settings.pauseOnFullScreen = pauseOnFullScreen
        SettingsManager.shared.saveGlobalSettings(settings)
        screenManager.handleGlobalSettingsChanged()
    }
}

/// Snooze picker. Active deadline is sourced live from ScreenManager so the
/// row reflects external changes (e.g. expiration timer).
private struct SnoozeRow: View {
    @Environment(ScreenManager.self) private var screenManager

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 11))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(currentLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("Off") { screenManager.snoozeAll(until: nil) }
                Button("Snooze 15 minutes") {
                    screenManager.snoozeAll(until: Date(timeIntervalSinceNow: 15 * 60))
                }
                Button("Snooze 1 hour") {
                    screenManager.snoozeAll(until: Date(timeIntervalSinceNow: 60 * 60))
                }
                Button("Snooze 2 hours") {
                    screenManager.snoozeAll(until: Date(timeIntervalSinceNow: 2 * 60 * 60))
                }
                Button("Until tomorrow") {
                    screenManager.snoozeAll(until: nextMorning())
                }
            } label: {
                Text(buttonLabel)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityLabel("Snooze")
        }
    }

    private var currentLabel: String {
        if let until = screenManager.snoozeUntil {
            return "Snoozed until \(formatTime(until))"
        }
        return "Snooze playback"
    }

    private var buttonLabel: String {
        screenManager.snoozeUntil == nil ? "Set" : "Adjust"
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func nextMorning() -> Date {
        let calendar = Calendar.current
        let now = Date()
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.day = (components.day ?? 1) + 1
        components.hour = 8
        components.minute = 0
        return calendar.date(from: components) ?? now.addingTimeInterval(8 * 60 * 60)
    }
}
