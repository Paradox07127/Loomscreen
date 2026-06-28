#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

struct WorkshopSettingsView: View {
    @Environment(SteamCMDDoctorService.self) private var doctorService
    @Environment(WorkshopServices.self) private var workshopServices

    @AppStorage("loomscreen.workshop.blurMatureThumbnails.v1") private var blurMatureThumbnails = true
    @AppStorage("loomscreen.workshop.hidesDownloaded.v1") private var hidesDownloadedInBrowse = false

    @State private var engineAssets = WPEEngineAssetsLibrary.shared
    @State private var showingDoctor = false
    @State private var showingKeyEntry = false
    @State private var showingBrowse = false

    var body: some View {
        Form {
            Section {
                capabilityChips
            } header: {
                Text("Steam Workshop")
            } footer: {
                Text("Your Steam password, Steam Guard codes, and session tokens are never read or stored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                SettingRow(
                    icon: "key",
                    iconColor: .orange,
                    title: "Steam Web API key",
                    subtitle: "Your own free key — required to browse the Workshop online",
                    info: "The key belongs to your own Steam account, not Loomscreen. Calls go directly to Valve over HTTPS, and the key is stored only in this Mac's Keychain (no iCloud sync). Get one free at steamcommunity.com/dev/apikey."
                ) {
                    keyStatusBadge
                        .fixedSize()
                }

                HStack(spacing: DesignTokens.Spacing.xs) {
                    Spacer()
                    if workshopServices.hasWebAPIKey {
                        Button("Replace") { showingKeyEntry = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(Text("Set a new Steam Web API key"))
                        Button("Forget on this Mac", role: .destructive) {
                            Task {
                                try? await workshopServices.keychain.deleteWebAPIKey()
                                await workshopServices.refreshAPIKeyStatus()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(Text(verbatim: WorkshopAPIKeyOwnershipInfo.forgetTooltip))
                        Button("Browse online") { showingBrowse = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .help(Text("Open the Workshop browse sheet"))
                    } else {
                        Button("Set key") { showingKeyEntry = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .help(Text("Paste your Steam Web API key"))
                    }
                }

                SettingRow(
                    icon: "stethoscope",
                    iconColor: .teal,
                    title: "SteamCMD Doctor",
                    subtitle: "Check SteamCMD and Steam sign-in before downloading",
                    info: "Downloading from the Workshop needs the official SteamCMD command-line tool plus your own Steam sign-in. The Doctor runs probes and tells you exactly what's missing."
                ) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        doctorIndicator
                        Button("Open") { showingDoctor = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(Text("Open the SteamCMD diagnostics sheet"))
                    }
                    // Claim intrinsic width: SettingRow's title column is greedy
                    // (maxWidth:.infinity, layoutPriority 1) and would otherwise
                    // starve these controls, wrapping/clipping their labels.
                    .fixedSize()
                }
            } header: {
                Text("Setup")
            } footer: {
                Text("\"Forget on this Mac\" only removes the local copy — revoke the key itself at steamcommunity.com/dev/apikey.")
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
                Text("Content")
            }

            Section {
                SettingRow(
                    icon: "shippingbox",
                    iconColor: .brown,
                    title: "Wallpaper Engine assets",
                    subtitle: "Optional — link a WPE install for extra scene coverage",
                    info: "Loomscreen bundles clean-room equivalents of the common Wallpaper Engine framework files, so most scenes render without a Wallpaper Engine install. Link one only for scenes that reference uncommon shared assets — read-only access, no files are modified."
                ) {
                    engineAssetsControl
                }
                if let error = engineAssets.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Colors.Status.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Scene rendering")
            }
        }
        // Shared settings chrome hides the Form's default system background
        // (.scrollContentBackground) + insets (.contentMargins) so this tab
        // doesn't show a different-colored inset panel than other tabs.
        .settingsFormChrome()
        .sheet(isPresented: $showingDoctor) {
            WorkshopDoctorView()
                .environment(doctorService)
        }
        .sheet(isPresented: $showingKeyEntry) {
            SteamWebAPIKeyEntrySheet(services: workshopServices) {
                Task { await workshopServices.refreshAPIKeyStatus() }
            }
        }
        .sheet(isPresented: $showingBrowse) {
            WorkshopBrowseView(services: workshopServices, doctor: doctorService) {
                showingBrowse = false
                showingKeyEntry = true
            }
        }
        .task { await workshopServices.refreshAPIKeyStatus() }
    }

    @ViewBuilder
    private var engineAssetsControl: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            if engineAssets.isAuthorized {
                Label(engineAssets.engineRootDisplayName ?? String(localized: "Linked", comment: "Engine-assets status when authorized but no display name."), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(DesignTokens.Colors.Status.active)
                    .font(DesignTokens.Typography.bodyEmphasized)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Change") { Task { _ = await engineAssets.requestAccess() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .help(Text("Pick a different Wallpaper Engine install folder"))
                Button("Forget", role: .destructive) { engineAssets.clearAccess() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .help(Text("Remove access to the Wallpaper Engine install folder"))
            } else {
                Button("Link folder…") { Task { _ = await engineAssets.requestAccess() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .help(Text("Grant read-only access to a Wallpaper Engine install for extra scene coverage"))
            }
        }
    }

    /// At-a-glance "what works right now" row. Preview is always available;
    /// Browse needs the user's API key; Download needs SteamCMD probed green.
    private var capabilityChips: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            capabilityChip("Preview", ready: true, needs: "")
            capabilityChip("Browse", ready: workshopServices.hasWebAPIKey, needs: "needs key")
            capabilityChip("Download", ready: downloadReady, needs: "needs SteamCMD")
            Spacer(minLength: 0)
        }
    }

    private var downloadReady: Bool {
        if case .done(let allGreen, _) = doctorService.state { return allGreen }
        return false
    }

    private func capabilityChip(_ title: LocalizedStringKey, ready: Bool, needs: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ready ? DesignTokens.Colors.Status.active : DesignTokens.Colors.Status.warning)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(DesignTokens.Typography.bodyEmphasized)
                if !ready {
                    Text(needs).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.secondary.opacity(0.08)))
        .overlay(Capsule().stroke(Color.secondary.opacity(0.15), lineWidth: 0.5))
    }

    @ViewBuilder
    private var doctorIndicator: some View {
        switch doctorService.state {
        case .idle:
            indicatorDot(.gray, label: "Not yet run")
        case .probing:
            ProgressView().controlSize(.small)
        case .done(let allGreen, let blockingFailures):
            if allGreen {
                indicatorDot(DesignTokens.Colors.Status.active, label: "All probes green")
            } else if blockingFailures == 0 {
                indicatorDot(DesignTokens.Colors.Status.warning, label: "Warnings")
            } else {
                indicatorDot(DesignTokens.Colors.Status.danger, label: "\(blockingFailures) blocker\(blockingFailures == 1 ? "" : "s")")
            }
        }
    }

    @ViewBuilder
    private var keyStatusBadge: some View {
        if workshopServices.hasWebAPIKey {
            Label("Set", systemImage: "checkmark.seal.fill")
                .foregroundStyle(DesignTokens.Colors.Status.active)
                .font(DesignTokens.Typography.bodyEmphasized)
        } else {
            Label("Not set", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignTokens.Colors.Status.warning)
                .font(DesignTokens.Typography.bodyEmphasized)
        }
    }

    private func indicatorDot(_ color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

}
#endif
