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
    @Binding var isHovered: Bool

    @State private var controller = GIFAnimationController()
    @State private var phase: LoadPhase = .loading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum LoadPhase { case loading, ready, failed, empty }

    init(
        url: URL?,
        playbackMode: GIFPlaybackMode = .hoverToPlay,
        isHovered: Binding<Bool> = .constant(false)
    ) {
        self.url = url
        self.playbackMode = playbackMode
        self._isHovered = isHovered
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            content
        }
        .overlay(alignment: .topLeading) {
            if controller.isAnimating {
                playingBadge
                    .padding(DesignTokens.Spacing.sm)
                    .transition(.opacity)
            }
        }
        .animation(DesignTokens.motion(reduceMotion, .easeInOut(duration: 0.15)), value: controller.isAnimating)
        .clipped()
        .task(id: url) { await load() }
        .onChange(of: isHovered) { _, hovering in handleHover(hovering) }
        .onChange(of: reduceMotion) { _, reduce in handleReduceMotion(reduce) }
        .onDisappear { controller.stop(resetToPoster: false) }
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
            ProgressView()
                .controlSize(.small)
                .opacity(0.6)
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
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
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
        guard asset != nil, !reduceMotion else { return }
        // Begin immediately if the surface auto-plays, or if the pointer is
        // already resting on the tile when the load resolves.
        if playbackMode == .autoPlay || isHovered {
            controller.play(debounced: false)
        }
    }

    private func handleHover(_ hovering: Bool) {
        guard playbackMode == .hoverToPlay, !reduceMotion else { return }
        if hovering {
            controller.play(debounced: true)
        } else {
            controller.stop()
        }
    }

    private func handleReduceMotion(_ reduce: Bool) {
        if reduce {
            controller.stop()
        } else if playbackMode == .autoPlay {
            controller.play(debounced: false)
        } else if isHovered {
            controller.play(debounced: true)
        }
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

    /// Starts playback for the current animated asset. `debounced` adds an
    /// 80 ms delay so a rapid mouse sweep across a grid doesn't thrash the
    /// decoder; hover-exit during the window cancels before any frame decodes.
    func play(debounced: Bool) {
        guard case .animatedGIF = asset, playbackTask == nil else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            if debounced {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            guard !Task.isCancelled else { return }
            self?.beginPlayback()
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

    private func beginPlayback() {
        guard case .animatedGIF(let gif) = asset, playbackTask == nil else { return }
        let id = clientID
        GIFPlaybackCoordinator.shared.requestPlayback(id: id) { [weak self] in
            self?.stop()
        }
        isAnimating = true
        playbackTask = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                let delay = index < gif.frameDelays.count ? gif.frameDelays[index] : 0.1
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { break }
                index = (index + 1) % gif.frameCount
                let frame = await GIFAnimationController.decode(gif, at: index)
                guard !Task.isCancelled else { break }
                if let frame { self?.displayedFrame = frame }
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
