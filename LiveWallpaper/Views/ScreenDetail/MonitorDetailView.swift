import AppKit
import LiveWallpaperCore
import SwiftUI
import UniformTypeIdentifiers

/// Inspector card for the Monitor wallpaper — the side panel for the board
/// editor (Monitor v2). The board itself is edited in the preview area to the
/// left (`MonitorBoardPreviewArea`, SPEC §4: preview = editor); this panel holds
/// the surrounding controls, all funnelling through `ScreenManager`:
///   • Board-level controls (refresh rate, mouse interaction, reduce-motion).
///   • A list of placed widgets; selecting one opens its settings popover (size,
///     remove, kind-specific options) that writes into the placement's options.
///   • Usage-limit setup + folder authorization (Pro `.agentFleet` only).
///
/// It stays in sync with edits made ON the preview by re-reading the persisted
/// board on `.wallpaperConfigurationDidChange`. The AI-agent surfaces stay gated
/// on the Pro `.agentFleet` capability, exactly as the wallpaper view gates its
/// placements.
struct MonitorDetailView: View {
    let screen: Screen
    let screenManager: ScreenManager
    let featureCatalog: FeatureCatalog

    @AppStorage("Inspector.MonitorExpanded") private var isExpanded = true

    /// The board config being edited. Seeded from the persisted config on appear
    /// and re-seeded when live board edits arrive from the preview; every mutation
    /// here writes back through `ScreenManager`.
    @State private var draft: MonitorBoardConfiguration = .default

    /// Placement currently open in the settings popover (by id), if any.
    @State private var settingsWidgetID: UUID?

    @State private var claudeAuthorized = false
    @State private var codexAuthorized = false
    @State private var showUsageSetup = false
    @State private var detectedStatusLineCommand: String?

