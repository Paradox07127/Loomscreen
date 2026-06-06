#if !LITE_BUILD && DIRECT_DISTRIBUTION
import LiveWallpaperSharedUI
import Observation
import SwiftUI

/// Whether an `AnimatedGIFThumbnail` plays on hover (grid / list idiom) or
/// auto-plays (single-item detail surfaces).
enum GIFPlaybackMode {
    case hoverToPlay
    case autoPlay
}

/// A Workshop preview tile that shows a static poster by default and plays the
/// underlying GIF/APNG only while hovered (`.hoverToPlay`) or immediately for
/// focused detail surfaces (`.autoPlay`). Matches the macOS Photos / Quick Look
/// idiom: no grid of 20 simultaneously animating tiles.
struct AnimatedGIFThumbnail: View {
    let url: URL?
    var playbackMode: GIFPlaybackMode = .hoverToPlay
    /// When true the poster is heavily blurred behind a "click to reveal" cover
    /// and playback is suppressed — the adult-content spoiler gate. Flipping it
    /// back to false (the parent's reveal) resumes normal hover/auto playback.
    var isBlurred: Bool = false
    @Binding var isHovered: Bool

    @State private var controller = GIFAnimationController()
    @State private var phase: LoadPhase = .loading
    @State private var isVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.controlActiveState) private var controlActiveState

    private enum LoadPhase { case loading, ready, failed, empty }

    private var playbackGate: ThumbnailPlaybackGate {
        ThumbnailPlaybackGate(
            isVisible: isVisible,
            isHovered: isHovered,
            isFocused: controlActiveState != .inactive,
            scenePhase: scenePhase,
            reduceMotion: reduceMotion,
            isBlurred: isBlurred,
            trigger: playbackMode == .hoverToPlay ? .hover : .focus
        )
    }

    init(
        url: URL?,
        playbackMode: GIFPlaybackMode = .hoverToPlay,
        isBlurred: Bool = false,
        isHovered: Binding<Bool> = .constant(false)
    ) {
        self.url = url
        self.playbackMode = playbackMode
        self.isBlurred = isBlurred
        self._isHovered = isHovered
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            content
                .blur(radius: isBlurred ? 26 : 0)
            if isBlurred {
                matureCover
            }
        }
        // Bottom-leading so it never collides with the top-leading rating pill
        // the grid card overlays on the same tile.
        .overlay(alignment: .bottomLeading) {
            if controller.isAnimating, !isBlurred {
                playingBadge
                    .padding(DesignTokens.Spacing.sm)
                    .transition(.opacity)
            }
        }
        .animation(DesignTokens.motion(reduceMotion, .easeInOut(duration: 0.15)), value: controller.isAnimating)
        .clipped()
        .task(id: url) { await load() }
        .onAppear {
            isVisible = true
            applyPlaybackGate()
        }
        .onChange(of: playbackGate) { _, _ in applyPlaybackGate() }
        .onDisappear {
            isVisible = false
            controller.stop()
        }
    }

    /// Spoiler scrim shown over a blurred adult thumbnail. The eye glyph + label
    /// double as the "this is mature content" warning; tapping the tile (handled
    /// by the parent) reveals it.
    private var matureCover: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 5) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 22, weight: .semibold))
                Text("Mature", comment: "Spoiler cover over an adult-rated Workshop thumbnail.")
                    .font(DesignTokens.Typography.captionEmphasized)
                Text("Click to reveal", comment: "Hint on the spoiler cover over an adult-rated Workshop thumbnail.")
                    .font(DesignTokens.Typography.badge)
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Mature content hidden. Activate to reveal."))
    }

    @ViewBuilder
    private var content: some View {
        if let frame = controller.displayedFrame {
            Image(decorative: frame, scale: 1)
                .resizable()
                .interpolation(.medium)
                .scaledToFill()
                .clipped()
                .accessibilityHidden(true)
        } else if phase == .loading, url != nil {
            // Pure-SwiftUI spinner (not `ProgressView`, whose NSProgressIndicator
            // bridge spams "max length doesn't satisfy min <= max" layout faults
            // when 50 tiles load at fractional grid widths).
            LiquidGlassSpinner(size: 20, lineWidth: 2, tint: .secondary)
                .opacity(0.7)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "cube.transparent")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    private var playingBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .bold))
            Text("Playing", comment: "Badge on a Workshop thumbnail while its animated preview is playing.")
                .font(DesignTokens.Typography.badge)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .thumbnailBadgeGlass(tint: .black, opacity: 0.7)
        .accessibilityHidden(true)
    }

    private func load() async {
        controller.stop(resetToPoster: false)
        guard let url else {
            controller.setAsset(nil)
            phase = .empty
            return
        }
        phase = .loading
        let asset = await WorkshopPreviewImageLoader.shared.loadAsset(url)
        guard !Task.isCancelled else { return }
        controller.setAsset(asset)
        phase = asset == nil ? .failed : .ready
        guard asset != nil else { return }
        applyPlaybackGate()
    }

    /// Single source of truth for playback: the gate decides, the controller
    /// obeys. Grid tiles debounce + auto-stop; focused detail heroes run while
    /// the gate holds.
    private func applyPlaybackGate() {
        guard GIFPlaybackCoordinator.shared.allowsPlayback(playbackGate) else {
            controller.stop()
            return
        }
        let isGrid = playbackMode == .hoverToPlay
        controller.play(
            debounced: isGrid,
            maximumDuration: isGrid ? ThumbnailPlaybackGate.hoverPreviewMaximumDuration : nil,
            maximumLoops: isGrid ? ThumbnailPlaybackGate.hoverPreviewMaximumLoops : nil
        )
    }
}

