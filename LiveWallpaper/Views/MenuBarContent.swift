import SwiftUI
import AppKit

/// Top-level container for the menu-bar control center. Delegates each region
/// (header, hero, effects, bookmarks, other displays, automation, footer) to
/// dedicated child views under `Views/MenuBar/`. Persists the user's choice
/// of selected screen, popover mode, and section visibility via @AppStorage
/// so the surface restores its state across launches.
struct MenuBarContent: View {
    let openSettings: () -> Void
    let openSettingsForScreen: (CGDirectDisplayID) -> Void
    let promptAddWallpaper: (String) -> Void

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(MenuBarPreferenceKey.selectedScreenID) private var selectedScreenIDRaw: String = ""
    @AppStorage(MenuBarPreferenceKey.popoverMode) private var popoverModeRaw: String = MenuBarPopoverMode.standard.rawValue
    @AppStorage(MenuBarPreferenceKey.diagnosticsVisible) private var diagnosticsVisible: Bool = false
    @AppStorage(MenuBarPreferenceKey.effectsVisible) private var effectsVisible: Bool = true
    @AppStorage(MenuBarPreferenceKey.bookmarksVisible) private var bookmarksVisible: Bool = true
    @AppStorage(MenuBarPreferenceKey.automationVisible) private var automationVisible: Bool = true
    @AppStorage(MenuBarPreferenceKey.otherDisplaysVisible) private var otherDisplaysVisible: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            header

            if let screen = selectedScreen {
                MenuBarScreenTabs(
                    screens: screenManager.screens,
                    selectedScreenIDRaw: $selectedScreenIDRaw
                )

                MenuBarHeroSection(
                    screen: screen,
                    openSettingsForScreen: invokeOpenSettingsForScreen
                )

                if mode != .compact {
                    if effectsVisible {
                        MenuBarEffectsSection(screen: screen)
                    }
                    if bookmarksVisible {
                        MenuBarBookmarksShelf(screen: screen)
                    }
                    if otherDisplaysVisible && screenManager.screens.count >= 3 {
                        MenuBarOtherDisplaysList(
                            screens: screenManager.screens,
                            selectedScreenID: screen.id,
                            openSettingsForScreen: invokeOpenSettingsForScreen
                        )
                    }
                    if automationVisible {
                        MenuBarAutomationDrawer()
                    }
                }

                if diagnosticsVisible {
                    MenuBarDiagnosticsPopover()
                        .padding(.top, 2)
                }
            } else {
                Text("No displays detected")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            MenuBarFooter(
                openSettings: invokeOpenSettings,
                onReload: { screenManager.reloadAllScreens() },
                diagnosticsVisible: $diagnosticsVisible,
                effectsVisible: $effectsVisible,
                bookmarksVisible: $bookmarksVisible,
                automationVisible: $automationVisible,
                otherDisplaysVisible: $otherDisplaysVisible,
                popoverModeRaw: $popoverModeRaw
            )
        }
        .padding(DesignTokens.Spacing.md)
        .frame(width: mode.width)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignTokens.Corner.xl))
        .animation(DesignTokens.motion(reduceMotion, .smooth(duration: 0.40)), value: mode)
        .animation(
            DesignTokens.motion(reduceMotion, .snappy(duration: 0.20)),
            value: selectedScreenIDRaw
        )
        .onAppear { ensureValidSelection() }
        .onChange(of: screenManager.screens.map(\.id)) { _, _ in ensureValidSelection() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.rectangle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .font(.system(size: 16))
                .accessibilityHidden(true)

            Text("LiveWallpaper")
                .font(.system(size: 13, weight: .semibold))
                .help(versionString)

            Spacer()

            Button(action: togglePauseAll) {
                Image(systemName: isAnyPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 24, height: 24)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(isAnyPlaying
                ? Text("Pause all", comment: "Tooltip when at least one wallpaper is playing.")
                : Text("Resume all", comment: "Tooltip when all wallpapers are paused."))
            .accessibilityLabel(isAnyPlaying
                ? Text("Pause all displays", comment: "A11y label to pause all displays.")
                : Text("Resume all displays", comment: "A11y label to resume all displays."))
        }
    }

    // MARK: - Derived state

    private var mode: MenuBarPopoverMode {
        MenuBarPopoverMode(rawValue: popoverModeRaw) ?? .standard
    }

    private var selectedScreen: Screen? {
        if let target = screenManager.screens.first(where: { String($0.id) == selectedScreenIDRaw }) {
            return target
        }
        return screenManager.screens.first
    }

    private var isAnyPlaying: Bool {
        screenManager.screens.contains { $0.playbackController?.isPlaying ?? false }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        return "Version \(version)"
    }

    // MARK: - Actions

    private func togglePauseAll() {
        screenManager.togglePlayback()
    }

    private func invokeOpenSettings() {
        dismiss()
        openSettings()
    }

    private func invokeOpenSettingsForScreen(_ id: CGDirectDisplayID) {
        dismiss()
        openSettingsForScreen(id)
    }

    private func ensureValidSelection() {
        let ids = screenManager.screens.map { String($0.id) }
        guard !ids.isEmpty else { return }
        if !ids.contains(selectedScreenIDRaw) {
            selectedScreenIDRaw = ids.first ?? ""
        }
    }
}

@MainActor
enum PlaybackToggle {
    static func toggle(_ playback: any WallpaperPlaybackControllable) {
        if playback.isPlaying {
            playback.pause()
        } else {
            playback.play()
        }
    }
}
