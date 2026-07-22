#if DEBUG && !LITE_BUILD
import SwiftUI
import AppKit
import LiveWallpaperCore

/// Pro diagnostic surface available only in local debug builds.
struct DeveloperToolsView: View {
    @State private var flagRefresh = 0
    @State private var captureIDs: [String] = UserDefaults.standard.stringArray(forKey: DeveloperToolsView.captureSceneKey) ?? []
    @State private var newCaptureID: String = ""
    @State private var sceneScriptXPCDiagnosticsEnabled = WPESceneScriptXPCDiagnostics.isEnabled
    @State private var freezeTimeText: String = {
        if let value = UserDefaults.standard.object(forKey: DeveloperToolsView.oracleFreezeTimeKey) as? Double {
            return String(value)
        }
        return ""
    }()

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
                    Text("Visible while Developer Mode is on. Disable it in Settings → Advanced.", comment: "Developer Tools header subtitle explaining the runtime gate.")
                }
                .foregroundStyle(.secondary)
            },
            actions: { EmptyView() }
        )
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            diagnosticsFlagsSection
            oracleSection
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
        .init(key: "WPEParticlePrewarmEnabled", title: "Particle prewarm",
              help: "Also pre-populate emitters with starttime 0 to their steady-state spread on load. Authored starttime offsets always prewarm for WPE-matching first frames. Reload the scene to apply."),
        .init(key: "WPEAudioDebugLog", title: "Audio debug log",
              help: "Verbose audio-reactive DSP logging."),
        .init(key: "WPEPuppetDeferMeshWarp", title: "Defer puppet mesh warp (override)",
              help: "Override the automatic per-puppet decision (default: defer only puppets that have an effect chain, so their effect masks align). ON forces every non-clip puppet to defer; OFF forces direct warp. Clip-eye puppets ignore this. Reload the scene to apply."),
    ]

    static let oracleEnabledKey = "WPEOracleEnabled"
    static let oracleFreezeTimeKey = "WPEOracleFreezeTime"
    static let captureSceneKey = "WPEMetalCaptureScene"

    private static let diagnosticStringKeys: [String] = [
        "WPEDumpScenePasses",
        "WPEDumpScenePassesAtTime",
        captureSceneKey,
    ]

    /// Every UserDefaults key any control in this view writes.
    static let allDiagnosticDefaultsKeys: [String] =
        diagnosticBoolFlags.map(\.key)
            + diagnosticStringKeys
            + [oracleEnabledKey, oracleFreezeTimeKey]

    static func clearAllDiagnosticDefaults(in defaults: UserDefaults = .standard) {
        for key in allDiagnosticDefaultsKeys {
            defaults.removeObject(forKey: key)
        }
        WPESceneScriptXPCDiagnostics.setEnabled(false)
        WPESceneScriptXPCDiagnostics.reset()
    }

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
                sceneScriptXPCDiagnosticsControl

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
        Self.clearAllDiagnosticDefaults()
        sceneScriptXPCDiagnosticsEnabled = false
        captureIDs = []
        freezeTimeText = ""
        flagRefresh += 1
    }

    private var sceneScriptXPCDiagnosticsControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { sceneScriptXPCDiagnosticsEnabled },
                set: { enabled in
                    sceneScriptXPCDiagnosticsEnabled = enabled
                    WPESceneScriptXPCDiagnostics.setEnabled(enabled)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SceneScript XPC measurements", comment: "Developer Tools toggle title enabling in-memory SceneScript XPC diagnostics.")
                    Text("Keep the most recent helper attempts in memory while diagnosing timing or recovery. Nothing is written automatically; Copy JSON puts a redacted snapshot on the clipboard.", comment: "Developer Tools helper text explaining the opt-in, memory-only SceneScript XPC diagnostic recorder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button {
                    WPESceneScriptXPCDiagnostics.reset()
                    flagRefresh += 1
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                Button {
                    copySceneScriptXPCDiagnostics()
                } label: {
                    Label("Copy XPC JSON", systemImage: "doc.on.clipboard")
                }
            }
        }
    }

    private func copySceneScriptXPCDiagnostics() {
        guard let data = try? WPESceneScriptXPCDiagnostics.encodedSnapshot(),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func revealDebugArtifacts() {
        guard let root = WPESceneDebugArtifacts.rootURL else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    // MARK: - Oracle

    /// Flag-and-reveal convenience for the WPE render oracle (`WPEOracleMode`): a master toggle + the frozen scene-time it uses, both plain UserDefaults the oracle already reads.
    private var oracleSection: some View {
        GroupBox(label:
            HStack {
                Text("Oracle", comment: "Developer Tools section header for the WPE render oracle controls.")
                    .font(.headline)
                Spacer()
                Button {
                    revealDebugArtifacts()
                } label: {
                    Label("Reveal trace", systemImage: "folder")
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: boolBinding(Self.oracleEnabledKey)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Render oracle", comment: "Developer Tools toggle title enabling the WPE render oracle (deterministic capture mode).")
                        Text("Seeds particle RNG, freezes the frame clock, and records per-pass and final trace hashes for same-machine refactor-safety diffing or Windows fidelity replay. Restart the app after toggling — a running instance caches the old value.", comment: "Developer Tools helper text under the render oracle toggle.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Freeze time", comment: "Developer Tools section label above the WPE render oracle's frozen scene-time field.")
                        .font(.callout.weight(.medium))
                    Text("Synthetic scene time the oracle freezes every frame to. Defaults to 6 seconds when left blank.", comment: "Developer Tools helper text explaining the WPE render oracle freeze-time field.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("Seconds", text: $freezeTimeText, prompt: Text(verbatim: "6.0"))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                            .onSubmit { commitFreezeTime() }
                        Button("Apply") { commitFreezeTime() }
                    }
                }

                Text("Traces land in the scene-debug folder shown by “Reveal trace” once a scene is reloaded with the oracle on.", comment: "Developer Tools helper text pointing to where WPE render oracle traces are written.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .id(flagRefresh)
        }
    }

    private func commitFreezeTime() {
        let trimmed = freezeTimeText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.oracleFreezeTimeKey)
        } else if let value = Double(trimmed), value >= 0 {
            UserDefaults.standard.set(value, forKey: Self.oracleFreezeTimeKey)
        }
        flagRefresh += 1
    }

    // MARK: - GPU capture

    private func addCaptureID() {
        let id = newCaptureID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !captureIDs.contains(id) else { return }
        captureIDs.append(id)
        UserDefaults.standard.set(captureIDs, forKey: Self.captureSceneKey)
        newCaptureID = ""
    }

    private func removeCaptureID(_ id: String) {
        captureIDs.removeAll { $0 == id }
        if captureIDs.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.captureSceneKey)
        } else {
            UserDefaults.standard.set(captureIDs, forKey: Self.captureSceneKey)
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
