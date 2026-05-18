#if !LITE_BUILD
#if DEBUG
import SwiftUI
import AppKit

/// DEBUG-only Phase A.3 corpus playback test menu. Streams a
/// `WPECorpusPlaybackHarness` run, surfaces per-scene outcomes in a table,
/// and lets the maintainer export the resulting JSON report for triage.
/// Compiled out of Release so end users never see (and the bundle never
/// carries) this UI.
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
        if isRunning {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(verbatim: progressLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else if let summary = lastReport?.summary {
            Text(verbatim: summaryLabel(summary, total: lastReport?.total ?? entries.count))
                .foregroundStyle(.secondary)
        } else {
            Text("Phase A.3 — Corpus playback test")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
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

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            configurationSection
            if let startupError {
                errorBanner(startupError)
            }
            if isRunning {
                ProgressView(value: progressFraction)
                    .progressViewStyle(.linear)
            }
            resultsTable
        }
        .padding(16)
    }

    private var configurationSection: some View {
        GroupBox(label: Text("Configuration").font(.headline)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Per-scene timeout")
                    Slider(value: $perSceneTimeout, in: 3...30, step: 1)
                        .frame(width: 220)
                        .disabled(isRunning)
                    Text(verbatim: "\(Int(perSceneTimeout))s")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                Text("Iterates every imported scene workshop project, runs `WPEMetalSceneRenderer.load()` headlessly with the configured timeout, and aggregates pass/fail/timeout outcomes plus resolution diagnostics. The test window is held at alpha 0 behind the desktop — nothing flashes on screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
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
#endif
