import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

extension GeneralSettingsView {
    /// Per-screen RAM budget for the in-memory video cache. Slider (not a
    /// 3-mode picker) so each user picks their own RAM-vs-disk-reads trade-off.
    /// 0 = streaming only; the "total" line makes the multi-screen multiplier explicit.
    @ViewBuilder
    var performanceSection: some View {
        Section {
            SettingRow(icon: "macwindow.badge.plus", iconColor: .purple, title: "Pause on full-screen apps", subtitle: "Automatically pause wallpapers when a full-screen app is active") {
                Toggle("", isOn: $pauseOnFullScreen)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: pauseOnFullScreen) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Pause on full-screen apps"))
                    .accessibilityHint(Text("Automatically pause wallpapers when a full-screen app is active"))
            }

            SettingRow(
                icon: "rectangle.on.rectangle",
                iconColor: .purple,
                title: "Pause when windows cover the desktop",
                subtitle: "Pause when app windows cover most of the screen, even without full-screen",
                info: "When open windows cover about 85 percent or more of a display, the wallpaper pauses to free CPU and GPU. It resumes as soon as you reveal the desktop."
            ) {
                Toggle("", isOn: $pauseOnWindowOcclusion)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: pauseOnWindowOcclusion) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Pause when windows cover the desktop"))
                    .accessibilityHint(Text("Pause when other apps' windows cover at least 85 percent of a display"))
            }

            #if !LITE_BUILD
            SettingRow(
                icon: "gauge.with.dots.needle.33percent",
                iconColor: .teal,
                title: "Reduce frame rate when covered",
                subtitle: "Lower the frame rate when windows cover the desktop or on battery, to save power",
                info: "When windows cover about half the screen, or your Mac is unplugged and wallpapers keep playing, the frame rate drops to about half to save GPU power. Full speed returns once the desktop is visible again. Affects scene (Wallpaper Engine) wallpapers."
            ) {
                Toggle("", isOn: $adaptiveFrameRateEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: adaptiveFrameRateEnabled) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Reduce frame rate when covered"))
                    .accessibilityHint(Text("Lower the frame rate when windows cover the desktop or on battery, to save power"))
            }
            #endif

            SettingRow(icon: "gamecontroller", iconColor: .green, title: "Pause when a game is active", subtitle: "Yield the GPU when the frontmost app is a game, or macOS enters Low Power Mode") {
                Toggle("", isOn: $pauseInGameMode)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: pauseInGameMode) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Pause when a game is active"))
                    .accessibilityHint(Text("Yield the GPU when the frontmost app is a game, or macOS enters Low Power Mode"))
            }

            SettingRow(icon: "bolt.circle.fill", iconColor: .yellow, title: "Pause on battery", subtitle: "Switch wallpapers to a static frame when your Mac is unplugged") {
                Toggle("", isOn: $globalPauseOnBattery)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: globalPauseOnBattery) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Pause on battery"))
                    .accessibilityHint(Text("Switch wallpapers to a static frame when your Mac is unplugged"))
            }

            SettingRow(
                icon: "hand.raised",
                iconColor: .blue,
                title: "App Exceptions",
                subtitle: applicationRules.isEmpty
                    ? "Pause wallpapers while chosen apps are in use"
                    : "Active for \(applicationRules.count) app\(applicationRules.count == 1 ? "" : "s")"
            ) {
                Button("Edit…") { showAppExceptions = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    // Without fixedSize the SettingRow's flexible title column
                    // (maxWidth: .infinity, layoutPriority 1) starves the button and clips its label to an empty border.
                    .fixedSize()
                    .accessibilityLabel(Text("Edit application exceptions"))
            }

            SettingRow(
                icon: "memorychip",
                iconColor: .pink,
                title: "Video preload (RAM)",
                subtitle: "Preload video loops into memory to reduce disk reads",
                info: "Caching keeps each looping video in RAM so it doesn't re-read your disk every cycle — saving SSD wear and power. Drag to Off to stream straight from disk and use the least memory. The value below is the budget per screen (and the total across all displays)."
            ) {
                VStack(alignment: .trailing, spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { videoCacheBudgetMB },
                            set: { newValue in
                                let snapped = (newValue / 32).rounded() * 32
                                videoCacheBudgetMB = snapped
                                updateGlobalSettings()
                            }
                        ),
                        in: 0...Double(GlobalSettings.maxVideoCacheBytes / (1024 * 1024)),
                        step: 32
                    ) {
                        Text("Video preload (RAM)")
                    } minimumValueLabel: {
                        Text("Off")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text("1 GB")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 240)
                    .accessibilityLabel(Text("Video preload (RAM)"))
                    .accessibilityValue(Text(videoCacheValueLabel))

                    Text(videoCacheValueLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Performance & Battery")
        }
    }

    /// `150 MB · 300 MB total` (per-screen · total). Off collapses to
    /// "Streaming only" to avoid a misleading "0 MB total".
    private var videoCacheValueLabel: String {
        guard videoCacheBudgetMB > 0 else { return "Streaming only" }

        let perScreenMB = Int(videoCacheBudgetMB)
        let screenCount = max(screenManager.screens.count, 1)
        if screenCount == 1 {
            return "\(perScreenMB) MB"
        }
        let totalMB = perScreenMB * screenCount
        return "\(perScreenMB) MB · \(totalMB) MB total"
    }
}
