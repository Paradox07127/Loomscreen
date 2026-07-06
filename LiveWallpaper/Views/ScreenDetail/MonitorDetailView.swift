import AppKit
import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

/// Inspector card for the Monitor wallpaper: module toggles plus the Pro-only
/// AI-agent section (sessions + usage + read-only folder authorization).
///
/// Edits mirror into a local draft, commit to `ScreenManager` immediately, and
/// restart the wallpaper session so the renderer rebuilds under the new module
/// mix (there is no in-place apply seam on the monitor view yet).
struct MonitorDetailView: View {
    let screen: Screen
    let screenManager: ScreenManager
    let featureCatalog: FeatureCatalog

    @AppStorage("Inspector.MonitorExpanded") private var isExpanded = true
    @State private var config: MonitorWallpaperConfiguration = .default
    @State private var claudeAuthorized = false
    @State private var codexAuthorized = false
    @State private var showUsageSetup = false
    @State private var detectedStatusLineCommand: String?

    private var agentFleetEnabled: Bool {
        featureCatalog.isEnabled(.agentFleet)
    }

    var body: some View {
        GroupBox {
            CollapsibleSection(
                title: "Monitor",
                systemImage: "gauge.with.dots.needle.67percent",
                isExpanded: $isExpanded
            ) {
                VStack(spacing: 8) {
                    systemMetricsRow
                    Divider()
                    topProcessesRow
                    Divider()
                    mouseInteractionRow

                    if agentFleetEnabled {
                        Divider()
                        agentsRow
                        Divider()
                        usageRow
                        Divider()
                        usageSetupRow
                        Divider()
                        authorizationRows
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: screen.id) { _, _ in reload() }
        .sheet(isPresented: $showUsageSetup) {
            MonitorUsageSetupView(existingStatusLineCommand: detectedStatusLineCommand)
        }
    }

    // MARK: - Rows

    private var systemMetricsRow: some View {
        SettingRow(
            icon: "cpu",
            iconColor: .blue,
            title: "System Metrics",
            subtitle: "CPU, memory, network and disk"
        ) {
            Toggle("", isOn: binding(\.systemEnabled))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Show system metrics"))
        }
    }

    private var topProcessesRow: some View {
        SettingRow(
            icon: "list.bullet.rectangle",
            iconColor: .teal,
            title: "Top Processes",
            subtitle: "Show the busiest processes"
        ) {
            Toggle("", isOn: binding(\.showTopProcesses))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Show top processes"))
        }
    }

    private var mouseInteractionRow: some View {
        SettingRow(
            icon: "cursorarrow.rays",
            iconColor: .green,
            title: "Mouse Interaction",
            subtitle: "Let the dashboard receive clicks (double-click a session to focus it)"
        ) {
            Toggle("", isOn: binding(\.mouseInteractionEnabled))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Enable mouse interaction"))
        }
    }

    private var agentsRow: some View {
        SettingRow(
            icon: "brain",
            iconColor: .orange,
            title: "AI Agent Sessions",
            subtitle: "Live Claude and Codex activity"
        ) {
            Toggle("", isOn: binding(\.agentsEnabled))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Show AI agent sessions"))
        }
    }

    private var usageRow: some View {
        SettingRow(
            icon: "chart.bar",
            iconColor: .purple,
            title: "AI Usage",
            subtitle: "Token and cost totals"
        ) {
            Toggle("", isOn: binding(\.usageEnabled))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Show AI usage"))
        }
    }

    private var usageSetupRow: some View {
        SettingRow(
            icon: "clock.badge.exclamationmark",
            iconColor: .pink,
            title: "Account usage limits",
            subtitle: "Show 5-hour and weekly quota from Claude Code's statusline"
        ) {
            Button("Set Up…") {
                detectedStatusLineCommand = detectExistingStatuslineCommand()
                showUsageSetup = true
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var authorizationRows: some View {
        SettingRow(
            icon: "folder.badge.person.crop",
            iconColor: .indigo,
            title: "Authorize Claude Folder",
            subtitle: "Read-only access to ~/.claude"
        ) {
            authorizationControl(isAuthorized: claudeAuthorized) {
                MonitorSourceAuthorization.shared.requestClaudeAccess(from: hostWindow()) {
                    refreshAuthorizationState()
                    Task { await MonitorRuntime.shared.refreshSources() }
                }
            }
        }

        SettingRow(
            icon: "folder.badge.person.crop",
            iconColor: .indigo,
            title: "Authorize Codex Folder",
            subtitle: "Read-only access to ~/.codex"
        ) {
            authorizationControl(isAuthorized: codexAuthorized) {
                MonitorSourceAuthorization.shared.requestCodexAccess(from: hostWindow()) {
                    refreshAuthorizationState()
                    Task { await MonitorRuntime.shared.refreshSources() }
                }
            }
        }
    }

    @ViewBuilder
    private func authorizationControl(isAuthorized: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            if isAuthorized {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel(Text("Authorized"))
            }
            Button(isAuthorized ? "Re-authorize…" : "Authorize…", action: action)
                .controlSize(.small)
        }
    }

    // MARK: - Binding + commit

    private func binding(_ keyPath: WritableKeyPath<MonitorWallpaperConfiguration, Bool>) -> Binding<Bool> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { newValue in
                var next = config
                next[keyPath: keyPath] = newValue
                config = next
                screenManager.updateMonitorConfiguration(next, for: screen)
            }
        )
    }

    private func reload() {
        if case .monitor(let current)? = screenManager.getConfiguration(for: screen)?.activeWallpaper {
            config = current
        } else {
            config = .default
        }
        refreshAuthorizationState()
    }

    private func refreshAuthorizationState() {
        claudeAuthorized = MonitorSourceAuthorization.shared.isAuthorized(.claude)
        codexAuthorized = MonitorSourceAuthorization.shared.isAuthorized(.codex)
    }

    /// Reads the user's current `statusLine.command` from settings.json (via the
    /// read-only grant) so the setup sheet can chain it; nil when absent,
    /// unreadable, or already our own capture script.
    private func detectExistingStatuslineCommand() -> String? {
        let detected: String?? = MonitorSourceAuthorization.shared.withResolvedClaudeRoot { root -> String? in
            let url = root.appendingPathComponent("settings.json")
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let statusLine = object["statusLine"] as? [String: Any],
                  let command = statusLine["command"] as? String else { return nil }
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("livewallpaper-statusline") else { return nil }
            return trimmed
        }
        return detected ?? nil
    }

    private func hostWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
    }
}
