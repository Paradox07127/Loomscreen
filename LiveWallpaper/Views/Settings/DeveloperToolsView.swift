#if DEBUG && !LITE_BUILD
import SwiftUI
import AppKit

/// Pro-only diagnostic surface compiled into local DEBUG builds only — it
/// ships in no Release binary at all, so it can never reach end users (and the
/// scene-debug artifact writer it drives is hard-disabled in Release too).
/// Within a DEBUG build it is still gated at runtime by the Developer Mode
/// toggle in Settings → General → Advanced.
struct DeveloperToolsView: View {
    @State private var flagRefresh = 0
    @State private var captureIDs: [String] = UserDefaults.standard.stringArray(forKey: "WPEMetalCaptureScene") ?? []
    @State private var newCaptureID: String = ""

    var body: some View {
        DetailPageScaffold(
            showsHeader: true,
            header: { header },
            content: { content }
        )
    }

    private var header: some View {
        DetailHeaderBar(
            systemImage: "wrench.and.screwdriver",
            title: { Text("Developer Tools") },
            metadata: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diagnostic flags — persist until toggled off or reset.", comment: "Developer Tools header subtitle on the diagnostics tab.")
                    Text("Visible while Developer Mode is on. Disable it in Settings → General → Advanced.", comment: "Developer Tools header subtitle explaining the runtime gate.")
                }
                .foregroundStyle(.secondary)
            },
            actions: { EmptyView() }
        )
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            diagnosticsFlagsSection
        }
        .padding(16)
    }

    // MARK: - Diagnostic flags

    private struct DiagnosticBoolFlag: Identifiable {
        let key: String
        let title: String
        let help: String
        var id: String { key }
    }

    private static let diagnosticBoolFlags: [DiagnosticBoolFlag] = [
        .init(key: "WPESceneDebugArtifactsEnabled", title: "Scene debug artifacts",
              help: "Write per-scene logs, first-frame snapshot, and texture metadata to scene-debug."),
        .init(key: "WPEMetalLoadTiming", title: "Load timing",
              help: "Log a per-phase scene-load time breakdown ([load-timing] …) at first frame, for measuring + comparing load cost."),
        .init(key: "WPECustomSettingsLoadTiming", title: "Custom settings timing",
              help: "Log WPE project custom-settings schema load timing ([custom-settings-timing] …), including bookmark resolve, cache probe, and project.json read/parse."),
        .init(key: "WPEParticlePrewarmEnabled", title: "Particle prewarm",
              help: "Pre-populate emitters to their steady-state spread on load (the WPE-matching populated look). Off (default): emitters start empty and fill naturally — cuts the dominant particles.load cost. Reload the scene to apply."),
        .init(key: "WPEAudioCaptureProbe", title: "Audio capture probe",
              help: "Probe the Core Audio process tap under the sandbox (audio-reactive bring-up)."),
        .init(key: "WPEAudioDebugLog", title: "Audio debug log",
              help: "Verbose audio-reactive DSP logging."),
        .init(key: "WPEPuppetLogSkinningReason", title: "Log puppet skinning gate",
              help: "Log why each puppet's GPU skinning is enabled or gated off (blink/body-sway depend on it). Filter logs for 🦴 [puppet-skin]. Logged once per change."),
        .init(key: "WPEMetalBypassEffects", title: "Bypass effect passes",
              help: "Draw only base image layers, skipping effects (note: breaks solid-color layers)."),
        .init(key: "WPEPuppetDeferMeshWarp", title: "Defer puppet mesh warp (override)",
              help: "Override the automatic per-puppet decision (default: defer only puppets that have an effect chain, so their effect masks align). ON forces every non-clip puppet to defer; OFF forces direct warp. Clip-eye puppets ignore this. Reload the scene to apply."),
    ]

    private static let diagnosticStringKeys: [String] = [
        WPEWaterWavesDebugMode.defaultsKey,
        "WPEDumpScenePasses",
        "WPEDumpScenePassesAtTime",
        "WPEMetalCaptureScene",
    ]

    private var diagnosticsFlagsSection: some View {
        GroupBox(label:
            HStack {
                Text("WPE diagnostics").font(.headline)
                Spacer()
                Button {
                    revealDebugArtifacts()
                } label: {
                    Label("Reveal artifacts in Finder", systemImage: "folder")
                }
                Button {
                    resetDiagnosticFlags()
                } label: {
                    Label("Reset all", systemImage: "arrow.counterclockwise")
                }
                .help(Text("Turn every diagnostic flag off so none leak into normal playback or other sessions."))
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Self.diagnosticBoolFlags) { flag in
                    Toggle(isOn: boolBinding(flag.key)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: flag.title)
                            Text(verbatim: flag.help)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()
                gpuCaptureList

                Text(verbatim: "Flags persist in UserDefaults until toggled off. \"Reset all\" clears every flag here (including scene-dump targets) so a forgotten toggle never affects normal playback.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .id(flagRefresh)
        }
    }

    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: key) },
            set: { newValue in
                UserDefaults.standard.set(newValue, forKey: key)
                flagRefresh += 1
            }
        )
    }

    private func resetDiagnosticFlags() {
        for flag in Self.diagnosticBoolFlags {
            UserDefaults.standard.removeObject(forKey: flag.key)
        }
        for key in Self.diagnosticStringKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.removeObject(forKey: WPEWaterWavesTrace.defaultsKey)
        captureIDs = []
        flagRefresh += 1
    }

    private func revealDebugArtifacts() {
        guard let root = WPESceneDebugArtifacts.rootURL else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    // MARK: - GPU capture

    private func addCaptureID() {
        let id = newCaptureID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !captureIDs.contains(id) else { return }
        captureIDs.append(id)
        UserDefaults.standard.set(captureIDs, forKey: "WPEMetalCaptureScene")
        newCaptureID = ""
    }

    private func removeCaptureID(_ id: String) {
        captureIDs.removeAll { $0 == id }
        if captureIDs.isEmpty {
            UserDefaults.standard.removeObject(forKey: "WPEMetalCaptureScene")
        } else {
            UserDefaults.standard.set(captureIDs, forKey: "WPEMetalCaptureScene")
        }
    }

    private var gpuCaptureList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "GPU capture scene IDs")
                .font(.callout.weight(.medium))
            Text(verbatim: "Scenes whose workshopID is listed get a Metal .gputrace (→ /tmp) plus output/texture PNG dumps (→ App Support/LiveWallpaper/gpu-traces/) on next load. Reload the wallpaper after editing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if captureIDs.isEmpty {
                Text(verbatim: "No scenes selected.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(captureIDs, id: \.self) { id in
                    HStack(spacing: 8) {
                        Text(verbatim: id).monospaced()
                        Spacer()
                        Button(role: .destructive) {
                            removeCaptureID(id)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help(Text(verbatim: "Stop capturing this scene"))
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Workshop ID", text: $newCaptureID)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .frame(maxWidth: 200)
                    .onSubmit { addCaptureID() }
                Button {
                    addCaptureID()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(newCaptureID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
#endif
