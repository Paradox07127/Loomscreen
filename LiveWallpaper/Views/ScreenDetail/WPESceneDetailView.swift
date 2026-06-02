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
    @Environment(\.featureCatalog) private var featureCatalog
    @State private var state: SceneRenderState = .idle
    /// Presents the full diagnostic log in a resizable glass terminal window.
    /// Opened from the metadata info button (any state) or the error banner's
    /// "Log" button — the verbose renderer log never lives inline on the card,
    /// so the card stays compact and the layout barely shifts on error.
    @State private var showLogSheet = false

    var body: some View {
        VStack(spacing: 16) {
            previewCard
            errorBanner
            metadata
            actions
        }
        .padding(24)
        .frame(maxWidth: 560)
        .adaptiveGlassSurface(.roundedRectangle(24))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .sheet(isPresented: $showLogSheet) {
            DiagnosticLogSheet(title: origin.title, log: fullDiagnosticText, tint: currentSeverityTint)
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
    /// — the friendly summary lives in `errorBanner` below, the full log in the
    /// diagnostic window.
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

    /// Compact, glass-tinted failure summary shown only on `.error`. The verbose
    /// renderer log stays out of the card (it lives in the log window opened via
    /// the "Log" button), so failing a scene barely shifts the layout.
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

    /// Severity tint for the log window's chrome — red/orange on failure, a
    /// neutral accent otherwise.
    private var currentSeverityTint: Color {
        if case .error(let reason) = state {
            return severityColor(for: reason)
        }
        return .accentColor
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
            HStack(spacing: 4) {
                workshopIDLabel
                Text("· capability: \(descriptor.capabilityTier.localizedLabel)", comment: "Scene metadata capability suffix. The placeholder is the capability tier.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button {
                    showLogSheet = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Open renderer diagnostics"))
                .accessibilityLabel(Text("Open renderer diagnostics"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                showLogSheet = true
            } label: {
                Label("Renderer Diagnostics", systemImage: "info.circle")
            }
        }
    }

    /// Workshop ID. For a numeric Steam item it's an actionable link: when the
    /// in-app Workshop pane is available it offers both "Find in Workshop"
    /// (jumps to Browse Online scoped to this item) and "Open Steam Page";
    /// otherwise it's a plain web link. Locally-imported projects whose ID isn't
    /// a Steam item render as plain text.
    @ViewBuilder
    private var workshopIDLabel: some View {
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
                    workshopIDText.foregroundStyle(Color.accentColor)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(Text("Find this item in the Workshop, or open its Steam page"))
                .accessibilityLabel(Text("Workshop ID \(origin.workshopID). Find in Workshop or open the Steam page.", comment: "A11y label for the Workshop ID menu. The placeholder is the numeric Workshop ID."))
            } else {
                workshopIDWebLink(url)
            }
            #else
            workshopIDWebLink(url)
            #endif
        } else {
            workshopIDText.foregroundStyle(.secondary)
        }
    }

    /// The bare "Workshop ID 12345" caption, shared by every rendering branch.
    private var workshopIDText: Text {
        Text("Workshop ID \(origin.workshopID)", comment: "Scene metadata Workshop ID. The placeholder is the Workshop ID.")
            .font(.caption)
    }

    /// Plain web link to the Steam Workshop page (used when the in-app Workshop
    /// pane isn't available in this build).
    private func workshopIDWebLink(_ url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            workshopIDText.foregroundStyle(Color.accentColor)
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

    #if DEBUG
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

// MARK: - Diagnostic log window

/// Resizable glass-terminal window for the complete diagnostic log. Glass base,
/// a severity-tinted header, and per-line syntax colouring (errors red, warnings
/// orange, misses yellow, successes green) over a selectable monospaced body —
/// matching the app's liquid-glass language without dropping into a plain sheet.
@MainActor
private struct DiagnosticLogSheet: View {
    let title: String
    let log: String
    let tint: Color

    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false
    /// Colourised log, built once when the window appears. Caching avoids
    /// rebuilding the whole AttributedString on every body refresh (e.g. the
    /// `didCopy` toggle) — important for long logs.
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
            .tint(didCopy ? .green : tint)
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
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .background(Color.black.opacity(0.8))
    }

    /// Builds one selectable `AttributedString` (so copy/selection still spans
    /// the whole log) with each line tinted by its severity keyword. Computed
    /// once per window via `rendered`.
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
