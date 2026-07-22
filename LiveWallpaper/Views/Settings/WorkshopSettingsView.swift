#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

struct WorkshopSettingsView: View {
    @Environment(SteamCMDDoctorService.self) private var doctorService
    @Environment(WorkshopServices.self) private var workshopServices

    @AppStorage("loomscreen.workshop.blurMatureThumbnails.v1") private var blurMatureThumbnails = true
    @AppStorage("loomscreen.workshop.hidesDownloaded.v1") private var hidesDownloadedInBrowse = false

    @State private var engineAssets = WPEEngineAssetsLibrary.shared
    @State private var engineInstaller = WPEEngineAssetsInstaller.shared
    @State private var preflightingDoctor = false
    @State private var showingDoctor = false
    @State private var showingRemoveConfirm = false
    @State private var showingKeyEntry = false
    @Binding private var pendingSearchAnchor: SettingsSearchAnchor?

    init(pendingSearchAnchor: Binding<SettingsSearchAnchor?> = .constant(nil)) {
        _pendingSearchAnchor = pendingSearchAnchor
    }

    var body: some View {
        Form {
            Section {
                SettingRow(
                    icon: "key",
                    iconColor: .orange,
                    title: "Steam Web API key",
                    titleBadge: keyTitleBadge,
                    subtitle: "Your own free key — required to browse the Workshop online",
                    info: "The key belongs to your own Steam account, not Loomscreen. Calls go directly to Valve over HTTPS, and the key is stored only in this Mac's Keychain (no iCloud sync). Get one free at steamcommunity.com/dev/apikey."
                ) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        if workshopServices.hasWebAPIKey {
                            Button("Replace") { showingKeyEntry = true }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help(Text("Set a new Steam Web API key"))
                            Button("Forget", role: .destructive) {
                                Task {
                                    try? await workshopServices.keychain.deleteWebAPIKey()
                                    await workshopServices.refreshAPIKeyStatus()
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(Text(verbatim: WorkshopAPIKeyOwnershipInfo.forgetTooltip))
                        } else {
                            Button("Set key") { showingKeyEntry = true }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .help(Text("Paste your Steam Web API key"))
                        }
                    }
                    .fixedSize()
                }

                SettingRow(
                    icon: "stethoscope",
                    iconColor: .teal,
                    title: "SteamCMD Doctor",
                    titleBadge: doctorTitleBadge,
                    subtitle: "Check SteamCMD and Steam sign-in before downloading",
                    info: "Downloading from the Workshop needs the official SteamCMD command-line tool plus your own Steam sign-in. The Doctor runs probes and tells you exactly what's missing."
                ) {
                    Button("Open") { showingDoctor = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                        .help(Text("Open the SteamCMD diagnostics sheet"))
                }

                SettingRow(
                    icon: "shippingbox",
                    iconColor: .brown,
                    title: "Wallpaper Engine assets",
                    titleBadge: engineTitleBadge,
                    subtitle: "Optional — link a WPE install for extra scene coverage",
                    info: "Loomscreen bundles clean-room equivalents of the common Wallpaper Engine framework files, so most scenes render without a Wallpaper Engine install. Link one only for scenes that reference uncommon shared assets — read-only access, no files are modified."
                ) {
                    engineAssetsControl
                        .frame(maxHeight: 24)
                }
                if let status = engineAssetsStatusLine {
                    Text(verbatim: status.message)
                        .font(.caption)
                        .foregroundStyle(status.tint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                SettingsSearchSectionHeader("Setup", anchor: .workshopSetup)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Loomscreen never reads or stores your Steam password, Steam Guard codes, or session tokens.")
                    Text("Forget deletes only this Mac's local copy of the key; it stays active on your Steam account until you revoke it at steamcommunity.com/dev/apikey.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                SettingRow(
                    icon: "eye.slash",
                    iconColor: .pink,
                    title: "Blur mature thumbnails",
                    subtitle: "Hide Mature covers in Browse until you click to reveal"
                ) {
                    Toggle("", isOn: $blurMatureThumbnails)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(Text("Blur mature thumbnails until clicked"))
                }
                SettingRow(
                    icon: "tray.full",
                    iconColor: .indigo,
                    title: "Hide items already in my library",
                    subtitle: "Keep Browse Online focused on wallpapers you don't have yet"
                ) {
                    Toggle("", isOn: $hidesDownloadedInBrowse)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(Text("Hide items already in my library when browsing"))
                }
            } header: {
                SettingsSearchSectionHeader("Content", anchor: .workshopContent)
            }
        }
        .settingsFormChrome()
        .settingsSearchAnchorScroller(
            pendingSearchAnchor: $pendingSearchAnchor,
            anchors: [
                .workshopSetup,
                .workshopContent
            ]
        )
        .overlay(alignment: .bottomTrailing) {
            WorkshopDownloadToastHost()
                .padding(DesignTokens.Spacing.lg)
        }
        .sheet(isPresented: $showingDoctor) {
            WorkshopDoctorView()
                .environment(doctorService)
        }
        .sheet(isPresented: $showingKeyEntry) {
            SteamWebAPIKeyEntrySheet(services: workshopServices) {
                Task { await workshopServices.refreshAPIKeyStatus() }
            }
        }
        .task {
            engineInstaller.refreshManagedInstallState()
            await workshopServices.refreshAPIKeyStatus()
        }
    }

    @ViewBuilder
    private var engineAssetsControl: some View {
        if preflightingDoctor {
            HStack(spacing: DesignTokens.Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
            }
        } else if engineInstaller.isBusy {
            engineAssetsBusyControl
        } else if engineInstaller.hasManagedInstall {
            engineAssetsManagedControl
        } else if engineAssets.isAuthorized {
            engineAssetsManualControl
        } else {
            engineAssetsUnlinkedControl
        }
    }

    /// Runs Workshop actions after a successful Doctor preflight.
    private func preflightThen(_ action: @escaping () -> Void) {
        // Engine downloads require configuration and cached login; advisory ownership status must not block recovery.
        if doctorService.isDownloadReady { action(); return }
        Task {
            preflightingDoctor = true
            await doctorService.runAll()
            preflightingDoctor = false
            if doctorService.isDownloadReady { action() } else { showingDoctor = true }
        }
    }

    @ViewBuilder
    private var engineAssetsBusyControl: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            switch engineInstaller.phase {
            case .downloading:
                if let fraction = engineInstaller.progress {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("Downloading…").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
                Button("Cancel") { engineInstaller.cancel() }
                    .buttonStyle(.bordered).controlSize(.small).fixedSize()
            case .pruning:
                ProgressView().controlSize(.small)
                Text("Finishing…").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking…").font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var engineAssetsManagedControl: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            if engineInstaller.updateAvailable {
                Button("Update") { preflightThen { engineInstaller.download(using: doctorService) } }
                    .buttonStyle(.borderedProminent).controlSize(.small).fixedSize()
            } else {
                Button("Check for updates") { preflightThen { engineInstaller.checkForUpdate(using: doctorService) } }
                    .buttonStyle(.bordered).controlSize(.small).fixedSize()
            }
            Button("Remove", role: .destructive) { showingRemoveConfirm = true }
                .buttonStyle(.bordered).controlSize(.small).fixedSize()
                .tint(DesignTokens.Colors.Status.danger)
                .help(Text("Delete the downloaded Wallpaper Engine assets and unlink"))
                .confirmationDialog(
                    Text("Remove Wallpaper Engine assets?"),
                    isPresented: $showingRemoveConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Remove", role: .destructive) { engineInstaller.remove() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This deletes the downloaded assets from this Mac. You can download them again anytime.")
                }
        }
    }

    @ViewBuilder
    private var engineAssetsManualControl: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Button("Change") { Task { await requestManualEngineAssetsAccess() } }
                .buttonStyle(.bordered).controlSize(.small).fixedSize()
                .help(Text("Pick a different Wallpaper Engine install folder"))
            Button("Forget", role: .destructive) {
                engineAssets.clearAccess()
                engineInstaller.clearTransientStatus()
            }
                .buttonStyle(.bordered).controlSize(.small).fixedSize()
                .tint(DesignTokens.Colors.Status.danger)
                .help(Text("Remove access to the Wallpaper Engine install folder"))
        }
    }

    @ViewBuilder
    private var engineAssetsUnlinkedControl: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Button("Download from Steam") {
                preflightThen { engineInstaller.download(using: doctorService) }
            }
            .buttonStyle(.bordered).controlSize(.small).fixedSize()
            .help(Text("Download the copy of Wallpaper Engine you own for extra scene coverage"))
            Button("Link folder…") { Task { await requestManualEngineAssetsAccess() } }
                .buttonStyle(.bordered).controlSize(.small).fixedSize()
                .help(Text("Grant read-only access to a Wallpaper Engine install for extra scene coverage"))
        }
    }

    private func requestManualEngineAssetsAccess() async {
        if await engineAssets.requestAccess() {
            engineInstaller.refreshManagedInstallState()
            engineInstaller.clearTransientStatus()
        }
    }

    private var showsEngineDownloadHint: Bool {
        !engineInstaller.isBusy
            && !engineInstaller.hasManagedInstall
            && !engineAssets.isAuthorized
            && !doctorService.isDownloadReady
    }

    private struct EngineAssetsStatusLine {
        let message: String
        let tint: Color
    }

    private var engineAssetsStatusLine: EngineAssetsStatusLine? {
        if case .failed(let message) = engineInstaller.phase {
            return EngineAssetsStatusLine(message: message, tint: DesignTokens.Colors.Status.danger)
        }
        if preflightingDoctor {
            return EngineAssetsStatusLine(
                message: String(localized: "Checking SteamCMD readiness before downloading.", comment: "Engine-assets settings status while preflighting SteamCMD."),
                tint: .secondary
            )
        }
        switch engineInstaller.phase {
        case .downloading:
            return EngineAssetsStatusLine(
                message: String(localized: "Downloading Wallpaper Engine, then Loomscreen will keep only the assets folder and link it automatically.", comment: "Engine-assets settings status while downloading."),
                tint: .secondary
            )
        case .pruning:
            return EngineAssetsStatusLine(
                message: String(localized: "Download finished. Keeping the assets folder and linking it now.", comment: "Engine-assets settings status while pruning the downloaded WPE app."),
                tint: .secondary
            )
        case .checking:
            return EngineAssetsStatusLine(
                message: String(localized: "Checking Steam for the latest Wallpaper Engine build.", comment: "Engine-assets settings status while checking for updates."),
                tint: .secondary
            )
        case .idle, .failed:
            break
        }
        if let error = engineAssets.lastError {
            return EngineAssetsStatusLine(message: error, tint: DesignTokens.Colors.Status.danger)
        }
        if engineInstaller.hasManagedInstall {
            return managedEngineAssetsStatusLine
        }
        if engineAssets.isAuthorized {
            let name = engineAssets.engineRootDisplayName ?? String(
                localized: "selected folder",
                comment: "Fallback display name for a manually linked engine-assets folder."
            )
            return EngineAssetsStatusLine(
                message: String(localized: "Linked to \(name) for extra scene coverage.", comment: "Engine-assets settings status for a manually linked folder."),
                tint: DesignTokens.Colors.Status.active
            )
        }
        if showsEngineDownloadHint {
            return EngineAssetsStatusLine(
                message: String(localized: "Set up SteamCMD in the Doctor to enable in-app download, or link an existing folder manually.", comment: "Engine-assets settings status when SteamCMD is not ready."),
                tint: .secondary
            )
        }
        return EngineAssetsStatusLine(
            message: String(localized: "Not linked. Most scenes still use Loomscreen's built-in equivalents.", comment: "Engine-assets settings status when no engine assets are linked."),
            tint: .secondary
        )
    }

    private var managedEngineAssetsStatusLine: EngineAssetsStatusLine {
        switch engineInstaller.updateCheckOutcome {
        case .available:
            return EngineAssetsStatusLine(
                message: String(localized: "Update available on Steam. Current downloaded assets are still linked.", comment: "Engine-assets settings status when an update is available."),
                tint: DesignTokens.Colors.Status.warning
            )
        case .upToDate:
            return EngineAssetsStatusLine(
                message: String(localized: "Downloaded assets linked and up to date.", comment: "Engine-assets settings status when downloaded assets are current."),
                tint: DesignTokens.Colors.Status.active
            )
        case .unableToCompare:
            return EngineAssetsStatusLine(
                message: String(localized: "Downloaded assets linked, but their version is unknown. Download again to refresh them.", comment: "Engine-assets settings status when installed build id is unknown."),
                tint: DesignTokens.Colors.Status.warning
            )
        case .checkFailed:
            return EngineAssetsStatusLine(
                message: String(localized: "Downloaded assets linked. Couldn't check Steam for updates.", comment: "Engine-assets settings status when update check fails."),
                tint: DesignTokens.Colors.Status.warning
            )
        case .checking:
            return EngineAssetsStatusLine(
                message: String(localized: "Checking Steam for the latest Wallpaper Engine build.", comment: "Engine-assets settings status while checking for updates."),
                tint: .secondary
            )
        case .notChecked:
            return EngineAssetsStatusLine(
                message: String(localized: "Downloaded assets linked for extra scene coverage.", comment: "Engine-assets settings status for downloaded assets before checking updates."),
                tint: DesignTokens.Colors.Status.active
            )
        }
    }

    // MARK: - Title status badges (uniform icon-only seals next to each name)

    private var keyTitleBadge: SettingRowTitleBadge {
        workshopServices.hasWebAPIKey
            ? SettingRowTitleBadge(systemImage: "checkmark.seal.fill", tint: DesignTokens.Colors.Status.active, accessibilityLabel: Text("Set"))
            : SettingRowTitleBadge(systemImage: "exclamationmark.triangle.fill", tint: DesignTokens.Colors.Status.warning, accessibilityLabel: Text("Not set"))
    }

    private var doctorTitleBadge: SettingRowTitleBadge? {
        switch doctorService.state {
        case .idle, .probing:
            return nil
        case .done(let allGreen, let blockingFailures):
            if allGreen {
                return SettingRowTitleBadge(systemImage: "checkmark.seal.fill", tint: DesignTokens.Colors.Status.active, accessibilityLabel: Text("All probes green"))
            } else if blockingFailures == 0 {
                return SettingRowTitleBadge(systemImage: "exclamationmark.triangle.fill", tint: DesignTokens.Colors.Status.warning, accessibilityLabel: Text("Warnings"))
            } else {
                return SettingRowTitleBadge(systemImage: "exclamationmark.octagon.fill", tint: DesignTokens.Colors.Status.danger, accessibilityLabel: Text("Has blockers"))
            }
        }
    }

    private var engineTitleBadge: SettingRowTitleBadge? {
        if engineInstaller.updateAvailable {
            return SettingRowTitleBadge(systemImage: "arrow.down.circle.fill", tint: DesignTokens.Colors.Status.warning, accessibilityLabel: Text("Update available"))
        }
        if engineInstaller.hasManagedInstall || engineAssets.isAuthorized {
            return SettingRowTitleBadge(systemImage: "checkmark.seal.fill", tint: DesignTokens.Colors.Status.active, accessibilityLabel: Text("Linked"))
        }
        return nil
    }

}
#endif
