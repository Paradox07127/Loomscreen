#if !LITE_BUILD
import SwiftUI
import AppKit

/// Pro-only diagnostic surface gated at runtime by the Developer Mode
/// toggle in Settings → General → Advanced. The sidebar entry is hidden
/// by default and only appears once the user opts in, so end users never
/// see this view unless they go looking for it. Streams a
/// `WPECorpusPlaybackHarness` run, surfaces per-scene outcomes in a table,
/// and lets the maintainer export the resulting JSON report for triage.
struct DeveloperToolsView: View {
    @State private var isRunning = false
    @State private var progressLabel: String = ""
    @State private var progressFraction: Double = 0
    @State private var entries: [WPECorpusPlaybackReport.Entry] = []
    @State private var lastReport: WPECorpusPlaybackReport?
    @State private var startupError: String?
    @State private var perSceneTimeout: Double = 8
    @State private var cancelRequested = false
    @State private var runTask: Task<Void, Never>?
    @State private var singleSceneWorkshopID: String = ""
    @State private var singleSceneStatus: String = ""
    @State private var flagRefresh = 0
    @State private var waterWavesDebug = WPEWaterWavesDebugMode.current
    @State private var selectedTab: DevToolsTab = .corpusTest

    private enum DevToolsTab: String, CaseIterable, Identifiable {
        case corpusTest
        case diagnostics
        var id: String { rawValue }
        var title: String {
            switch self {
            case .corpusTest: return "Corpus Test"
            case .diagnostics: return "Diagnostics"
            }
        }
    }

    var body: some View {
        DetailPageScaffold(
            showsHeader: true,
            header: { header },
            content: { content }
        )
        .onDisappear {
            runTask?.cancel()
            cancelRequested = true
        }
    }

    private var header: some View {
        DetailHeaderBar(
            systemImage: "wrench.and.screwdriver",
            title: { Text("Developer Tools") },
            metadata: { metadata },
            actions: { actions }
        )
    }

