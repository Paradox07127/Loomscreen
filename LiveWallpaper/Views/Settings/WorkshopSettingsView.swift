#if !LITE_BUILD && DIRECT_DISTRIBUTION
import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

/// "Steam Workshop" Settings tab — sibling of "General", "Shortcuts",
/// "Cache", "Backup", "About". v1 surfaces the privacy explainer and a
/// reset toggle for the onboarding sheet. Doctor + Web API key sections are
/// placeholders so future Phase 2 / Phase 5 slices have a target site
/// (`docs/2026-05-28-steam-workshop-integration-plan.md` "UI surfaces
/// inventory" rows #7, #11).
struct WorkshopSettingsView: View {
    @AppStorage("loomscreen.workshop.onboarding.shown.v1") private var onboardingShown: Bool = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Label("Ready", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Color.green)
                        .font(.system(size: 12, weight: .semibold))
                }
                LabeledContent("Build") {
                    Text("Pro · Direct distribution")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Steam Workshop")
            } footer: {
                Text("Paste-and-preview works out of the box. Downloading needs your own Steam account + the official SteamCMD — that setup ships in a later release.")
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
                Label("SteamCMD Doctor", systemImage: "stethoscope")
                    .foregroundStyle(.secondary)
                Text("Coming with the download release.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("Downloads")
            }

            Section {
                Label("Steam Web API key", systemImage: "key")
                    .foregroundStyle(.secondary)
                Text("Coming with the browse-online release.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("Browse Online")
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
        .padding(.vertical, DesignTokens.Settings.formVerticalMargin)
        .background(DesignTokens.Colors.pageBackground)
    }
}
#endif
