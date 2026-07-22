import AppKit
import LiveWallpaperCore
import SwiftUI

extension GeneralSettingsView {
    /// The Developer Mode toggle (and the Developer Tools surface it reveals)
    /// compiles into local Pro DEBUG builds only — never a Release binary — so
    /// end users can't reach the diagnostic harness or the HTML Web Inspector.
    /// "Log Files" stays in every Pro build so users can still grab logs for a
    /// bug report.
    @ViewBuilder
    var advancedSection: some View {
        Section {
            #if DEBUG && !LITE_BUILD
            SettingRow(
                icon: "wrench.and.screwdriver",
                iconColor: .orange,
                title: "Developer Mode",
                subtitle: "Show Developer Tools in the sidebar and enable right-click Inspect Element on web wallpapers.",
                info: "When on, web wallpapers open with WebKit's Web Inspector accessible — right-click in a webview wallpaper to inspect. Recommended only when debugging your own content."
            ) {
                Toggle("", isOn: $developerModeEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: developerModeEnabled) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Developer Mode"))
                    .accessibilityHint(Text("Reveals diagnostic tools and the web inspector. Off by default."))
            }
            #endif

            SettingRow(
                icon: "doc.on.doc",
                iconColor: .blue,
                title: "Copy Diagnostic Summary",
                subtitle: "Copy a sanitized system and runtime summary."
            ) {
                Button("Copy") { copyDiagnosticsSummary() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel(Text("Copy diagnostic summary"))
            }

            SettingRow(
                icon: "square.and.arrow.up",
                iconColor: .blue,
                title: "Export Diagnostics",
                subtitle: "Save a sanitized diagnostic report as a text file."
            ) {
                Button("Export…") { beginDiagnosticsExport() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel(Text("Export diagnostics"))
            }

            SettingRow(
                icon: "ladybug",
                iconColor: .red,
                title: "Report a Bug",
                subtitle: "Review diagnostics before opening a GitHub issue."
            ) {
                Button("Open…") { presentBugReport() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel(Text("Report a bug"))
            }

            SettingRow(
                icon: "doc.text.magnifyingglass",
                iconColor: .orange,
                title: "Log Files",
                subtitle: "Open the folder containing the app's diagnostic logs."
            ) {
                Button("Show in Finder") { revealLogFolder() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel(Text("Show logs in Finder"))
                    .accessibilityHint(Text("Opens the folder containing the app's log files"))
            }
        } header: {
            Text("Advanced", comment: "Section header for diagnostics and developer settings.")
        }
    }

    // MARK: - Diagnostics Actions

    func presentBugReport() {
        pendingBugReport = makeDiagnosticsReport()
    }

    private func copyDiagnosticsSummary() {
        let report = makeDiagnosticsReport()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.diagnosticMarkdown, forType: .string)
    }

    private func beginDiagnosticsExport() {
        diagnosticsDocument = DiagnosticDocument(text: makeDiagnosticsReport().diagnosticMarkdown)
        isPresentingDiagnosticsExporter = true
    }

    private func makeDiagnosticsReport() -> BugReport {
        BugReporter.makeReport(activeWallpaperKinds: activeWallpaperKinds)
    }

    private var activeWallpaperKinds: [String] {
        screenManager.wallpaperSessionSummaries
            .compactMap { $0.wallpaperType?.rawValue }
    }

    private func revealLogFolder() {
        if let logURL = Logger.persistentLogFileURL {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
            return
        }
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/LiveWallpaper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}