    @ViewBuilder
    private var metadata: some View {
        if selectedTab == .diagnostics {
            Text("Diagnostic flags — persist until toggled off or reset.", comment: "Developer Tools header subtitle on the diagnostics tab.")
                .foregroundStyle(.secondary)
        } else if isRunning {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(verbatim: progressLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else if let report = lastReport {
            Text(verbatim: "[\(report.renderer)] \(summaryLabel(report.summary, total: report.total))")
                .foregroundStyle(.secondary)
        } else {
            Text("Visible while Developer Mode is on. Disable it in Settings → General → Advanced.", comment: "Developer Tools header subtitle explaining the runtime gate.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if selectedTab == .corpusTest {
            HStack(spacing: 8) {
                if isRunning {
                Button(role: .destructive) {
                    cancelRequested = true
                    runTask?.cancel()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else {
                Button {
                    startRun()
                } label: {
                    Label("Run corpus playback test", systemImage: "play.fill")
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button {
                    exportReport()
                } label: {
                    Label("Export JSON", systemImage: "square.and.arrow.up")
                }
                .disabled(lastReport == nil)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(selection: $selectedTab) {
                ForEach(DevToolsTab.allCases) { tab in
                    Text(verbatim: tab.title).tag(tab)
                }
            } label: {
                Text(verbatim: "Developer Tools section")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch selectedTab {
            case .corpusTest:
                corpusTestContent
            case .diagnostics:
                diagnosticsFlagsSection
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var corpusTestContent: some View {
        configurationSection
        sceneDebugSection
        if let startupError {
            errorBanner(startupError)
        }
        if isRunning {
            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
        }
        resultsTable
    }

    /// Per-scene debug iteration loop. Runs `WPECorpusPlaybackHarness` with
    /// a single-workshop filter so the maintainer gets one fully-traced
    /// load — every shader compile failure, FBO miss, first-frame snapshot,
    /// and pipeline-state error lands under
    /// `~/Library/Application Support/LiveWallpaper/scene-debug/<ts>-<id>/`.
    @ViewBuilder
    private var sceneDebugSection: some View {
        GroupBox(label: Text("Single-scene debug").font(.headline)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField(
                        "Workshop ID",
                        text: $singleSceneWorkshopID
                    )
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .frame(maxWidth: 200)
                    .disabled(isRunning)

                    Button {
                        runSingleSceneDebug()
                    } label: {
                        Label("Run debug load", systemImage: "play.fill")
                    }
                    .disabled(isRunning || singleSceneWorkshopID.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button {
                        revealDebugArtifacts()
                    } label: {
                        Label("Reveal artifacts in Finder", systemImage: "folder")
                    }
                    .disabled(WPESceneDebugArtifacts.rootURL == nil)
                }
                if !singleSceneStatus.isEmpty {
                    Text(verbatim: singleSceneStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Headless single-scene load with full pipeline tracing. Every shader compile error, FBO miss, first-frame snapshot lands under scene-debug as `<timestamp>-<workshopID>/`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var configurationSection: some View {
        GroupBox(label: Text("Configuration").font(.headline)) {
            VStack(alignment: .leading, spacing: 12) {
                wpeRuntimeToggle
                Divider()
                HStack {
                    Text("Per-scene timeout")
                    Slider(value: $perSceneTimeout, in: 3...30, step: 1)
                        .frame(width: 220)
                        .disabled(isRunning)
                    Text(verbatim: "\(Int(perSceneTimeout))s")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                Text("Iterates every imported scene workshop project, runs `WPESceneRenderer.load()` headlessly with the configured timeout, and aggregates pass/fail/timeout outcomes plus resolution diagnostics. Uses the active renderer (Metal or WebGL2 — controlled by the toggle above). The test window is held at alpha 0 behind the desktop — nothing flashes on screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    @State private var runtimeSelection: WPERuntimeSelection = WPERuntimeSelection.current

    @ViewBuilder
    private var wpeRuntimeToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: Binding(
                get: { runtimeSelection },
                set: { newValue in
                    guard runtimeSelection != newValue else { return }
                    runtimeSelection = newValue
                    UserDefaults.standard.set(newValue.rawValue, forKey: WPERuntimeSelection.defaultsKey)
                }
            )) {
                Text(verbatim: "Automatic").tag(WPERuntimeSelection.automatic)
                Text(verbatim: "Metal").tag(WPERuntimeSelection.metal)
                Text(verbatim: "WebGL2").tag(WPERuntimeSelection.webGL)
            } label: {
                Text(verbatim: "Scene runtime")
            }
            .pickerStyle(.segmented)

            Text(verbatim: "Automatic = WPESceneBackendRouter picks per scene (BC textures → Metal, RGBA + video → WebGL).  Metal / WebGL2 pin every scene to that backend.  Mirror of `defaults write Taijia.LiveWallpaper \(WPERuntimeSelection.defaultsKey)`.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: "Takes effect on the next scene-wallpaper load — already-running scenes keep the renderer they started with. Default is Automatic; user pins override the router.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Diagnostic flags

    private struct DiagnosticBoolFlag: Identifiable {
        let key: String
        let title: String
        let help: String
        var id: String { key }
    }

    private static let diagnosticBoolFlags: [DiagnosticBoolFlag] = [
        .init(key: "WPEMetalCaptureScene", title: "Capture scene textures",
              help: "Dump decoded scene/composite textures (incl. BC/DXT) under scene-debug."),
        .init(key: "WPEMetalBypassEffects", title: "Bypass effect passes",
              help: "Draw only base image layers, skipping effects (note: breaks solid-color layers)."),
        .init(key: "WPEPuppetEnableSkinning", title: "Puppet bone skinning",
              help: "Apply MDLA bone animation to puppets. Off by default — waterwaves drives the visible hair motion."),
        .init(key: "WPESceneDebugArtifactsEnabled", title: "Scene debug artifacts",
              help: "Write per-scene logs, first-frame snapshot, and texture metadata to scene-debug."),
        .init(key: "WPEAudioCaptureProbe", title: "Audio capture probe",
              help: "Probe the Core Audio process tap under the sandbox (audio-reactive bring-up)."),
        .init(key: "WPEAudioDebugLog", title: "Audio debug log",
              help: "Verbose audio-reactive DSP logging."),
        .init(key: "WPE_METAL_LEGACY_COMPOSE_LAYER", title: "Legacy compose layer",
              help: "Roll back to the pre-fix scaled-footprint compose-layer path."),
    ]

    private static let diagnosticStringKeys: [String] = [
        WPEWaterWavesDebugMode.defaultsKey,
        "WPEDumpScenePasses",
        "WPEDumpScenePassesAtTime",
        "WPE_METAL_LEGACY_COMPOSE_SCENES",
    ]

    private var diagnosticsFlagsSection: some View {
        GroupBox(label:
            HStack {
                Text("WPE diagnostics").font(.headline)
                Spacer()
                Button {
                    resetDiagnosticFlags()
                } label: {
                    Label("Reset all", systemImage: "arrow.counterclockwise")
                }
                .help(Text("Turn every diagnostic flag off so none leak into normal playback or other sessions."))
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Picker(selection: Binding(
                        get: { waterWavesDebug },
                        set: { setWaterWavesDebug($0) }
                    )) {
                        ForEach(WPEWaterWavesDebugMode.allCases) { mode in
                            Text(verbatim: mode.title).tag(mode)
                        }
                    } label: {
                        Text(verbatim: "Waterwaves debug")
                    }
                    Text(verbatim: "Visualize where the waterwaves effect triggers: Mask / Overlay show the masked region on the character, Displacement shows the wave field. Applies on the next rendered frame.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                ForEach(Self.diagnosticBoolFlags) { flag in
                    Toggle(isOn: boolBinding(flag.key)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: flag.title)
                            Text(verbatim: flag.help)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text(verbatim: "Flags persist in UserDefaults until toggled off. \"Reset all\" clears every flag here (including scene-dump targets) so a forgotten toggle never affects normal playback.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .id(flagRefresh)
        }
    }

    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: key) },
            set: { newValue in
                UserDefaults.standard.set(newValue, forKey: key)
                flagRefresh += 1
            }
        )
    }

    private func setWaterWavesDebug(_ mode: WPEWaterWavesDebugMode) {
        waterWavesDebug = mode
        if mode == .off {
            UserDefaults.standard.removeObject(forKey: WPEWaterWavesDebugMode.defaultsKey)
        } else {
            UserDefaults.standard.set(mode.storageValue, forKey: WPEWaterWavesDebugMode.defaultsKey)
        }
    }

    private func resetDiagnosticFlags() {
        for flag in Self.diagnosticBoolFlags {
            UserDefaults.standard.removeObject(forKey: flag.key)
        }
        for key in Self.diagnosticStringKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        waterWavesDebug = .off
        flagRefresh += 1
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var resultsTable: some View {
        Table(entries) {
            TableColumn("Workshop ID") { entry in
                Text(verbatim: entry.workshopID).monospaced()
            }
            .width(min: 100, ideal: 120)

            TableColumn("Title") { entry in
                Text(verbatim: entry.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: entry.title))
            }
            .width(min: 120, ideal: 220)

            TableColumn("Result") { entry in
                Label(entry.result.rawValue.capitalized, systemImage: resultIcon(entry.result))
                    .foregroundStyle(resultColor(entry.result))
            }
            .width(min: 80, ideal: 100)

            TableColumn("Tier") { entry in
                Text(verbatim: entry.preflightTier?.localizedLabel ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130)

            TableColumn("Backend") { entry in
                Text(verbatim: backendLabel(for: entry))
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Elapsed") { entry in
                Text(verbatim: String(format: "%.2fs", entry.elapsedSeconds))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 70)

            TableColumn("Resolved / Missing") { entry in
                Text(verbatim: "\(entry.resolution.resolved) / \(entry.resolution.missing)")
                    .monospacedDigit()
                    .foregroundStyle(entry.resolution.missing > 0 ? .orange : .secondary)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Failure") { entry in
                Text(verbatim: entry.failureMessage ?? "")
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                    .help(Text(verbatim: failureHelp(for: entry)))
            }
        }
        .frame(minHeight: 280)
    }

    // MARK: - Single-scene debug

    private func runSingleSceneDebug() {
        let trimmed = singleSceneWorkshopID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isRunning else { return }

        isRunning = true
        cancelRequested = false
        startupError = nil
        entries.removeAll()
        lastReport = nil
        progressFraction = 0
        singleSceneStatus = "Loading \(trimmed)…"
        progressLabel = singleSceneStatus

        var config = WPECorpusPlaybackHarness.Configuration(
            perSceneTimeoutSeconds: perSceneTimeout
        )
        config.workshopIDFilter = [trimmed]
        let harness = WPECorpusPlaybackHarness(configuration: config)

        runTask = Task { @MainActor in
            await harness.run(
                progress: handleProgress,
                isCancelled: { self.cancelRequested }
            )
            self.isRunning = false
            if let path = WPESceneDebugArtifacts.rootURL?.path {
                self.singleSceneStatus = "Done — artifacts under \(path)/<timestamp>-\(trimmed)/"
            } else {
                self.singleSceneStatus = "Done — artifacts directory unavailable"
            }
        }
    }

    private func revealDebugArtifacts() {
        guard let root = WPESceneDebugArtifacts.rootURL else { return }
        let fm = FileManager.default
        // Try to surface the most recent session for the entered workshop
        // ID; fall back to the parent folder when nothing's there yet.
        let trimmed = singleSceneWorkshopID.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty,
           let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: []),
           let latest = children
            .filter({ $0.lastPathComponent.contains(trimmed) })
            .sorted(by: { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            })
            .first {
            NSWorkspace.shared.activateFileViewerSelecting([latest])
            return
        }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    // MARK: - Run lifecycle

    private func startRun() {
        guard !isRunning else { return }
        isRunning = true
        cancelRequested = false
        startupError = nil
        entries.removeAll()
        lastReport = nil
        progressFraction = 0
        progressLabel = String(
            localized: "Scanning library…",
            defaultValue: "Scanning library…",
            comment: "Developer tools progress shown while scanning the local Wallpaper Engine corpus."
        )

        let config = WPECorpusPlaybackHarness.Configuration(
            perSceneTimeoutSeconds: perSceneTimeout
        )
        let harness = WPECorpusPlaybackHarness(configuration: config)

        runTask = Task { @MainActor in
            await harness.run(
                progress: handleProgress,
                isCancelled: { self.cancelRequested }
            )
            self.isRunning = false
        }
    }

    @MainActor
    private func handleProgress(_ progress: WPECorpusPlaybackHarness.Progress) {
        switch progress {
        case .scanning:
            progressLabel = String(
                localized: "Scanning library…",
                defaultValue: "Scanning library…",
                comment: "Developer tools progress shown while scanning the local Wallpaper Engine corpus."
            )
        case .running(let index, let total, let workshopID, let title):
            let displayTitle = title.isEmpty ? workshopID : title
            progressLabel = String(
                localized: "Running \(index)/\(total) — \(displayTitle)",
                comment: "Developer tools progress. Placeholders are current index, total count, and current scene title or Workshop ID."
            )
            progressFraction = total > 0 ? Double(index) / Double(total) : 0
        case .sceneComplete(let entry):
            entries.append(entry)
        case .finished(let report):
            lastReport = report
            progressLabel = String(
                localized: "Finished — \(summaryLabel(report.summary, total: report.total))",
                comment: "Developer tools progress after a corpus run completes. The placeholder is a compact result summary."
            )
            progressFraction = 1
        case .cancelled(let partial):
            lastReport = partial
            progressLabel = String(
                localized: "Cancelled — \(summaryLabel(partial.summary, total: partial.total)) (partial)",
                comment: "Developer tools progress after a corpus run is cancelled. The placeholder is a compact partial result summary."
            )
        case .failedToStart(let message):
            startupError = message
            progressLabel = ""
            progressFraction = 0
        }
    }

    // MARK: - Export

    private func exportReport() {
        guard let report = lastReport else { return }

        let fileManager = FileManager.default
        let supportRoot: URL
        do {
            supportRoot = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            startupError = String(
                localized: "Export failed: cannot locate Application Support — \(error.localizedDescription)",
                comment: "Developer tools export error. The placeholder is the system error description."
            )
            Logger.error("WPE corpus playback export: cannot locate Application Support — \(error.localizedDescription)", category: .screenManager)
            return
        }
        let exportDirectory = supportRoot
            .appendingPathComponent("LiveWallpaper", isDirectory: true)
            .appendingPathComponent("corpus-reports", isDirectory: true)
        let fileURL = exportDirectory.appendingPathComponent(defaultExportName(for: report))

        do {
            try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            try data.write(to: fileURL, options: .atomic)
            Logger.info("WPE corpus playback report exported to \(fileURL.path)", category: .screenManager)
            startupError = nil
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } catch {
            startupError = String(
                localized: "Export failed: \(error.localizedDescription)",
                comment: "Developer tools export error. The placeholder is the system error description."
            )
            Logger.error("WPE corpus playback report export failed: \(error.localizedDescription)", category: .screenManager)
        }
    }

    private func defaultExportName(for report: WPECorpusPlaybackReport) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let stamp = formatter.string(from: report.generatedAt)
            .replacingOccurrences(of: ":", with: "-")
        return "wpe-corpus-playback-\(stamp).json"
    }

    // MARK: - Formatting helpers

    private func summaryLabel(_ summary: WPECorpusPlaybackReport.Summary, total: Int) -> String {
        let completed = summary.passCount + summary.failCount + summary.timeoutCount + summary.skippedCount
        return "\(completed)/\(total) — pass \(summary.passCount) · fail \(summary.failCount) · timeout \(summary.timeoutCount) · skipped \(summary.skippedCount)"
    }

    private func resultIcon(_ result: WPECorpusPlaybackReport.Entry.Outcome) -> String {
        switch result {
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.octagon.fill"
        case .timeout: return "clock.badge.exclamationmark"
        case .skipped: return "minus.circle"
        }
    }

    private func resultColor(_ result: WPECorpusPlaybackReport.Entry.Outcome) -> Color {
        switch result {
        case .pass: return .green
        case .fail: return .red
        case .timeout: return .orange
        case .skipped: return .secondary
        }
    }

    private func backendLabel(for entry: WPECorpusPlaybackReport.Entry) -> String {
        guard let renderer = entry.renderer else { return "—" }
        guard let routedBy = entry.routedBy else { return renderer }
        switch routedBy {
        case .user:
            return renderer
        case .automatic:
            return "\(renderer) (auto)"
        }
    }

    private func failureHelp(for entry: WPECorpusPlaybackReport.Entry) -> String {
        var lines: [String] = []
        if let message = entry.failureMessage, !message.isEmpty {
            lines.append(message)
        }
        if !entry.resolution.firstMisses.isEmpty {
            lines.append("First misses:")
            for miss in entry.resolution.firstMisses {
                lines.append("  • \(miss)")
            }
        }
        return lines.isEmpty ? entry.title : lines.joined(separator: "\n")
    }
}
#endif
