#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

struct WorkshopSettingsView: View {
    @Environment(SteamCMDDoctorService.self) private var doctorService
    @Environment(WorkshopServices.self) private var workshopServices

    @AppStorage("loomscreen.workshop.onboarding.shown.v1") private var onboardingShown: Bool = false
    @AppStorage("loomscreen.workshop.blurMatureThumbnails.v1") private var blurMatureThumbnails = true
    @AppStorage("loomscreen.workshop.hidesDownloaded.v1") private var hidesDownloadedInBrowse = false

    @State private var engineAssets = WPEEngineAssetsLibrary.shared
    @State private var showingDoctor = false
    @State private var showingKeyEntry = false
    @State private var showingCacheManagement = false
    @State private var showingBrowse = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Label("Ready", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(DesignTokens.Colors.Status.active)
                        .font(DesignTokens.Typography.bodyEmphasized)
                }
            } header: {
                Text("Steam Workshop")
            } footer: {
                Text("Paste-and-preview works out of the box. Online browsing needs your own free Steam Web API key. Downloading needs the official SteamCMD + your Steam account — open the Doctor below to wire that up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Privacy") {
                Label("Loomscreen never reads or stores your Steam password, Steam Guard codes, or session tokens.", systemImage: "lock.shield")
                    .labelStyle(.titleAndIcon)
                    .font(DesignTokens.Typography.body)
                Label("Workshop metadata is fetched directly from Valve over HTTPS. We never proxy through a Loomscreen server.", systemImage: "network")
                    .labelStyle(.titleAndIcon)
                    .font(DesignTokens.Typography.body)
                Label("Workshop wallpapers run inside an isolated, ephemeral WKWebView with a strict Content-Security-Policy.", systemImage: "shield.lefthalf.filled")
                    .labelStyle(.titleAndIcon)
                    .font(DesignTokens.Typography.body)
            }

            Section("Onboarding") {
                SettingRow(
                    icon: "hand.wave",
                    iconColor: .blue,
                    title: "Show the welcome sheet next time",
                    subtitle: "Reopen the Workshop intro the next time you open it"
                ) {
                    Toggle("", isOn: Binding(
                        get: { !onboardingShown },
                        set: { onboardingShown = !$0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text("Show the welcome sheet next time"))
                }
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
            } footer: {
                Text("Application wallpapers are always hidden because they can't run here. The Installed tab is where you revisit your full library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
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
                Text("Downloads")
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
            } header: {
                Text("Browse Online")
            } footer: {
                Text("\"Forget on this Mac\" only removes the local copy — revoke the key itself at steamcommunity.com/dev/apikey.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                SettingRow(
                    icon: "internaldrive",
                    iconColor: .gray,
                    title: "Workshop browse cache",
                    subtitle: "Cached browse results (5-min refresh, 100 MB cap)",
                    info: "Holds the JSON responses behind Browse Online so paging stays fast. Scene assets are read in place from their source — they're no longer copied into a cache."
                ) {
                    Button("Manage") { showingCacheManagement = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                        .help(Text("Inspect and clear the Workshop browse cache"))
                }
            } header: {
                Text("Cache")
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
        .sheet(isPresented: $showingCacheManagement) {
            cacheSheet
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

    private var cacheSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Workshop cache")
                    .font(.headline)
                Spacer()
                Button("Done") { showingCacheManagement = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
            .padding(.vertical, DesignTokens.Settings.formVerticalMargin)
            .background(.bar)
            WorkshopCacheManagementView(cache: workshopServices.queryCache)
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 360, idealHeight: 420)
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