    /// Display-only temperature unit for every sensor readout (app-wide, not
    /// per-board). Widgets re-read `MonitorTemperature` on each 1 Hz render, so a
    /// flip shows on the next tick.
    @AppStorage(MonitorTemperature.fahrenheitDefaultsKey) private var temperatureFahrenheit = false

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
                VStack(alignment: .leading, spacing: 8) {
                    boardHint
                    refreshRateRow
                    Divider()
                    mouseInteractionRow
                    Divider()
                    reduceMotionRow
                    Divider()
                    temperatureUnitRow
                    Divider()
                    placedWidgetsSection
                    Divider()
                    layoutManagementRow

                    if agentFleetEnabled {
                        Divider()
                        usageSetupRow
                        Divider()
                        authorizationRows
                    }
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
        .onAppear(perform: reload)
        .onChange(of: screen.id) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperConfigurationDidChange)) { notification in
            // Board edits made ON the preview persist without touching this panel;
            // re-read so the instruments list + open popover track the board.
            guard let changedID = notification.userInfo?["screenID"] as? CGDirectDisplayID,
                  changedID == screen.id else { return }
            reload()
        }
        .sheet(isPresented: $showUsageSetup) {
            MonitorUsageSetupView(existingStatusLineCommand: detectedStatusLineCommand)
        }
    }

    // MARK: - Board-level controls

    private var boardHint: some View {
        Text("Arrange the board in the preview above — drag tiles, or add and remove instruments there.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var refreshRateRow: some View {
        SettingRow(
            icon: "arrow.triangle.2.circlepath",
            iconColor: .blue,
            title: "Refresh Rate",
            info: "How often the instruments sample"
        ) {
            HStack(spacing: DesignTokens.Inspector.sliderValueSpacing) {
                // Dragging updates only the local draft (live label); the value is
                // committed ONCE on release. Committing on every tick would fire a
                // config write per frame — a storm the live board must not endure.
                Slider(
                    value: Binding(
                        get: { draft.refreshHz },
                        set: { draft.refreshHz = MonitorBoardConfiguration.clampedRefreshHz($0) }
                    ),
                    in: 0.2...2.0,
                    onEditingChanged: { editing in
                        if !editing { commit(draft) }
                    }
                )
                .controlSize(.small)
                .frame(width: DesignTokens.Inspector.sliderWidth)
                Text(verbatim: Self.refreshHzLabel(draft.refreshHz))
                    .font(DesignTokens.Typography.metric)
                    .foregroundStyle(.secondary)
                    .frame(width: DesignTokens.Inspector.sliderValueWidth, alignment: .trailing)
            }
        }
    }

    private var mouseInteractionRow: some View {
        SettingRow(
            icon: "cursorarrow.rays",
            iconColor: draft.mouseInteractionEnabled ? .blue : .secondary,
            title: "Mouse Interaction",
            info: "Let the wallpaper receive clicks instead of passing them to the desktop"
        ) {
            Toggle("", isOn: Binding(
                get: { draft.mouseInteractionEnabled },
                set: { setMouseInteraction($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel(Text("Enable mouse interaction"))
        }
    }

    private var reduceMotionRow: some View {
        SettingRow(
            icon: "wind",
            iconColor: .teal,
            title: "Reduce Motion",
            info: "Still the animations on this board"
        ) {
            Picker("", selection: Binding(
                get: { ReduceMotionChoice(draft.reduceMotionOverride) },
                set: { setReduceMotion($0) }
            )) {
                Text("System").tag(ReduceMotionChoice.system)
                Text("On").tag(ReduceMotionChoice.on)
                Text("Off").tag(ReduceMotionChoice.off)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Reduce motion"))
        }
    }

    private var temperatureUnitRow: some View {
        SettingRow(
            icon: "thermometer.variable.and.figure",
            iconColor: .orange,
            title: "Temperature",
            info: "Unit for the CPU / GPU / battery sensor readouts"
        ) {
            Picker("", selection: Binding(
                get: { temperatureFahrenheit },
                set: { temperatureFahrenheit = $0 }
            )) {
                Text(verbatim: "°C").tag(false)
                Text(verbatim: "°F").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Temperature unit"))
        }
    }

    // MARK: - Layout management (reset / import / export)

    private var layoutManagementRow: some View {
        SettingRow(
            icon: "square.grid.2x2",
            iconColor: .purple,
            title: "Layout",
            info: "Reset the board to its default instruments, or move a layout between machines"
        ) {
            HStack(spacing: 6) {
                Button("Reset", action: resetLayout)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(isDefaultLayout)
                Button("Import…", action: importLayout)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                Button("Export…", action: exportLayout)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(draft.widgets.isEmpty)
            }
        }
    }

    /// True when the board already matches the default preset — same instruments,
    /// sizes, AND positions — so Reset is a genuine no-op. Position is included so
    /// a user who only rearranged the default trio can still reset the layout.
    private var isDefaultLayout: Bool {
        let defaults = MonitorBoardConfiguration.defaultSystemPlacements()
        let current = draft.widgets
        guard current.count == defaults.count else { return false }
        func key(_ p: MonitorWidgetPlacement) -> String {
            "\(p.kind.rawValue)|\(p.size.rawValue)|\((p.x * 1000).rounded())|\((p.y * 1000).rounded())"
        }
        return Set(current.map(key)) == Set(defaults.map(key))
    }

    // MARK: - Placed widgets list

    @ViewBuilder
    private var placedWidgetsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Instruments")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if draft.widgets.isEmpty {
                Text("No instruments yet — double-click the preview to edit, then add them from the catalog.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 4) {
                    ForEach(draft.widgets) { placement in
                        widgetRow(placement)
                    }
                }
            }
        }
    }

    private func widgetRow(_ placement: MonitorWidgetPlacement) -> some View {
        Button {
            settingsWidgetID = placement.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: MonitorWidgetFactory.icon(placement.kind))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(verbatim: MonitorWidgetFactory.displayName(placement.kind))
                    .font(.body)
                Spacer(minLength: 4)
                Text(verbatim: placement.size.rawValue.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(settingsWidgetID == placement.id ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .popover(
            isPresented: Binding(
                get: { settingsWidgetID == placement.id },
                set: { if !$0, settingsWidgetID == placement.id { settingsWidgetID = nil } }
            ),
            arrowEdge: .trailing
        ) {
            MonitorWidgetSettingsPopover(
                placement: placement,
                onUpdate: { updated in updatePlacement(updated) },
                onRemove: { removeWidget(placement.id) }
            )
        }
    }

    // MARK: - AI-agent surfaces (Pro-gated)

    private var usageSetupRow: some View {
        SettingRow(
            icon: "clock.badge.exclamationmark",
            iconColor: .pink,
            title: "Account usage limits",
            info: "Show 5-hour and weekly quota from Claude Code's statusline"
        ) {
            Button("Set Up…") {
                detectedStatusLineCommand = detectExistingStatuslineCommand()
                showUsageSetup = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var authorizationRows: some View {
        authorizationRow(
            title: "Authorize Claude Folder",
            subtitle: "Read-only access to ~/.claude",
            isAuthorized: claudeAuthorized,
            authorize: {
                MonitorSourceAuthorization.shared.requestClaudeAccess(from: hostWindow()) {
                    refreshAuthorizationState()
                    Task { await MonitorRuntime.shared.refreshSources() }
                }
            },
            revoke: { revoke(.claude) }
        )

        Divider()

        authorizationRow(
            title: "Authorize Codex Folder",
            subtitle: "Read-only access to ~/.codex",
            isAuthorized: codexAuthorized,
            authorize: {
                MonitorSourceAuthorization.shared.requestCodexAccess(from: hostWindow()) {
                    refreshAuthorizationState()
                    Task { await MonitorRuntime.shared.refreshSources() }
                }
            },
            revoke: { revoke(.codex) }
        )
    }

    /// Authorized state carries TWO actions (Revoke + Re-authorize…) that can
    /// never share `SettingRow`'s trailing slot with the long title at inspector
    /// width, so they get a full-width trailing row of their own; the ✓ becomes
    /// a title badge. Buttons are `.fixedSize()` so labels never truncate —
    /// title/subtitle give way instead.
    @ViewBuilder
    private func authorizationRow(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        isAuthorized: Bool,
        authorize: @escaping () -> Void,
        revoke: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingRow(
                icon: "folder.badge.person.crop",
                iconColor: .indigo,
                title: title,
                titleBadge: isAuthorized
                    ? SettingRowTitleBadge(
                        systemImage: "checkmark.circle.fill",
                        tint: DesignTokens.Colors.Status.active,
                        accessibilityLabel: Text("Authorized")
                    )
                    : nil,
                subtitle: subtitle
            ) {
                if !isAuthorized {
                    Button("Authorize…", action: authorize)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                }
            }
            if isAuthorized {
                HStack(spacing: 6) {
                    Button("Revoke", action: revoke)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                    Button("Re-authorize…", action: authorize)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func revoke(_ provider: MonitorSourceAuthorization.Provider) {
        MonitorSourceAuthorization.shared.revokeAccess(provider)
        refreshAuthorizationState()
        Task { await MonitorRuntime.shared.refreshSources() }
    }

    // MARK: - Draft mutations (persist through ScreenManager)

    private func setMouseInteraction(_ enabled: Bool) {
        var next = draft
        next.mouseInteractionEnabled = enabled
        commit(next)
    }

    private func setReduceMotion(_ choice: ReduceMotionChoice) {
        var next = draft
        next.reduceMotionOverride = choice.override
        commit(next)
    }

    private func updatePlacement(_ updated: MonitorWidgetPlacement) {
        guard let index = draft.widgets.firstIndex(where: { $0.id == updated.id }) else { return }
        var next = draft
        next.widgets[index] = updated
        commit(next)
    }

    private func removeWidget(_ id: UUID) {
        guard draft.widgets.contains(where: { $0.id == id }) else { return }
        var next = draft
        next.widgets.removeAll { $0.id == id }
        if settingsWidgetID == id { settingsWidgetID = nil }
        commit(next)
    }

    // MARK: - Layout reset / import / export

    private func resetLayout() {
        var next = draft
        next.widgets = MonitorBoardConfiguration.defaultSystemPlacements()
        settingsWidgetID = nil
        commit(next)
    }

    /// Write the whole board config (widgets + board-level settings) as JSON to a
    /// user-chosen file. Placement ids are regenerated on import, so a file can be
    /// applied to several machines without collisions.
    private func exportLayout() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "monitor-layout.json"
        panel.canCreateDirectories = true
        panel.title = String(localized: "Export Monitor Layout", comment: "Save-panel title for exporting a monitor board layout.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(draft).write(to: url, options: .atomic)
        } catch {
            presentLayoutError(error, isImport: false)
        }
    }

    private func importLayout() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = String(localized: "Import Monitor Layout", comment: "Open-panel title for importing a monitor board layout.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let imported = try JSONDecoder().decode(MonitorBoardConfiguration.self, from: data)
            // Fresh ids so an imported file can't collide with live placements, and
            // keep the current schema version regardless of the file's origin.
            var next = imported
            next.widgets = imported.widgets.map { w in
                MonitorWidgetPlacement(kind: w.kind, size: w.size, x: w.x, y: w.y, options: w.options)
            }
            next.schemaVersion = MonitorBoardConfiguration.currentSchemaVersion
            settingsWidgetID = nil
            commit(next)
        } catch {
            presentLayoutError(error, isImport: true)
        }
    }

    private func presentLayoutError(_ error: Error, isImport: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = isImport
            ? String(localized: "Couldn't import that layout", comment: "Alert title when a monitor layout file fails to import.")
            : String(localized: "Couldn't export the layout", comment: "Alert title when a monitor layout file fails to export.")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button on the monitor layout error alert."))
        if let window = hostWindow() {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    /// Board-level edits made in THIS inspector go through the NON-restarting board
    /// path (`persistMonitorConfigurationFromBoard`): every control here — refresh
    /// rate, mouse interaction, reduce-motion, per-widget options — applies in place
    /// on the live board and preview, so a full session rebuild (which would flicker
    /// the wallpaper and churn its lease/window) is never warranted.
    ///
    /// The `draft` write is synchronous (so the control itself doesn't visually
    /// snap back), but the `ScreenManager` call is deferred to the next runloop
    /// tick: it reaches `wallpaperSessionState`, an `@Observable` property that
    /// ancestor views (the toggle's own window) are still mid-update on when a
    /// Binding's `set` fires (Toggle/Slider/Picker) — committing there synchronously
    /// trips "Publishing changes from within view updates", the same class of bug
    /// `scheduleMonitorOverlayReconcile` defers in `ScreenManager`.
    private func commit(_ config: MonitorBoardConfiguration) {
        draft = config
        Task { @MainActor in
            screenManager.persistMonitorConfigurationFromBoard(config, for: screen)
        }
    }

    // MARK: - Loading

    private func reload() {
        if case .monitor(let board)? = screenManager.getConfiguration(for: screen)?.activeWallpaper {
            draft = board
        } else {
            draft = .default
        }
        if !draft.widgets.contains(where: { $0.id == settingsWidgetID }) {
            settingsWidgetID = nil
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

    // MARK: - Formatting helpers

    nonisolated static func refreshHzLabel(_ hz: Double) -> String {
        let clamped = MonitorBoardConfiguration.clampedRefreshHz(hz)
        return String(format: "%.1f Hz", clamped)
    }

}

// MARK: - Reduce-motion tri-state

/// Tri-state mapping for `reduceMotionOverride`: follow system (nil) / force on
/// (true) / force off (false).
enum ReduceMotionChoice: Hashable {
    case system
    case on
    case off

    init(_ override: Bool?) {
        switch override {
        case .none: self = .system
        case .some(true): self = .on
        case .some(false): self = .off
        }
    }

    var override: Bool? {
        switch self {
        case .system: return nil
        case .on: return true
        case .off: return false
        }
    }
}