/// Owns the frame-stepping state for one thumbnail. A reference type (rather
/// than view `@State`) so the playback `Task` and the coordinator's eviction
/// closure can capture it weakly and mutate it safely from outside the SwiftUI
/// update pass.
@MainActor
@Observable
final class GIFAnimationController {
    private(set) var displayedFrame: CGImage?
    private(set) var isAnimating = false

    private let clientID = UUID()
    private var asset: WorkshopPreviewAsset?
    private var playbackTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    /// Installs a new asset, resetting any in-flight playback to its poster.
    func setAsset(_ asset: WorkshopPreviewAsset?) {
        stop(resetToPoster: false)
        self.asset = asset
        displayedFrame = asset?.posterFrame
    }

    /// Starts playback for the current animated asset. `debounced` adds a short
    /// hover delay (250 ms) so a rapid mouse sweep across a grid doesn't thrash
    /// the decoder; hover-exit during the window cancels before any frame decodes.
    func play(debounced: Bool, maximumDuration: TimeInterval? = nil, maximumLoops: Int? = nil) {
        guard case .animatedGIF = asset, playbackTask == nil else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            if debounced {
                try? await Task.sleep(nanoseconds: ThumbnailPlaybackGate.hoverPreviewDelayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            self?.beginPlayback(maximumDuration: maximumDuration, maximumLoops: maximumLoops)
        }
    }

    /// Stops playback. Restores the poster frame instantly unless suppressed
    /// (e.g. on disappear, where there is nothing left to show).
    func stop(resetToPoster: Bool = true) {
        debounceTask?.cancel()
        debounceTask = nil
        let wasRegistered = isAnimating || playbackTask != nil
        playbackTask?.cancel()
        playbackTask = nil
        isAnimating = false
        if wasRegistered {
            GIFPlaybackCoordinator.shared.endPlayback(id: clientID)
        }
        if resetToPoster {
            displayedFrame = asset?.posterFrame
        }
    }

    private func beginPlayback(maximumDuration: TimeInterval? = nil, maximumLoops: Int? = nil) {
        guard case .animatedGIF(let gif) = asset, playbackTask == nil else { return }
        let id = clientID
        GIFPlaybackCoordinator.shared.requestPlayback(id: id) { [weak self] in
            self?.stop()
        }
        isAnimating = true
        playbackTask = Task { [weak self] in
            var index = 0
            var elapsed: TimeInterval = 0
            var completedLoops = 0
            while !Task.isCancelled {
                let delay = index < gif.frameDelays.count ? gif.frameDelays[index] : 0.1
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { break }
                elapsed += delay
                index = (index + 1) % gif.frameCount
                let frame = await GIFAnimationController.decode(gif, at: index)
                guard !Task.isCancelled else { break }
                if let frame { self?.displayedFrame = frame }
                if index == 0 { completedLoops += 1 }
                if let maximumLoops, completedLoops >= maximumLoops {
                    self?.stop()
                    break
                }
                if let maximumDuration, elapsed >= maximumDuration {
                    self?.stop()
                    break
                }
            }
        }
    }

    /// Non-poster frames decode off the main actor — `CGImageSourceCreateImageAtIndex`
    /// is free-threaded, and this keeps heavy decodes off the render loop.
    private static func decode(_ gif: WorkshopAnimatedGIF, at index: Int) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            gif.frame(at: index)
        }.value
    }
}
#endif
