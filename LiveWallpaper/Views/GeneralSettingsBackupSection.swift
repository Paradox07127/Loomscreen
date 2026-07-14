import Foundation
import LiveWallpaperCore
import SwiftUI

extension GeneralSettingsView {
    @ViewBuilder
    var backupSection: some View {
        Section {
            SettingRow(
                icon: "square.and.arrow.up",
                iconColor: .blue,
                title: "Export Configuration",
                subtitle: "Save settings, display defaults, bookmarks, and per-display setup to a .lwconfig file",
                info: "The bundle includes global preferences, display defaults, wallpaper library bookmarks, and per-display playback / effect setup. Wallpaper files themselves are not copied — only references to them."
            ) {
                Button("Export…") { beginExport() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityHint(Text("Save the current settings, display defaults, bookmarks, and per-display setup to a backup file"))
            }

            SettingRow(
                icon: "square.and.arrow.down",
                iconColor: .blue,
                title: "Import Configuration",
                subtitle: "Restore from a previously exported .lwconfig file",
                info: "Importing replaces the current global preferences, display defaults, and per-display setup. Bookmarks from the backup are merged into your library — existing entries with the same source are kept."
            ) {
                Button("Import…") { beginImport() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityHint(Text("Restore settings, display defaults, bookmarks, and per-display setup from a backup file"))
            }
        } header: {
            Text("Backup & Restore")
        } footer: {
            Text("Backups store settings and references to your wallpaper files, not the files themselves — the originals must exist on the Mac you restore to.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Import / Export Action Handlers

    private func beginExport() {
        do {
            exportDocument = try ConfigurationDocument.snapshot()
            isPresentingExporter = true
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    private func beginImport() {
        isPresentingImporter = true
    }

    func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let source = urls.first else { return }
            let didStartAccess = source.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    source.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let bundle = try ConfigurationPorter.decode(from: source)
                pendingImportSource = source
                pendingImportBundle = bundle
            } catch let error as ConfigurationPorter.ImportError {
                importErrorMessage = error.errorDescription
            } catch {
                importErrorMessage = error.localizedDescription
            }

        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                importErrorMessage = error.localizedDescription
            }
        }
    }

    func applyPendingImport() {
        guard let bundle = pendingImportBundle else { return }
        let summary = ConfigurationPorter.apply(bundle)
        pendingImportBundle = nil
        pendingImportSource = nil

        postSettingsNotificationAsync(.dockVisibilityDidChange)
        postSettingsNotificationAsync(.globalShortcutsDidChange)
        postSettingsNotificationAsync(.weatherLocationPreferenceDidChange)
        screenManager.handleGlobalSettingsChanged()
        screenManager.resetAllWallpaperSessions()
        screenManager.refreshScreens(preserveRuntimeSessions: false)

        let settings = SettingsManager.shared.loadGlobalSettings()
        globalPauseOnBattery = settings.globalPauseOnBattery
        startOnLogin = settings.startOnLogin
        preservePlaybackOnLock = settings.preservePlaybackOnLock
        pauseOnFullScreen = settings.pauseOnFullScreen
        pauseInGameMode = settings.pauseInGameMode
        pauseOnWindowOcclusion = settings.pauseOnWindowOcclusion
        applicationRules = settings.applicationPerformanceRules
        showInDock = settings.showInDock
        developerModeEnabled = settings.developerModeEnabled
        audioResponseEnabled = settings.audioResponseEnabled
        weatherLocation = settings.weatherLocation
        #if !LITE_BUILD
        applyAudioResponseEnabled(settings.audioResponseEnabled)
        #endif
        postSettingsNotificationAsync(.developerModeDidChange)

        let feedback = importFeedbackMessage(for: summary)
        DispatchQueue.main.async {
            importFeedback = feedback
        }
    }

    /// Individual `String(localized:)` per section so each gets its own xcstrings pluralization rule (no manual "(s)", no concatenation).
    private func importFeedbackMessage(for summary: ConfigurationPorter.ApplySummary) -> String {
        guard !summary.isEmpty else {
            return String(
                localized: "Imported file contained no recognizable settings.",
                comment: "Toast shown after importing an empty configuration bundle."
            )
        }

        var lines: [String] = []
        if let count = summary.displayCount {
            lines.append(String(
                localized: "Restored \(count) display configurations.",
                comment: "Import success line: how many displays were restored. xcstrings provides a pluralized variant."
            ))
        }
        if summary.didRestoreGlobalSettings {
            lines.append(String(
                localized: "Restored global preferences, display defaults, schedule, and shortcuts.",
                comment: "Import success line: global settings were restored."
            ))
        }
        if let count = summary.bookmarkCount {
            lines.append(String(
                localized: "Restored \(count) saved bookmarks.",
                comment: "Import success line: how many bookmarks were restored. xcstrings provides a pluralized variant."
            ))
        }
        return lines.joined(separator: "\n")
    }

    var importConfirmationMessage: String {
        guard let bundle = pendingImportBundle else { return "" }
        var lines: [String] = []
        if let count = bundle.screenConfigurations?.count {
            lines.append(String(
                localized: "• \(count) display configurations",
                comment: "Import confirmation bullet: how many displays the bundle includes. xcstrings provides a pluralized variant."
            ))
        }
        if bundle.globalSettings != nil {
            lines.append(String(
                localized: "• Global settings (preferences, display defaults, schedule, shortcuts)",
                comment: "Import confirmation bullet: presence of global settings."
            ))
        }
        if let count = bundle.wallpaperBookmarks?.count {
            lines.append(String(
                localized: "• \(count) saved bookmarks",
                comment: "Import confirmation bullet: how many bookmarks the bundle includes. xcstrings provides a pluralized variant."
            ))
        }

        let summary = lines.isEmpty
            ? String(
                localized: "The file contains no recognizable settings.",
                comment: "Import confirmation when bundle is empty."
            )
            : lines.joined(separator: "\n")

        return String(
            localized: "\(summary)\n\n\(localizedBookmarkPortabilityWarning)\n\nReplace current configuration?",
            comment: "Import confirmation alert message. First placeholder is a bulleted list of restored sections; second is the device-portability warning."
        )
    }

    private var localizedBookmarkPortabilityWarning: String {
        String(
            localized: "Selected files and folders will need to be re-granted on this Mac because security bookmarks are device-specific.",
            comment: "Import confirmation footer warning about cross-device bookmark portability."
        )
    }
}
