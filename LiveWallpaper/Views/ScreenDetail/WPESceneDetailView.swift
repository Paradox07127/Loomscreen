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

    var body: some View {
        VStack(spacing: 16) {
            previewCard
            metadata
            actions
        }
        .padding(24)
        .frame(maxWidth: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(origin.title). Scene wallpaper. \(stateAccessibilityText)")
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
            guard state == .idle || state == .loading else { return }
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
            case .idle, .loading:
                fallbackBackground
                LiquidGlassSpinner()
            case .playing(let controller):
                ScenePreviewContainer(controller: controller)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
            case .paused(let reason):
                if let controller = session?.sceneController {
                    ScenePreviewContainer(controller: controller)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
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
        }
    }

    private var fallbackBackground: some View {
        WPEPreviewView(
            imageURL: previewURL,
            securityScopedBookmarkData: origin.sourceFolderBookmark
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .blur(radius: state == .loading ? 6 : 0)
        .overlay(Color.black.opacity(state == .loading ? 0.35 : 0.0))
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(origin.title)
                    .font(.title3.bold())
                Spacer()
                statusPill
            }
            Text("Workshop ID \(origin.workshopID) · capability: \(descriptor.capabilityTier.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        HStack(spacing: 12) {
            Button(role: .destructive) {
                onClearWallpaper()
            } label: {
                Label("Clear Scene", systemImage: "xmark.circle")
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
            .accessibilityHint("Removes the scene wallpaper from this display")

            Spacer()
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
        guard let controller = session.sceneController else {
            state = .idle
            return
        }
        if controller.view.scene == nil {
            state = .loading
            return
        }
        // Drive the runtime profile from the same env signals the state
        // machine consults — this is the single point where ReduceMotion
        // / throttle propagate down to the controller. `applyPerformanceProfile`
        // is idempotent so re-issuing the current profile every poll is cheap.
        controller.applyPerformanceProfile(reduceMotion ? .suspended : .quality)
        if reduceMotion || session.isThrottled {
            state = .paused(reason: reduceMotion ? .reduceMotion : .throttled)
            return
        }
        state = .playing(controller)
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
        }
    }

    private var stateKey: Int {
        // Lightweight state-change fingerprint for animation triggers; the
        // associated values (controller / fallback) compare poorly so we
        // map down to ints.
        switch state {
        case .idle:    return 0
        case .loading: return 1
        case .playing: return 2
        case .paused:  return 3
        case .error:   return 4
        }
    }

    private var stateLabel: String {
        switch state {
        case .idle:    return "Idle"
        case .loading: return "Loading"
        case .playing: return "Playing"
        case .paused:  return "Paused"
        case .error:   return "Error"
        }
    }

    private var stateAccessibilityText: String {
        switch state {
        case .idle:    return "Idle"
        case .loading: return "Loading scene assets"
        case .playing: return "Scene playing"
        case .paused(let reason): return "Paused, \(reason.label)"
        case .error:   return "Scene cannot be played"
        }
    }

    private var statusColor: Color {
        switch state {
        case .playing: return .green
        case .loading: return .yellow
        case .paused:  return .orange
        case .error:   return .red
        case .idle:    return .secondary
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
    case loading
    case playing(SceneRenderingController)
    case paused(reason: PausedReason)
    case error(FallbackReason)

    static func == (lhs: SceneRenderState, rhs: SceneRenderState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.loading, .loading): return true
        case (.playing(let lhsCtrl), .playing(let rhsCtrl)): return lhsCtrl === rhsCtrl
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

    var label: String {
        switch self {
        case .reduceMotion: return "Reduce Motion"
        case .throttled:    return "Throttled"
        case .suspended:    return "Suspended"
        }
    }
}
