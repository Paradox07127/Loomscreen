#if !LITE_BUILD
import AppKit
import Metal
import SwiftUI

/// Scene detail card for Wallpaper Engine projects. Reuses the renderer instance
/// the wallpaper session already mounted into the desktop window, so the preview
/// seen here is byte-identical to the live wallpaper.
@MainActor
struct WPESceneDetailView: View {
    private let screenAspectRatio: CGFloat = 16 / 9
    private let infoBarReservedHeight: CGFloat = 44
    private let errorBannerReservedHeight: CGFloat = 76
    private let stackSpacing: CGFloat = 16

    let origin: WPEOrigin
    let descriptor: SceneDescriptor
    let session: SceneWallpaperSession?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureCatalog) private var featureCatalog
    @State private var state: SceneRenderState = .idle
    /// The live renderer's own frame, reused as the hero poster once it presents.
    @State private var livePoster: NSImage?
    @State private var livePosterTask: Task<Void, Never>?
    /// The verbose renderer log opens in a sheet, never inline, so the layout
    /// barely shifts on error.
    @State private var showLogSheet = false

    var body: some View {
        GeometryReader { geo in
            let previewSize = screenPreviewSize(
                in: geo.size,
                reservedHeight: previewReservedHeight
            )
            VStack(spacing: stackSpacing) {
                previewCard
                    .frame(width: previewSize.width, height: previewSize.height)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .layoutPriority(1)
                infoBar
                errorBanner
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showLogSheet) {
            DiagnosticLogSheet(title: origin.title, log: fullDiagnosticText, tint: currentSeverityTint)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(origin.title). Scene wallpaper. \(stateAccessibilityText)", comment: "A11y label for a Wallpaper Engine scene detail card. Placeholders are scene title and state."))
        .task(id: descriptor.workshopID) {
            livePosterTask?.cancel()
            livePosterTask = nil
            livePoster = nil
            await refreshState()
        }
        .onChange(of: reduceMotion) { _, _ in
            livePosterTask?.cancel()
            livePosterTask = nil
            Task { @MainActor in await refreshState() }
        }
        .onDisappear {
            livePosterTask?.cancel()
            livePosterTask = nil
            livePoster = nil
        }
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in
            guard state == .idle || state.isLoading else { return }
            Task { @MainActor in
                await refreshState()
            }
        }
    }

    // MARK: - Subviews

    private var previewCard: some View {
        ZStack {
            // Chrome (clip + shadow) sits on the image layer only, matching the
            // video / HTML previews, so the info capsule overlays on top rather
            // than being clipped or shadowed with it.
            ZStack { stateBackground }
                .screenPreviewChrome()
            // Info capsule lives INSIDE the aspect-fit ZStack (exactly like the
            // video / HTML overlays) so it tracks the 16:9 content and never
            // escapes onto the letterbox margin on a wide window.
            VStack {
                HStack {
                    SceneInformationOverlay(origin: origin, descriptor: descriptor)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .allowsHitTesting(false)
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: stateKey)
    }

    @ViewBuilder
    private var stateBackground: some View {
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
                .overlay(alignment: .bottom) { previewErrorStrip(reason: fallbackReason) }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(severityColor(for: fallbackReason).opacity(0.45), lineWidth: 1.5)
                }
        }
    }

    /// Surfaces a glanceable error code without hiding the artwork — the friendly
    /// summary lives in `errorBanner`, the full log in the diagnostic window.
    private func previewErrorStrip(reason: FallbackReason) -> some View {
        HStack(spacing: 6) {
            Image(systemName: severityIcon(for: reason))
                .font(.caption.weight(.semibold))
                .foregroundStyle(severityColor(for: reason))
            Text(verbatim: errorCode(for: reason))
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 24)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
            return Text(verbatim: PIISanitizer.scrub(detail))
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
            return Text(verbatim: PIISanitizer.scrub(detail))
        }
    }

    // MARK: - Error banner

    @ViewBuilder
    private var errorBanner: some View {
        if case .error(let reason) = state {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: severityIcon(for: reason))
                    .font(.title3)
                    .foregroundStyle(severityColor(for: reason))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    errorTitle(for: reason)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    errorBody(for: reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Combine only the text so it reads as one phrase, leaving the
                // Log button a separate, focusable VoiceOver node.
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                if reason.isActionable {
                    Button {
                        Task { @MainActor in
                            withAnimation(DesignTokens.motion(reduceMotion, .spring(response: 0.35, dampingFraction: 0.85))) {
                                state = .loading
                            }
                            livePoster = nil
                            await session?.reload()
                            await refreshState()
                        }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityHint(Text("Re-decodes the scene with the current cache state"))
                }
                Button {
                    showLogSheet = true
                } label: {
                    Label("Log", systemImage: "terminal")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(Text("Open the full diagnostic log"))
                .accessibilityLabel(Text("Open the full diagnostic log"))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(severityColor(for: reason).opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(severityColor(for: reason).opacity(0.30), lineWidth: 1)
            }
            .transition(.opacity)
        }
    }

    /// PII-scrubbed diagnostic text for the log window. Shown in Release too: the
    /// resolution tracer already runs unconditionally, so surfacing it costs
    /// nothing and is what makes a user bug report actionable (which refs missed,
    /// why the capability badge reads the way it does).
    private var fullDiagnosticText: String {
        var lines: [String] = ["Capability: \(descriptor.capabilityTier.localizedLabel)"]
        if let preflight = descriptor.preflightTier, preflight != .nativePlayable {
            lines.append("Preflight: \(preflight.localizedLabel)")
        }
        if !descriptor.preflightFeatureFlags.isEmpty {
            lines.append("Features: \(descriptor.preflightFeatureFlags.map(\.rawValue).joined(separator: ", "))")
        }
        if case .error(let reason) = state {
            lines.append("Error code: \(errorCode(for: reason))")
        }
        lines.append("")

        let loadDiagnostic = session?.sceneRenderer?.loadDiagnostics?.errorDescription
        let snapshot = session?.sceneRenderer?.resolutionDiagnostics

        if let loadDiagnostic {
            lines.append(loadDiagnostic)
        }

        if let snapshot {
            if loadDiagnostic == nil {
                lines.append(snapshot.missedRefs.isEmpty
                    ? "All declared refs resolved (\(snapshot.resolvedCount))."
                    : "\(snapshot.missedRefs.count) ref(s) unresolved, \(snapshot.resolvedCount) resolved.")
            }
            lines.append("")
            lines.append("Resource Resolution")
            lines.append(Self.resolutionSummaryText(snapshot))
            if snapshot.missedRefs.isEmpty {
                lines.append("Misses: none")
            } else {
                lines.append("Misses:")
                for event in snapshot.missedRefs.prefix(500) {
                    lines.append("  \(event.ref): \(event.finalOutcome.debugLabel)")
                }
            }
            // Refs the scene package didn't carry but a built-in / engine-assets /
            // dependency mount covered — a "scene shipped incomplete" signal.
            let fallback = Self.fallbackResolvedRefs(snapshot)
            if !fallback.isEmpty {
                lines.append("Resolved via fallback (not in scene package):")
                for entry in fallback.prefix(40) {
                    lines.append("  \(entry.ref) <- \(entry.origin)")
                }
            }
            // Capability is computed at import (path probe + parser diagnostics);
            // a clean runtime resolve means the badge is an import-time false positive.
            if loadDiagnostic == nil
                && descriptor.capabilityTier == .degraded
                && snapshot.missedRefs.isEmpty {
                lines.append("")
                lines.append("Note: \"Limited Compatibility\" was set at import; every ref resolved at runtime — see Preflight above for the reason.")
            }
        } else if loadDiagnostic == nil {
            lines.append("No render diagnostics yet (scene not loaded).")
        }

        if let shaders = session?.sceneRenderer?.shaderErrorSummary, shaders.count > 0 {
            lines.append("")
            lines.append("Shader compile failures: \(shaders.count) (pass skipped — effect not drawn)")
            for entry in shaders.entries.prefix(20) {
                lines.append("  \(entry.shader): \(entry.reason)")
            }
        }

        if let gpu = session?.sceneRenderer?.gpuErrorSummary, gpu.count > 0 {
            lines.append("")
            lines.append("GPU errors: \(gpu.count)" + (gpu.last.map { " (last: \($0))" } ?? ""))
        }

        lines.append("")
        lines.append(contentsOf: environmentLines())

        return PIISanitizer.scrub(lines.joined(separator: "\n"))
    }

    // MARK: - Severity derivation

    /// Maps a fallback reason to a severity tint. User-recoverable problems
    /// (missing Steam dependency, Windows-only plugin) read as warnings;
    /// everything else is a hard render failure.
    private func severityColor(for reason: FallbackReason) -> Color {
        switch reason {
        case .missingDependency, .requiresWindowsPlugin: return DesignTokens.Colors.Status.warning
        default:                                         return DesignTokens.Colors.Status.danger
        }
    }

    private func severityIcon(for reason: FallbackReason) -> String {
        switch reason {
        case .missingDependency:     return "exclamationmark.triangle.fill"
        case .requiresWindowsPlugin: return "puzzlepiece.extension.fill"
        default:                     return "exclamationmark.octagon.fill"
        }
    }

    private func errorCode(for reason: FallbackReason) -> String {
        switch reason {
        case .unsupportedType:         return "WPE_UNSUPPORTED_TYPE"
        case .sceneParseFailed:        return "WPE_SCENE_PARSE"
        case .sceneShaderUnsupported:  return "WPE_SHADER_UNSUPPORTED"
        case .sceneResourceMissing:    return "WPE_RESOURCE_MISS"
        case .missingDependency:       return "WPE_MISSING_DEPENDENCY"
        case .requiresWindowsPlugin:   return "WPE_WINDOWS_PLUGIN"
        case .texContainerUnsupported: return "WPE_TEX_CONTAINER"
        case .texUnsupportedFormat:    return "WPE_TEX_FORMAT"
        case .texDecodeFailed:         return "WPE_TEX_DECODE"
        }
    }

    private var currentSeverityTint: Color {
        if case .error(let reason) = state {
            return severityColor(for: reason)
        }
        return .accentColor
    }

    /// Reuses the live renderer's own frame (already drawn for the desktop —
    /// no re-render) as the hero, byte-identical to the wallpaper. Falls back to
    /// the project's preview GIF while loading or if the read-back is unavailable.
    @ViewBuilder
    private var fallbackBackground: some View {
        Group {
            if let livePoster {
                ZStack {
                    Color.black
                    Image(nsImage: livePoster)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            } else {
                WPEPreviewView(
                    imageURL: previewURL,
                    securityScopedBookmarkData: origin.sourceFolderBookmark,
                    playbackMode: .staticPoster,
                    aspectRatio: nil
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .blur(radius: state.isLoading ? 6 : 0)
        .overlay(Color.black.opacity(state.isLoading ? 0.35 : 0.0))
    }

    private var previewReservedHeight: CGFloat {
        let base = infoBarReservedHeight + stackSpacing
        if case .error = state {
            return base + errorBannerReservedHeight + stackSpacing
        }
        return base
    }

    private func screenPreviewSize(in available: CGSize, reservedHeight: CGFloat) -> CGSize {
        let maxHeight = max(0, available.height - reservedHeight)
        let heightForAvailableWidth = available.width / screenAspectRatio
        let height = min(maxHeight, heightForAvailableWidth)
        return CGSize(width: height * screenAspectRatio, height: height)
    }

    /// Floating glass info bar under the preview — the scene-type analog of the
    /// video command bar. Display name, live status, and Clear live in the shared
    /// `ScreenDetailHeader`, so this carries only scene-specific identity.
    private var infoBar: some View {
        HStack(spacing: 10) {
            Text(verbatim: origin.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            workshopLinkButton
            Button {
                showLogSheet = true
            } label: {
                Image(systemName: "terminal")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(Text("Open renderer diagnostics"))
            .accessibilityLabel(Text("Open renderer diagnostics"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlassSurface(.capsule)
        .contextMenu {
            Button {
                showLogSheet = true
            } label: {
                Label("Renderer Diagnostics", systemImage: "terminal")
            }
        }
    }

    /// Compact hyperlink button to the item's Workshop page. Shown only for a
    /// numeric Steam item; locally-imported projects have no web page.
    @ViewBuilder
    private var workshopLinkButton: some View {
        if isSteamWorkshopID, let url = steamWorkshopURL {
            #if DIRECT_DISTRIBUTION
            if featureCatalog.isEnabled(.wpeImport) {
                Menu {
                    Button {
                        WorkshopDeepLink.requestSearch(origin.title)
                        NotificationCenter.default.post(name: .openWorkshopPane, object: nil)
                    } label: {
                        Label("Find in Workshop", systemImage: "magnifyingglass")
                    }
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open Steam Page", systemImage: "safari")
                    }
                } label: {
                    Image(systemName: "safari")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(Text("Find this item in the Workshop, or open its Steam page"))
                .accessibilityLabel(Text("Workshop ID \(origin.workshopID). Find in Workshop or open the Steam page.", comment: "A11y label for the Workshop ID menu. The placeholder is the numeric Workshop ID."))
            } else {
                workshopWebLinkButton(url)
            }
            #else
            workshopWebLinkButton(url)
            #endif
        }
    }

    private func workshopWebLinkButton(_ url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Image(systemName: "safari")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(Text("Open this item's Steam Workshop page"))
        .accessibilityLabel(Text("Workshop ID \(origin.workshopID). Opens the Steam Workshop page.", comment: "A11y label for the Workshop ID link. The placeholder is the numeric Workshop ID."))
    }

    private var isSteamWorkshopID: Bool {
        !origin.workshopID.isEmpty && origin.workshopID.allSatisfy(\.isNumber)
    }

    private var steamWorkshopURL: URL? {
        URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(origin.workshopID)")
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

    private static func fallbackResolvedRefs(
        _ snapshot: WPEResolutionDiagnosticsSnapshot
    ) -> [(ref: String, origin: String)] {
        var seen = Set<String>()
        var result: [(ref: String, origin: String)] = []
        for event in snapshot.events {
            guard event.finalOutcome == .resolved,
                  let hit = event.attempts.last, hit.outcome == .resolved,
                  hit.origin != .scene,
                  seen.insert(event.ref).inserted else { continue }
            result.append((event.ref, hit.origin.debugLabel))
        }
        return result
    }

    private func environmentLines() -> [String] {
        var lines: [String] = ["Environment"]
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        lines.append("App \(version) (\(build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if let gpu = MTLCreateSystemDefaultDevice()?.name {
            lines.append("GPU: \(gpu)")
        }
        let screens = NSScreen.screens.map {
            "\(Int($0.frame.width))×\(Int($0.frame.height))@\(Int($0.backingScaleFactor))x"
        }
        lines.append("Displays: \(screens.count) [\(screens.joined(separator: ", "))]")
        let flags = Self.nonDefaultRenderFlags()
        if !flags.isEmpty {
            lines.append("Flags: \(flags.joined(separator: ", "))")
        }
        return lines
    }

    /// Render-behaviour `defaults` knobs surfaced in bug reports so dev-vs-user
    /// flag drift ("works on my machine") is visible. Only explicitly-set keys
    /// print; the curated list excludes pure dump/trace toggles.
    /// `WPERenderFlagRegistryTests` scans the renderer sources and fails when a
    /// key read there is neither listed here nor excluded there with a reason.
    private static let renderFlagKeys = [
        "WPEMetalMemorylessDepthEnabled", "WPEMetalMipChainEnabled", "WPEMetalSerializeFrames",
        "WPEMetalPerspectiveNativeResolution", "WPEMetalSceneBloomEnabled",
        "WPEMetalStaticLayerCacheEnabled",
        "WPEMetalStaticLayerCacheBudgetMiB", "WPEMetalTextureCacheBudgetMiB",
        "WPEMetalIntroPhaseAlignEnabled", "WPEEnableMSDFText", "WPEParallaxGain",
        "WPEParticlePrewarmEnabled", "WPEPuppetAttachmentBindAnchor",
        "WPEPuppetClipComposite", "WPEPuppetDeferMeshWarp",
        "WPEScriptAsyncTickEnabled"
    ]

    private static func nonDefaultRenderFlags() -> [String] {
        let defaults = UserDefaults.standard
        var flags = renderFlagKeys.compactMap { key -> String? in
            guard let value = defaults.object(forKey: key) else { return nil }
            return "\(key.dropFirst(3))=\(value)"
        }
        // Tier defaults apply when the budget key is unset, so an unset key no
        // longer means "unbounded" — always report the effective value.
        let effectiveBudget = WPEMetalSceneRenderer.textureCacheBudgetBytes
            .map { "\($0 / 1_048_576)MiB" } ?? "unbounded"
        flags.append("MemoryTier=\(WPEMemoryTier.current) textureBudget=\(effectiveBudget)")
        return flags
    }


    // MARK: - State derivation

    private func refreshState() async {
        let next = derivedState()
        if next != state {
            // Animate so the error console's insertion/removal slides instead of
            // snapping the layout; the `!=` guard keeps the 0.4s poll from
            // re-animating when nothing changed.
            withAnimation(DesignTokens.motion(reduceMotion, .spring(response: 0.35, dampingFraction: 0.85))) {
                state = next
            }
        }
        captureLivePosterIfNeeded(for: next)
    }

    /// Reuses the next frame the live renderer presents, without forcing an
    /// extra synchronous render. The GIF/static project preview remains visible
    /// until the readback finishes.
    private func captureLivePosterIfNeeded(for next: SceneRenderState) {
        guard !reduceMotion,
              case .ready = next,
              livePoster == nil,
              livePosterTask == nil,
              let renderer = session?.sceneRenderer else { return }
        livePosterTask = Task { @MainActor in
            let image = await renderer.captureLivePosterFromNextFrame()
            guard !Task.isCancelled else { return }
            livePoster = image
            livePosterTask = nil
        }
    }

    private func derivedState() -> SceneRenderState {
        guard let session else { return .error(.unsupportedType) }
        if let error = session.loadError {
            return .error(mapToFallbackReason(error))
        }
        guard let renderer = session.sceneRenderer else { return .idle }
        if !renderer.hasPresentedFrame {
            return .loading(progress: session.loadProgress)
        }
        // Still suspend the *live* renderer under Reduce Motion; the inspector
        // shows a static reused frame (or the preview GIF poster) anyway, so
        // there's no separate paused state.
        renderer.applyPerformanceProfile(reduceMotion ? .suspended : .quality)
        return .ready
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
            // Map hard renderer gaps onto a parse failure so the inspector still
            // shows a meaningful diagnostic.
            return .sceneParseFailed(reason)
        }
    }

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

    private var previewURL: URL? {
        origin.sourcePreviewURL
    }
}

// MARK: - Diagnostic log window

@MainActor
private struct DiagnosticLogSheet: View {
    let title: String
    let log: String
    let tint: Color

    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false
    /// Cached so the whole AttributedString isn't rebuilt on every body refresh
    /// (e.g. the `didCopy` toggle) — matters for long logs.
    @State private var rendered: AttributedString?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            terminal
        }
        .frame(minWidth: 540, idealWidth: 680, minHeight: 380, idealHeight: 540)
        .background(.ultraThinMaterial)
        .task { if rendered == nil { rendered = Self.colourise(log) } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Diagnostic Log")
                    .font(.headline)
                Text(verbatim: title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                copy()
            } label: {
                Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .animation(.snappy, value: didCopy)
            }
            .buttonStyle(.bordered)
            .tint(didCopy ? DesignTokens.Colors.Status.active : tint)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
        .background(tint.opacity(0.08))
    }

    private var terminal: some View {
        ScrollView(.vertical) {
            Text(rendered ?? AttributedString(log))
                .font(DesignTokens.Typography.codeCaption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .background(Color.black.opacity(0.8))
    }

    /// One `AttributedString` rather than per-line views, so copy/selection still
    /// spans the whole log.
    private static func colourise(_ log: String) -> AttributedString {
        let lines = log.components(separatedBy: "\n")
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            var piece = AttributedString(line)
            piece.foregroundColor = colour(for: line)
            result += piece
            if index < lines.count - 1 {
                result += AttributedString("\n")
            }
        }
        return result
    }

    private static func colour(for line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("[err") || lower.contains("error") || lower.contains("fail") {
            return Color(red: 1.0, green: 0.45, blue: 0.42)
        }
        if lower.contains("[warn") || lower.contains("warning") || lower.contains("legacy") {
            return Color(red: 1.0, green: 0.72, blue: 0.36)
        }
        // Tight match so "permission"/"dismiss"/"transmission" don't read as misses.
        if lower.contains("[miss") || lower.contains("miss:") || lower.contains("missing") || lower.contains("missed") {
            return Color(red: 0.98, green: 0.86, blue: 0.45)
        }
        if lower.contains("resolved") || lower.contains("success") || lower.contains("cleanly") {
            return Color(red: 0.56, green: 0.92, blue: 0.64)
        }
        return Color.white.opacity(0.85)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(log, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
        }
    }
}

// MARK: - State machine

enum SceneRenderState: Equatable {
    case idle
    case loading(progress: String?)
    /// Scene loaded and presenting. The live `MTKView` drives the desktop
    /// wallpaper; the detail card reuses the renderer's current frame as the
    /// hero poster (captured on demand, off the load path).
    case ready
    case error(FallbackReason)

    /// Keeps the call sites that just wrote `.loading` pinned to one definition.
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

// MARK: - Information overlay

/// Floating dark capsule over the scene preview — the scene-type analog of
/// `VideoInformationOverlay` / `HTMLInformationOverlay`. Every value reads from
/// the in-memory descriptor / origin, so there's no project.json parse here.
/// Short status tags stay verbatim to match the video / HTML badge convention.
struct SceneInformationOverlay: View {
    let origin: WPEOrigin
    let descriptor: SceneDescriptor

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "cube.transparent")
                Text(verbatim: origin.originalType.localizedDisplayName)
            }
            // High-signal first (warnings, abnormal capability) so the verbose
            // feature-flag tail is what clips first on a narrow preview. Normal
            // states (image-only capability, legacy cache storage) stay hidden to
            // cut clutter.
            if requiresWindowsPlugin {
                tag("WIN PLUGIN", background: DesignTokens.Colors.Status.danger.opacity(0.55))
            }
            if descriptor.capabilityTier != .imageOnly {
                tag(descriptor.capabilityTier.localizedLabel, background: capabilityBackground)
            }
            if let storageLabel {
                tag(storageLabel)
            }
            if !descriptor.dependencyWorkshopIDs.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "shippingbox")
                    Text(verbatim: "\(descriptor.dependencyWorkshopIDs.count)")
                }
            }
            ForEach(featureLabels, id: \.self) { tag($0) }
        }
        .font(DesignTokens.Typography.code)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .thumbnailBadgeGlass()
        .accessibilityElement(children: .combine)
    }

    private func tag(_ text: String, background: Color = Color.white.opacity(0.18)) -> some View {
        Text(verbatim: text)
            .font(DesignTokens.Typography.badge)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(background, in: Capsule())
    }

    private var capabilityBackground: Color {
        switch descriptor.capabilityTier {
        case .imageOnly:   return Color.white.opacity(0.18)
        case .degraded:    return DesignTokens.Colors.Status.warning.opacity(0.55)
        case .unsupported: return DesignTokens.Colors.Status.danger.opacity(0.55)
        }
    }

    private var storageLabel: String? {
        switch descriptor.assetStorage {
        case .cache:           return nil
        case .sourceDirectory: return "FOLDER"
        case .packageSource:   return "PACKAGED"
        }
    }

    private var requiresWindowsPlugin: Bool {
        origin.requiresWindowsPlugin || descriptor.preflightFeatureFlags.contains(.windowsPlugin)
    }

    private var featureLabels: [String] {
        descriptor.preflightFeatureFlags.compactMap { flag in
            switch flag {
            case .customShaderSource: return "SHADER"
            case .particleObject:     return "PARTICLE"
            case .textObject:         return "TEXT"
            case .soundObject:        return "AUDIO"
            case .lightObject:        return "LIGHT"
            case .animationLayer:     return "ANIM"
            case .imageEffect:        return "FX"
            case .unknownObject:      return nil
            case .windowsPlugin:      return nil
            }
        }
    }
}

#endif
