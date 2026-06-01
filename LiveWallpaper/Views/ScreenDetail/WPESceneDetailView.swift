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
    /// Second-level disclosure inside the error console: expands the raw,
    /// monospaced renderer log. Collapsed by default so the friendly summary
    /// leads and the wall of diagnostic text is opt-in.
    @State private var showRawLog = false
    /// Transient "copied" affordance on the console's Copy button.
    @State private var didCopyLog = false
    /// Presents the full diagnostic log in a resizable in-app window so a long
    /// log never has to grow the inspector card off-screen.
    @State private var showLogSheet = false

    var body: some View {
        VStack(spacing: 16) {
            previewCard
            errorConsole
            metadata
            if showDiagnostics { diagnosticsPanel }
            actions
        }
        .padding(24)
        .frame(maxWidth: 560)
        .adaptiveGlassSurface(.roundedRectangle(24))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .sheet(isPresented: $showLogSheet) {
            DiagnosticLogSheet(title: origin.title, log: fullDiagnosticText)
        }
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
                    .overlay(alignment: .bottom) { previewErrorStrip(reason: fallbackReason) }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(severityColor(for: fallbackReason).opacity(0.45), lineWidth: 1.5)
                    }
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: stateKey)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 260)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Lightweight gradient strip pinned to the bottom of the (now unmasked)
    /// preview GIF. Surfaces a glanceable error code without hiding the artwork
    /// — the full story lives in `errorConsole` directly below.
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

    // MARK: - Error console

    /// Terminal-style diagnostic console that appears directly below the preview
    /// GIF whenever the scene failed. Collapses to zero height (no `spacing`
    /// cost) when there's no error. Layers a friendly summary over the raw,
    /// copyable renderer log behind a disclosure.
    @ViewBuilder
    private var errorConsole: some View {
        if case .error(let reason) = state {
            VStack(alignment: .leading, spacing: 0) {
                consoleHeader(reason: reason)

                errorBody(for: reason)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, diagnosticLogText == nil ? 14 : 10)

                if let log = diagnosticLogText {
                    rawLogDisclosure(log: log)
                }
            }
            .background(Color.black.opacity(0.88))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(severityColor(for: reason))
                    .frame(width: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(severityColor(for: reason).opacity(0.35), lineWidth: 1)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
        }
    }

    private func consoleHeader(reason: FallbackReason) -> some View {
        HStack(spacing: 8) {
            Image(systemName: severityIcon(for: reason))
                .font(.headline)
                .foregroundStyle(severityColor(for: reason))
            errorTitle(for: reason)
                .font(.headline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                copyDiagnostics(reason: reason)
            } label: {
                Image(systemName: didCopyLog ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(didCopyLog ? Color.green : .white.opacity(0.8))
                    .frame(width: 22, height: 22)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(Text("Copy diagnostic log"))
            .accessibilityLabel(Text(didCopyLog ? "Diagnostic log copied" : "Copy diagnostic log"))
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func rawLogDisclosure(log: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Color.white.opacity(0.12))

            HStack(spacing: 6) {
                Button {
                    withAnimation(DesignTokens.motion(reduceMotion, .spring(response: 0.3, dampingFraction: 0.85))) {
                        showRawLog.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(showRawLog ? 90 : 0))
                        Text(showRawLog ? "Hide diagnostic log" : "Show diagnostic log")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(showRawLog ? "Hide diagnostic log" : "Show diagnostic log"))

                Spacer(minLength: 0)

                Button {
                    showLogSheet = true
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.plain)
                .help(Text("Open the full diagnostic log in a resizable window"))
                .accessibilityLabel(Text("Open full diagnostic log"))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if showRawLog {
                ScrollView(.vertical) {
                    Text(verbatim: log)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.green.opacity(0.92))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }
                .frame(maxHeight: 140)
                .transition(.opacity)
            }
        }
    }

    /// Aggregated, PII-scrubbed diagnostic text for the resizable log window:
    /// capability tier + error code (when failed) + the renderer's first-failure
    /// description + (DEBUG) the resource-resolution summary and misses.
    private var fullDiagnosticText: String {
        var lines: [String] = ["Capability: \(descriptor.capabilityTier.localizedLabel)"]
        if case .error(let reason) = state {
            lines.append("Error code: \(errorCode(for: reason))")
        }
        lines.append("")
        lines.append(session?.sceneRenderer?.loadDiagnostics?.errorDescription
            ?? "All declared layers decoded cleanly.")
        #if DEBUG
        if let snapshot = session?.sceneRenderer?.resolutionDiagnostics {
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
        }
        #endif
        return PIISanitizer.scrub(lines.joined(separator: "\n"))
    }

    // MARK: - Severity derivation

    /// Maps a fallback reason to a severity tint. User-recoverable problems
    /// (missing Steam dependency, Windows-only plugin) read as warnings;
    /// everything else is a hard render failure.
    private func severityColor(for reason: FallbackReason) -> Color {
        switch reason {
        case .missingDependency, .requiresWindowsPlugin: return .orange
        default:                                         return .red
        }
    }

    private func severityIcon(for reason: FallbackReason) -> String {
        switch reason {
        case .missingDependency:     return "exclamationmark.triangle.fill"
        case .requiresWindowsPlugin: return "puzzlepiece.extension.fill"
        default:                     return "exclamationmark.octagon.fill"
        }
    }

    /// Short, glanceable machine code shown on the preview strip and copied
    /// alongside the raw log.
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

    /// The renderer's first-failure diagnostic — the actual "log" text, scrubbed
    /// of home paths / `/Users/<name>` / URLs before it reaches the screen or
    /// the clipboard (the Copy button makes this trivially shareable). `nil`
    /// when the failure surfaced before any per-layer diagnostic was recorded.
    private var diagnosticLogText: String? {
        guard let raw = session?.sceneRenderer?.loadDiagnostics?.errorDescription else { return nil }
        return PIISanitizer.scrub(raw)
    }

    private func copyDiagnostics(reason: FallbackReason) {
        var parts = [errorCode(for: reason)]
        if let log = diagnosticLogText {
            parts.append(log)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(parts.joined(separator: "\n\n"), forType: .string)

        didCopyLog = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopyLog = false
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
        let rawDiagnostic = session?.sceneRenderer?.loadDiagnostics?.errorDescription
        let diagnosticText = rawDiagnostic.map(PIISanitizer.scrub) ?? "All declared layers decoded cleanly."
        #if DEBUG
        let resolutionSnapshot = session?.sceneRenderer?.resolutionDiagnostics
        let resolutionA11y = resolutionSnapshot.map(Self.resolutionSummaryText)
            ?? "No resource resolution events recorded."
        #endif

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Renderer Diagnostics")
                    .font(.caption.bold())
                Spacer(minLength: 4)
                Button {
                    showLogSheet = true
                } label: {
                    Image(systemName: "macwindow")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(Text("Open the full diagnostic log in a resizable window"))
                .accessibilityLabel(Text("Open full diagnostic log"))
            }
            Text("Capability: \(descriptor.capabilityTier.localizedLabel)", comment: "Renderer diagnostics capability row. The placeholder is the capability tier.")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            // Bounded + scrollable so a long renderer log (or DEBUG resolution
            // misses) never grows the card off-screen; the window button above
            // opens the complete log when 160pt isn't enough.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: diagnosticText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    #if DEBUG
                    resolutionDiagnosticsSection(snapshot: resolutionSnapshot)
                    #endif
                }
            }
            .frame(maxHeight: 160)
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
                        withAnimation(DesignTokens.motion(reduceMotion, .spring(response: 0.35, dampingFraction: 0.85))) {
                            state = .loading
                        }
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
        let next = derivedState()
        guard next != state else { return }
        // Drive the assignment through an animation so the error console's
        // insertion/removal slides instead of snapping the layout — the 0.4s
        // poll only re-animates when the state actually changes (guard above).
        withAnimation(DesignTokens.motion(reduceMotion, .spring(response: 0.35, dampingFraction: 0.85))) {
            state = next
        }
    }

    /// Pure state derivation (plus the live renderer's Reduce-Motion side
    /// effect). Returns the state the card *should* be in for the current
    /// session, leaving the animated assignment to `refreshState()`.
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
        // itself just shows the project's preview GIF (which holds a static
        // poster under Reduce Motion), so there's no separate paused state.
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

// MARK: - Full diagnostic log window

/// Resizable in-app window (sheet) showing the complete diagnostic log when the
/// inline 140–160pt panels aren't enough. Monospaced, selectable, copyable.
@MainActor
private struct DiagnosticLogSheet: View {
    let title: String
    let log: String

    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
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
                }
                .buttonStyle(.bordered)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            ScrollView(.vertical) {
                Text(verbatim: log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 520, idealWidth: 660, minHeight: 360, idealHeight: 520)
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
