#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

/// "Steam Workshop" Settings tab — sibling of "General", "Shortcuts",
/// "Cache", "Backup", "About". Privacy disclosures + entry points to the
/// v2 Doctor and the v3 Web-API-key + browse-cache flows.
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
                        .foregroundStyle(Color.green)
                        .font(.system(size: 12, weight: .semibold))
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
                    .font(.system(size: 12))
                Label("Workshop metadata is fetched directly from Valve over HTTPS. We never proxy through a Loomscreen server.", systemImage: "network")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12))
                Label("Workshop wallpapers run inside an isolated, ephemeral WKWebView with a strict Content-Security-Policy.", systemImage: "shield.lefthalf.filled")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12))
            }

            Section("Onboarding") {
                Toggle("Show the welcome sheet next time", isOn: Binding(
                    get: { !onboardingShown },
                    set: { onboardingShown = !$0 }
                ))
                .toggleStyle(.switch)
            }

            Section {
                Toggle("Blur mature thumbnails until clicked", isOn: $blurMatureThumbnails)
                    .toggleStyle(.switch)
                Toggle("Hide items already in my library when browsing", isOn: $hidesDownloadedInBrowse)
                    .toggleStyle(.switch)
            } header: {
                Text("Content")
            } footer: {
                Text("Wallpapers tagged Mature show a blurred cover in the browse grid and details until you click to reveal them. Application wallpapers are always hidden because they can't run here. Hiding already-downloaded items keeps Browse Online focused on things you don't have yet — the Installed tab is where you revisit your library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        doctorIndicator
                        Button("Open") { showingDoctor = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Open the SteamCMD diagnostics sheet")
                    }
                } label: {
                    Label("SteamCMD Doctor", systemImage: "stethoscope")
                }
            } header: {
                Text("Downloads")
            } footer: {
                Text("Verify your SteamCMD install + Steam sign-in before enabling Workshop downloads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent {
                    keyStatusBadge
                } label: {
                    Label("Steam Web API key", systemImage: "key")
                }

                HStack(spacing: DesignTokens.Spacing.xs) {
                    Spacer()
                    if workshopServices.hasWebAPIKey {
                        Button("Replace") { showingKeyEntry = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Set a new Steam Web API key")
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
                            .help("Open the Workshop browse sheet")
                    } else {
                        Button("Set key") { showingKeyEntry = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .help("Paste your Steam Web API key")
                    }
                }
            } header: {
                Text("Browse Online")
            } footer: {
                Text("The key belongs to your own Steam account, not Loomscreen. Calls go directly to Valve over HTTPS; the key is stored in this Mac's Keychain (no iCloud sync). \"Forget on this Mac\" only removes the local copy — revoke the key itself at steamcommunity.com/dev/apikey.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent {
                    Button("Manage") { showingCacheManagement = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Inspect and clear the Workshop browse cache")
                } label: {
                    Label("Workshop browse cache", systemImage: "internaldrive")
                }
            } header: {
                Text("Cache")
            } footer: {
                Text("The browse cache holds QueryFiles JSON responses (5-minute TTL, 100 MB hard cap). Scene assets are read in place from their source — they're no longer copied into a cache.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent {
                    engineAssetsControl
                } label: {
                    Label("Wallpaper Engine assets", systemImage: "shippingbox")
                }
                if let error = engineAssets.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Scene rendering")
            } footer: {
                Text("Optional. Loomscreen bundles clean-room equivalents of the common Wallpaper Engine framework files, so most scenes render without a Wallpaper Engine install. Link one only for extra coverage of scenes that reference uncommon shared assets — read-only access, no files are modified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
        .padding(.vertical, DesignTokens.Settings.formVerticalMargin)
        .background(DesignTokens.Colors.pageBackground)
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
                    .foregroundStyle(Color.green)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Change") { Task { _ = await engineAssets.requestAccess() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Pick a different Wallpaper Engine install folder")
                Button("Forget", role: .destructive) { engineAssets.clearAccess() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Remove access to the Wallpaper Engine install folder")
            } else {
                Button("Link folder…") { Task { _ = await engineAssets.requestAccess() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Grant read-only access to a Wallpaper Engine install for extra scene coverage")
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
                indicatorDot(.green, label: "All probes green")
            } else if blockingFailures == 0 {
                indicatorDot(.orange, label: "Warnings")
            } else {
                indicatorDot(.red, label: "\(blockingFailures) blocker\(blockingFailures == 1 ? "" : "s")")
            }
        }
    }

    @ViewBuilder
    private var keyStatusBadge: some View {
        if workshopServices.hasWebAPIKey {
            Label("Set", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Color.green)
                .font(.system(size: 12, weight: .semibold))
        } else {
            Label("Not set", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
                .font(.system(size: 12, weight: .semibold))
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
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

}
#endif
