import AppKit
import SpriteKit
import SwiftUI

/// Phase 2.0 scene detail card. Drives the loading/playing/paused/error state
/// machine on top of the SKView the wallpaper session already mounted into
/// the desktop window. The inspector reuses the same `SceneRenderingController`
/// instance so the preview seen here is byte-identical to the live wallpaper.
@MainActor
struct WPESceneDetailView: View {
    let origin: WPEOrigin
    let descriptor: SceneDescriptor
    let session: SceneWallpaperSession?
    let onClearWallpaper: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var state: SceneRenderState = .idle
    /// Hidden developer disclosure toggled by Option-click on the metadata
    /// row. Surfaces capability tier + first failure diagnostic so power
    /// users can see *why* a layer was skipped without diving into Console.
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
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(origin.title). Scene wallpaper. \(stateAccessibilityText)"))
        .task(id: descriptor.workshopID) {
            await refreshState()
        }
        // Re-evaluate when ReduceMotion flips so a Settings change immediately
        // pauses the preview without waiting for a re-render.
        .onChange(of: reduceMotion) { _, _ in
            Task { @MainActor in await refreshState() }
        }
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in
            // Polling is bounded: only fires while we're still resolving
            // initial state. Once we land in playing/paused/error the timer
            // becomes a no-op (Timer.publish itself can't be cancelled
            // reactively from inside .onReceive without keeping a Cancellable
            // bag, which costs more than the early return).
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
            // The SKView preview never unmounts mid-lifecycle — keeping the
            // SpriteKit pipeline warm avoids a Metal command-buffer thrash
            // when the user toggles ReduceMotion / focus / throttle. Pause
            // is communicated by overlay, not by replacing the SKView.
            switch state {
            case .idle:
                fallbackBackground
                LiquidGlassSpinner()
            case .loading(let progress):
                fallbackBackground
                LiquidGlassSpinner(progressText: progress)
            case .playing(let controller):
                ScenePreviewContainer(controller: controller)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
            case .playingSnapshot(let image):
                MetalSnapshotPreview(image: image)
            case .paused(let reason):
                if let controller = session?.sceneController {
                    ScenePreviewContainer(controller: controller)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay(pausedOverlay(reason: reason))
                } else if let image = session?.sceneRenderer?.previewSnapshot {
                    MetalSnapshotPreview(image: image)
                        .overlay(pausedOverlay(reason: reason))
                } else {
                    fallbackBackground
                        .overlay(pausedOverlay(reason: reason))
                }
            case .error(let fallbackReason):
                fallbackBackground
                    .overlay(errorOverlay(reason: fallbackReason))
            }
        }
        // Use opacity-only transitions: `.scale` would animate the size of
        // the NSViewRepresentable host (`ScenePreviewContainer` /
        // `WPEPreviewView`), which triggers an AppKit Auto-Layout cycle in
        // the host window pass.
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: stateKey)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 260)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func pausedOverlay(reason: PausedReason) -> some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 8) {
                Image(systemName: "pause.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.85))
                Text(reason.label)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
        }
        .allowsHitTesting(false)
    }

    private func errorOverlay(reason: FallbackReason) -> some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.yellow)
                Text(errorTitle(for: reason))
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(errorBody(for: reason))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
    }

    /// Inline copy that avoids nesting a full `WPEFallbackCard` (with its
    /// own glass background) inside this card. Mirrors the WPEFallbackCard
    /// strings so users see consistent language across surfaces.
    private func errorTitle(for reason: FallbackReason) -> String {
        switch reason {
        case .unsupportedType:        return "Scene format not supported"
        case .sceneParseFailed:       return "Couldn't read scene.json"
        case .sceneShaderUnsupported: return "Scene uses unsupported shaders"
        case .sceneResourceMissing:   return "Some scene assets are missing"
        case .missingDependency(let ids):
            return "Missing \(ids.count) Workshop \(ids.count == 1 ? "dependency" : "dependencies")"
        case .requiresWindowsPlugin:  return "Windows plugin required"
        case .texContainerUnsupported: return "Unknown texture container"
        case .texUnsupportedFormat:    return "Texture format not supported"
        case .texDecodeFailed:         return "Texture decode failed"
        }
    }

    private func errorBody(for reason: FallbackReason) -> String {
        switch reason {
        case .unsupportedType:
            return "We can't render this scene's feature set yet."
        case .sceneParseFailed(let detail):
            return detail
        case .sceneShaderUnsupported:
            return "Phase 2.0 ships an image-only renderer."
        case .sceneResourceMissing:
            return "Image layers couldn't be located inside the cache."
        case .missingDependency(let ids):
            // Cap visible IDs so a composite scene with many deps doesn't
            // explode the inline overlay; the full list is still rendered
            // by `WPEFallbackCard` when the user navigates to the error.
            if ids.count <= 2 {
                return "Subscribe to \(ids.joined(separator: ", ")) in Steam, then re-import."
            }
            let head = ids.prefix(2).joined(separator: ", ")
            return "Subscribe to \(head) and \(ids.count - 2) more in Steam, then re-import."
        case .requiresWindowsPlugin:
            return "macOS can't load Windows native plugins."
        case .texContainerUnsupported(let magic):
            return "Container \(magic) — Phase 2.x will add it."
        case .texUnsupportedFormat(let code):
            return "Format \(code) — not yet decoded."
        case .texDecodeFailed(let detail):
            return detail
        }
    }

    private var fallbackBackground: some View {
        WPEPreviewView(
            imageURL: previewURL,
            securityScopedBookmarkData: origin.sourceFolderBookmark
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .blur(radius: state.isLoading ? 6 : 0)
        .overlay(Color.black.opacity(state.isLoading ? 0.35 : 0.0))
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(origin.title)
                    .font(.title3.bold())
                Spacer()
                statusPill
            }
            HStack(spacing: 6) {
                Text("Workshop ID \(origin.workshopID) · capability: \(descriptor.capabilityTier.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Tiny info glyph hints that there's a developer panel
                // hiding under Option-click. Without this affordance the
                // panel was completely undiscoverable (gemini audit).
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(Text("Option-click for renderer diagnostics"))
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Option-click toggles the hidden developer diagnostic panel. We
        // attach the gesture to the metadata row (rather than the whole
        // card) so retry / clear buttons aren't intercepted. SwiftUI for
        // macOS doesn't expose a typed modifier-aware tap gesture, so
        // we sniff `NSEvent.modifierFlags` at click time — plain clicks
        // become a no-op and only Option-clicks toggle the panel.
        .onTapGesture {
            guard NSEvent.modifierFlags.contains(.option) else { return }
            withAnimation(DesignTokens.motion(reduceMotion, .spring(response: 0.35, dampingFraction: 0.85))) {
                showDiagnostics.toggle()
            }
        }
    }

    @ViewBuilder
    private var diagnosticsPanel: some View {
        // Build the VoiceOver label up-front so the panel announces both
        // the title AND the active diagnostic in one pass — the previous
        // implementation overrode `accessibilityLabel` on the parent and
        // hid the error text from screen readers entirely (gemini audit).
        let diagnosticText = session?.sceneRenderer?.loadDiagnostics?.errorDescription
            ?? "All declared layers decoded cleanly."
        VStack(alignment: .leading, spacing: 6) {
            Text("Renderer Diagnostics")
                .font(.caption.bold())
            Text("Capability: \(descriptor.capabilityTier.rawValue) · Phase 2.1")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(diagnosticText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Renderer diagnostics: capability \(descriptor.capabilityTier.rawValue). \(diagnosticText)"))
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(stateLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var actions: some View {
        // Apple HIG: destructive "Clear" sits leading; the constructive
        // recovery action ("Retry") sits trailing and gets prominent
        // styling so the recommended path is visually obvious. Without
        // this swap, an Option-button-mash could land on the destructive
        // button by accident.
        HStack(spacing: 12) {
            Button(role: .destructive) {
                onClearWallpaper()
            } label: {
                Label("Clear Scene", systemImage: "xmark.circle")
            }
            .buttonStyle(.glass)
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
        // Drive the runtime profile from the same env signals the state
        // machine consults — this is the single point where ReduceMotion
        // / throttle propagate down to the controller. `applyPerformanceProfile`
        // is idempotent so re-issuing the current profile every poll is cheap.
        renderer.applyPerformanceProfile(reduceMotion ? .suspended : .quality)
        if reduceMotion || session.isThrottled {
            state = .paused(reason: reduceMotion ? .reduceMotion : .throttled)
            return
        }
        if let controller = session.sceneController {
            state = .playing(controller)
            return
        }
        // Phase 2B Task 5: Metal backend has a CGImage readback once load
        // completes. Surface it as `.playingSnapshot` so the view shows the
        // actual rendered scene instead of the static preview-unavailable
        // card; only fall back to `.previewUnavailable` if the snapshot
        // pipeline somehow returned nil (offscreen-only fixtures).
        if let snapshot = renderer.previewSnapshot {
            state = .playingSnapshot(snapshot)
            return
        }
        state = .paused(reason: .previewUnavailable)
    }

    private func mapToFallbackReason(_ error: SceneRenderingError) -> FallbackReason {
        switch error {
        case .cacheRootMissing, .entryFileMissing:
            return .sceneResourceMissing
        case .parseFailed(let detail):
            return .sceneParseFailed(detail)
        case .unsupportedShader:
            return .sceneShaderUnsupported
        case .noRenderableObjects:
            return .sceneResourceMissing
        case .resourceFailed(let diagnostic):
            return Self.fallbackReason(for: diagnostic)
        }
    }

    /// Maps the most-specific per-layer failure into the corresponding
    /// FallbackReason. Phase 2.1 surfaces .tex container/format errors with
    /// their precise codes so the user understands why a layer was skipped.
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
        // Lightweight state-change fingerprint for animation triggers; the
        // associated values (controller / fallback) compare poorly so we
        // map down to ints.
        switch state {
        case .idle:            return 0
        case .loading:         return 1
        case .playing:         return 2
        case .playingSnapshot: return 2
        case .paused:          return 3
        case .error:           return 4
        }
    }

    private var stateLabel: String {
        switch state {
        case .idle:            return "Idle"
        case .loading:         return "Loading"
        case .playing:         return "Playing"
        // Phase 2B: the Metal experimental backend renders one frame at
        // load and pauses the displaylink, so the detail card shows a
        // static thumbnail. Surface that explicitly so the user does not
        // mistake a frozen frame for a hung renderer.
        case .playingSnapshot: return "Static Preview"
        case .paused:          return "Paused"
        case .error:           return "Error"
        }
    }

    private var stateAccessibilityText: String {
        switch state {
        case .idle:            return "Idle"
        case .loading:         return "Loading scene assets"
        case .playing:         return "Scene playing"
        case .playingSnapshot: return "Scene preview, static"
        case .paused(let reason): return "Paused, \(reason.label)"
        case .error:           return "Scene cannot be played"
        }
    }

    private var statusColor: Color {
        switch state {
        case .playing:         return .green
        // Distinguish the Metal static preview with a blue pill — green
        // would imply "live" which is misleading until the per-frame
        // readback timer ships in Phase 2C.
        case .playingSnapshot: return .blue
        case .loading:         return .yellow
        case .paused:          return .orange
        case .error:           return .red
        case .idle:            return .secondary
        }
    }

    private var previewURL: URL? {
        guard let previewName = origin.previewFileName else { return nil }
        var isStale = false
        guard let folder = try? URL(
            resolvingBookmarkData: origin.sourceFolderBookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return folder.appendingPathComponent(previewName)
    }
}

// MARK: - State machine

enum SceneRenderState: Equatable {
    case idle
    case loading(progress: String?)
    case playing(SceneRenderingController)
    /// Phase 2B Task 5: Metal-backed scene with a CGImage readback. The
    /// SpriteKit live preview path stays on `.playing(controller)` because
    /// `SKView` runs its own runloop; this case lets the detail view show
    /// a static thumbnail for the Metal backend instead of falling through
    /// to `.previewUnavailable`.
    case playingSnapshot(NSImage)
    case paused(reason: PausedReason)
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
        case (.playing(let lhsCtrl), .playing(let rhsCtrl)): return lhsCtrl === rhsCtrl
        case (.playingSnapshot(let l), .playingSnapshot(let r)): return l === r
        case (.paused(let l), .paused(let r)): return l == r
        case (.error(let l), .error(let r)): return l == r
        default: return false
        }
    }
}

enum PausedReason: Equatable, Sendable {
    case reduceMotion
    case throttled
    case suspended
    case previewUnavailable

    var label: String {
        switch self {
        case .reduceMotion: return "Reduce Motion"
        case .throttled:    return "Throttled"
        case .suspended:    return "Suspended"
        case .previewUnavailable: return "Preview Unavailable"
        }
    }
}

// MARK: - Metal snapshot preview

/// Static thumbnail for the Metal scene backend per the UX & Frontend Spec
/// in `2026-05-05-wpe-phase2b-scene-runtime-hardening.md` §1. Honours the
/// rendered texture's intrinsic aspect ratio (orthogonal projections are
/// often square or portrait) and letterboxes inside the controlBackground
/// fill so the card chrome stays consistent with the SpriteKit path.
@MainActor
private struct MetalSnapshotPreview: View {
    let image: NSImage

    var body: some View {
        // Phase 2B Task 5 ships a one-shot static snapshot — no
        // `.updatesFrequently` trait until the per-frame readback timer
        // (Phase 2C) makes the image actually animate, otherwise VoiceOver
        // would announce stale "updates" on a frozen frame.
        Image(nsImage: image)
            .resizable()
            .interpolation(.medium)
            .aspectRatio(contentMode: .fit)
            .background(Color(nsColor: .controlBackgroundColor))
            .accessibilityLabel(Text("Scene preview snapshot"))
            .transition(.opacity)
    }
}
