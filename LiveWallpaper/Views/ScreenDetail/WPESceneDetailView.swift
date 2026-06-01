#if !LITE_BUILD
import AppKit
import SwiftUI

/// Scene detail card for Wallpaper Engine projects. Drives the loading /
/// playing / paused / error state machine on top of the renderer view the
/// wallpaper session already mounted into the desktop window. The inspector
/// reuses the same renderer instance so the preview seen here is
/// byte-identical to the live wallpaper.
@MainActor
struct WPESceneDetailView: View {
    let origin: WPEOrigin
    let descriptor: SceneDescriptor
    let session: SceneWallpaperSession?
    let onClearWallpaper: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var state: SceneRenderState = .idle
    /// Developer disclosure toggled by the info button on the metadata row
    /// or by right-clicking the row. Surfaces capability tier + first failure
    /// diagnostic so power users can see *why* a layer was skipped without
    /// diving into Console.
    @State private var showDiagnostics = false

    var body: some View {
        VStack(spacing: 16) {
            previewCard
            metadata
            if showDiagnostics { diagnosticsPanel }
            actions
        }
        .padding(24)
        .frame(maxWidth: 560)
        .adaptiveGlassSurface(.roundedRectangle(24))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(origin.title). Scene wallpaper. \(stateAccessibilityText)", comment: "A11y label for a Wallpaper Engine scene detail card. Placeholders are scene title and state."))
        .task(id: descriptor.workshopID) {
            await refreshState()
        }
        .onChange(of: reduceMotion) { _, _ in
            Task { @MainActor in await refreshState() }
        }
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in
            guard state == .idle || state.isLoading else { return }
            Task { @MainActor in
                await refreshState()
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var previewCard: some View {
        ZStack {
            switch state {
            case .idle:
                fallbackBackground
                LiquidGlassSpinner()
            case .loading(let progress):
                fallbackBackground
                LiquidGlassSpinner(progressText: progress)
            case .ready:
                fallbackBackground
            case .error(let fallbackReason):
                fallbackBackground
                    .overlay(errorOverlay(reason: fallbackReason))
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: stateKey)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 260)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func errorOverlay(reason: FallbackReason) -> some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.yellow)
                errorTitle(for: reason)
                    .font(.headline)
                    .foregroundStyle(.white)
                errorBody(for: reason)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
    }

    /// Inline copy that avoids nesting a full `WPEFallbackCard` (with its own glass background) inside this card.
    private func errorTitle(for reason: FallbackReason) -> Text {
        switch reason {
        case .unsupportedType:        return Text("Scene format not supported")
        case .sceneParseFailed:       return Text("Couldn't read scene.json")
        case .sceneShaderUnsupported: return Text("Scene uses unsupported shaders")
        case .sceneResourceMissing:   return Text("Some scene assets are missing")
        case .missingDependency(let ids):
            if ids.count == 1 {
                return Text("Missing 1 Workshop dependency")
            }
            return Text("Missing \(ids.count) Workshop dependencies", comment: "Scene error title. The placeholder is the number of missing Workshop dependencies.")
        case .requiresWindowsPlugin:  return Text("Windows plugin required")
        case .texContainerUnsupported: return Text("Unknown texture container")
        case .texUnsupportedFormat:    return Text("Texture format not supported")
        case .texDecodeFailed:         return Text("Texture decode failed")
        }
    }

    private func errorBody(for reason: FallbackReason) -> Text {
        switch reason {
        case .unsupportedType:
            return Text("We can't render this scene's feature set yet.")
        case .sceneParseFailed(let detail):
            return Text(verbatim: detail)
        case .sceneShaderUnsupported:
            return Text("A custom shader couldn't be translated. Try re-downloading the project.")
        case .sceneResourceMissing:
            return Text("Image layers couldn't be located inside the cache.")
        case .missingDependency(let ids):
            if ids.count <= 2 {
                return Text("Subscribe to \(ids.joined(separator: ", ")) in Steam, then re-import.", comment: "Scene dependency recovery hint. The placeholder is one or two Workshop IDs.")
            }
            let head = ids.prefix(2).joined(separator: ", ")
            return Text("Subscribe to \(head) and \(ids.count - 2) more in Steam, then re-import.", comment: "Scene dependency recovery hint. Placeholders are Workshop IDs and the remaining count.")
        case .requiresWindowsPlugin:
            return Text("macOS can't load Windows native plugins.")
        case .texContainerUnsupported(let magic):
            return Text("Container \(magic) — Phase 2.x will add it.", comment: "Texture error detail. The placeholder is a texture container magic value.")
        case .texUnsupportedFormat(let code):
            return Text("Format \(code) — not yet decoded.", comment: "Texture error detail. The placeholder is a texture format code.")
        case .texDecodeFailed(let detail):
            return Text(verbatim: detail)
        }
    }

    /// The project's own preview GIF (Workshop scenes always ship one), filling
    /// the card with aspect-fill crop. This replaces the former first-frame
    /// Metal snapshot — the live `MTKView` already drives the desktop wallpaper,
    /// so the inspector no longer pays for a synchronous GPU read-back just to
    /// show a thumbnail.
    private var fallbackBackground: some View {
        WPEPreviewView(
            imageURL: previewURL,
            securityScopedBookmarkData: origin.sourceFolderBookmark,
            aspectRatio: nil
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .blur(radius: state.isLoading ? 6 : 0)
        .overlay(Color.black.opacity(state.isLoading ? 0.35 : 0.0))
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: origin.title)
                    .font(.title3.bold())
                Spacer()
                statusPill
            }
            HStack(spacing: 6) {
                Text("Workshop ID \(origin.workshopID) · capability: \(descriptor.capabilityTier.localizedLabel)", comment: "Scene metadata row. Placeholders are Workshop ID and capability tier.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button {
                    withAnimation(DesignTokens.motion(reduceMotion, .spring(response: 0.35, dampingFraction: 0.85))) {
                        showDiagnostics.toggle()
                    }
                } label: {
                    Image(systemName: showDiagnostics ? "info.circle.fill" : "info.circle")
                        .font(.caption2)
                        .foregroundStyle(showDiagnostics ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(Text(showDiagnostics
                    ? "Hide renderer diagnostics"
                    : "Show renderer diagnostics"))
                .accessibilityLabel(Text(showDiagnostics ? "Hide renderer diagnostics" : "Show renderer diagnostics"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                withAnimation(DesignTokens.motion(reduceMotion, .spring(response: 0.35, dampingFraction: 0.85))) {
                    showDiagnostics.toggle()
                }
            } label: {
                Label(showDiagnostics ? "Hide Diagnostics" : "Show Diagnostics", systemImage: "info.circle")
            }
        }
    }

    @ViewBuilder
    private var diagnosticsPanel: some View {
        let diagnosticText = session?.sceneRenderer?.loadDiagnostics?.errorDescription
            ?? "All declared layers decoded cleanly."
        #if DEBUG
        let resolutionSnapshot = session?.sceneRenderer?.resolutionDiagnostics
        let resolutionA11y = resolutionSnapshot.map(Self.resolutionSummaryText)
            ?? "No resource resolution events recorded."
        #endif

        VStack(alignment: .leading, spacing: 6) {
            Text("Renderer Diagnostics")
                .font(.caption.bold())
            Text("Capability: \(descriptor.capabilityTier.localizedLabel)", comment: "Renderer diagnostics capability row. The placeholder is the capability tier.")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(verbatim: diagnosticText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
            #if DEBUG
            resolutionDiagnosticsSection(snapshot: resolutionSnapshot)
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        #if DEBUG
        .accessibilityLabel(Text("Renderer diagnostics: capability \(descriptor.capabilityTier.localizedLabel). \(diagnosticText). \(resolutionA11y)", comment: "A11y label for renderer diagnostics in DEBUG builds. Placeholders are capability tier, diagnostic text, and resolver summary."))
        #else
        .accessibilityLabel(Text("Renderer diagnostics: capability \(descriptor.capabilityTier.localizedLabel). \(diagnosticText)", comment: "A11y label for renderer diagnostics. Placeholders are capability tier and diagnostic text."))
        #endif
    }

    #if DEBUG
    @ViewBuilder
    private func resolutionDiagnosticsSection(snapshot: WPEResolutionDiagnosticsSnapshot?) -> some View {
        Divider()
            .padding(.vertical, 2)
        Text(verbatim: "Resource Resolution")
            .font(.caption.bold())
        if let snapshot {
            Text(verbatim: Self.resolutionSummaryText(snapshot))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            let misses = Array(snapshot.missedRefs.prefix(20))
            if misses.isEmpty {
                Text(verbatim: "Misses: none")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Misses:")
                    ForEach(Array(misses.enumerated()), id: \.offset) { pair in
                        let event = pair.element
                        Text(verbatim: "\(event.ref): \(event.finalOutcome.debugLabel)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if snapshot.missedRefs.count > misses.count {
                        Text(verbatim: "+\(snapshot.missedRefs.count - misses.count) more")
                    }
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        } else {
            Text(verbatim: "No resource resolution events recorded.")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private static func resolutionSummaryText(_ snapshot: WPEResolutionDiagnosticsSnapshot) -> String {
        let counts = snapshot.resolvedByOrigin
        let dependencyCount = counts.reduce(0) { partial, entry in
            if case .dependency = entry.key { return partial + entry.value }
            return partial
        }
        var parts = [
            "scene: \(counts[.scene, default: 0])",
            "builtin: \(counts[.builtin, default: 0])",
            "engineAssets: \(counts[.engineAssets, default: 0])"
        ]
        if dependencyCount > 0 {
            parts.append("dependency: \(dependencyCount)")
        }
        return "Events: \(snapshot.events.count), resolved: \(snapshot.resolvedCount), \(parts.joined(separator: ", "))"
    }
    #endif

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(verbatim: stateLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                onClearWallpaper()
            } label: {
                Label("Clear Scene", systemImage: "xmark.circle")
            }
            .adaptiveGlassButton(.regular)
            .destructiveControlTint()
            .controlSize(.regular)
            .accessibilityHint(Text("Removes the scene wallpaper from this display"))

            Spacer()

            if case .error(let reason) = state, reason.isActionable {
                Button {
                    Task { @MainActor in
                        state = .loading
                        await session?.reload()
                        await refreshState()
                    }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .accessibilityHint(Text("Re-decodes the scene with the current cache state"))
            }
        }
    }

    // MARK: - State derivation

    private func refreshState() async {
        guard let session else {
            state = .error(.unsupportedType)
            return
        }
        if let error = session.loadError {
            state = .error(mapToFallbackReason(error))
            return
        }
        guard let renderer = session.sceneRenderer else {
            state = .idle
            return
        }
        if !renderer.hasPresentedFrame {
            state = .loading(progress: session.loadProgress)
            return
        }
        // Still suspend the *live* renderer under Reduce Motion; the inspector
        // itself just shows the project's preview GIF (which holds a static
        // poster under Reduce Motion), so there's no separate paused state.
        renderer.applyPerformanceProfile(reduceMotion ? .suspended : .quality)
        state = .ready
    }

    private func mapToFallbackReason(_ error: SceneRenderingError) -> FallbackReason {
        switch error {
        case .cacheRootMissing:
            return .sceneResourceMissing
        case .parseFailed(let detail):
            return .sceneParseFailed(detail)
        case .resourceFailed(let diagnostic):
            return Self.fallbackReason(for: diagnostic)
        case .metalRendererUnsupported(let reason):
            // The session swaps in WebGL on this error before surfacing it
            // to the UI; the only path here is "WebGL fallback unavailable
            // or itself failed". Treat like a generic scene parse failure
            // so the inspector still shows a meaningful diagnostic.
            return .sceneParseFailed(reason)
        }
    }

    /// Maps the most-specific per-layer failure into the corresponding FallbackReason.
    static func fallbackReason(for diagnostic: SceneLoadDiagnostic) -> FallbackReason {
        switch diagnostic {
        case .texture(_, let error):
            switch error {
            case .unsupportedContainer(let magic):
                return .texContainerUnsupported(magic: magic)
            case .unsupportedFormat(let code):
                return .texUnsupportedFormat(code: code)
            case .metalUnavailable:
                return .texUnsupportedFormat(code: -1)
            case .unsupportedAnimation:
                return .texDecodeFailed(detail: "animation/sequence frames")
            default:
                return .texDecodeFailed(detail: error.errorDescription ?? "decode failed")
            }
        case .legacyUnsupportedTexture:
            return .texDecodeFailed(detail: "legacy .tex stub")
        case .fileMissing, .crossPackageReference:
            return .sceneResourceMissing
        case .materialUnresolved(_, let reason):
            return .texDecodeFailed(detail: reason)
        case .other(_, let message):
            return .texDecodeFailed(detail: message)
        }
    }

    private var stateKey: Int {
        switch state {
        case .idle:    return 0
        case .loading: return 1
        case .ready:   return 2
        case .error:   return 3
        }
    }

    private var stateLabel: String {
        switch state {
        case .idle:
            return String(localized: "Idle", defaultValue: "Idle", comment: "Scene renderer state.")
        case .loading:
            return String(localized: "Loading", defaultValue: "Loading", comment: "Scene renderer state.")
        case .ready:
            return String(localized: "Playing", defaultValue: "Playing", comment: "Scene renderer state.")
        case .error:
            return String(localized: "Error", defaultValue: "Error", comment: "Scene renderer state.")
        }
    }

    private var stateAccessibilityText: String {
        switch state {
        case .idle:
            return String(localized: "Idle", defaultValue: "Idle", comment: "Scene renderer accessibility state.")
        case .loading:
            return String(localized: "Loading scene assets", defaultValue: "Loading scene assets", comment: "Scene renderer accessibility state.")
        case .ready:
            return String(localized: "Scene preview", defaultValue: "Scene preview", comment: "Scene renderer accessibility state.")
        case .error:
            return String(localized: "Scene cannot be played", defaultValue: "Scene cannot be played", comment: "Scene renderer accessibility state.")
        }
    }

    private var statusColor: Color {
        switch state {
        case .ready:   return .blue
        case .loading: return .yellow
        case .error:   return .red
        case .idle:    return .secondary
        }
    }

    private var previewURL: URL? {
        origin.sourcePreviewURL
    }
}

// MARK: - State machine

enum SceneRenderState: Equatable {
    case idle
    case loading(progress: String?)
    /// Scene loaded and presenting. The live `MTKView` drives the desktop
    /// wallpaper itself; the detail card shows the project's preview GIF so it
    /// never has to read back a frame off the GPU.
    case ready
    case error(FallbackReason)

    /// Convenience for "loading without specific progress text" — keeps
    /// the dozens of existing call sites that just wrote `.loading`
    /// pinned to a single source of truth.
    static var loading: SceneRenderState { .loading(progress: nil) }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    static func == (lhs: SceneRenderState, rhs: SceneRenderState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.loading(let l), .loading(let r)): return l == r
        case (.ready, .ready): return true
        case (.error(let l), .error(let r)): return l == r
        default: return false
        }
    }
}

#endif
