import LiveWallpaperSharedUI
import SwiftUI

extension GeneralSettingsView {
    /// Flipping it drives `SystemAudioCaptureManager` directly so the tap
    /// starts/stops live, in addition to persisting for next launch.
    @ViewBuilder
    var audioResponseSection: some View {
        #if !LITE_BUILD
        Section {
            SettingRow(
                icon: "waveform",
                iconColor: audioResponseEnabled ? audioStatusColor : .pink,
                title: "Audio Response",
                subtitle: "Let audio-reactive wallpapers move with the music and sound playing on your Mac.",
                info: "Analyzes your Mac's audio output on-device to compute a frequency spectrum for audio-reactive scenes. Nothing is recorded, saved, or sent anywhere. macOS asks for permission the first time you turn this on."
            ) {
                HStack(spacing: 8) {
                    if audioResponseEnabled {
                        GeneralSettingsStatusPill(text: audioStatusText, color: audioStatusColor)
                            .help(Text(verbatim: audioStatusSubtitle))
                    }

                    if audioShowsRegrant {
                        Button("Re-grant Access") {
                            regrantAudioAccess()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                        .accessibilityLabel(Text("Re-grant audio access"))
                    }

                    Toggle("", isOn: $audioResponseEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: audioResponseEnabled) { _, newValue in
                            updateGlobalSettings()
                            applyAudioResponseEnabled(newValue)
                        }
                        .accessibilityLabel(Text("Audio Response"))
                        .accessibilityHint(Text("Lets wallpapers react to the audio playing on your Mac. Off by default; requires audio-recording permission."))
                }
            }
        } header: {
            Text("Audio", comment: "Section header for the audio-response toggle in General settings.")
        }
        #endif
    }

    #if !LITE_BUILD
    /// Single reconcile point for the live capture tap. The Toggle's onChange
    /// and the config-bundle import both route through here — the import path
    /// runs on the Backup & Restore page where the Toggle (and its onChange)
    /// is not in the view tree, so persisting alone would leave the tap stale.
    func applyAudioResponseEnabled(_ enabled: Bool) {
        SystemAudioCaptureManager.shared.setEnabled(enabled)
        audioCaptureState = SystemAudioCaptureManager.shared.state
        if enabled {
            scheduleSystemStatusRefresh(.audioCapture)
        } else {
            audioStatusRefreshPending = false
        }
    }

    private var audioStatusText: String {
        guard audioResponseEnabled else { return "Off" }
        if audioStatusRefreshPending {
            return "Checking…"
        }
        switch audioCaptureState {
        case .capturing:
            return "Granted"
        case .failed:
            return "Needs Access"
        case .unsupported:
            return "Unsupported"
        case .idle:
            return "Not Granted"
        }
    }

    private var audioStatusSubtitle: String {
        guard audioResponseEnabled else { return "Audio response is off" }
        if audioStatusRefreshPending {
            return "Waiting for macOS to update audio permission"
        }
        switch audioCaptureState {
        case .capturing:
            return "System audio capture is running"
        case .failed(let reason):
            return PIISanitizer.scrub(reason)
        case .unsupported:
            return "Requires macOS 14.2 or later"
        case .idle:
            return "Turn on access to start system audio capture"
        }
    }

    private var audioStatusColor: Color {
        guard audioResponseEnabled else { return .secondary }
        if audioStatusRefreshPending {
            return .secondary
        }
        switch audioCaptureState {
        case .capturing:
            return DesignTokens.Colors.Status.active
        case .failed:
            return DesignTokens.Colors.Status.danger
        case .unsupported:
            return DesignTokens.Colors.Status.warning
        case .idle:
            return DesignTokens.Colors.Status.warning
        }
    }

    private var audioShowsRegrant: Bool {
        guard audioResponseEnabled, !audioStatusRefreshPending else { return false }
        switch audioCaptureState {
        case .capturing, .unsupported:
            return false
        case .failed, .idle:
            return true
        }
    }

    private func regrantAudioAccess() {
        audioResponseEnabled = true
        updateGlobalSettings()
        SystemAudioCaptureManager.shared.retryAccessRequest()
        audioCaptureState = SystemAudioCaptureManager.shared.state
        scheduleSystemStatusRefresh(.audioCapture)
    }
    #endif
}
