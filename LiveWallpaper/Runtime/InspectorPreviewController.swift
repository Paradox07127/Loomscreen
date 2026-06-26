import AppKit
@preconcurrency import AVFoundation
import Combine
import Observation

@MainActor @Observable
final class InspectorPreviewController {
    private(set) var player: AVPlayer?
    private(set) var posterImage: NSImage?
    private(set) var isLoading = false
    private(set) var isPlaying = false
    private(set) var currentPosition: Double = 0
    private(set) var duration: Double = 1
    private(set) var lastError: String?
    /// Last URL handed to `loadPoster`/`startPlaybackPreview`. Lets the info
    /// overlay load asset metadata before — or instead of — the player coming
    /// up, so it can show on the poster / unloaded states.
    private(set) var assetURL: URL?

    @ObservationIgnored private var playerObserver: AnyCancellable?
    @ObservationIgnored private var itemStatusObserver: AnyCancellable?
    @ObservationIgnored private var positionTask: Task<Void, Never>?
    @ObservationIgnored private var posterTask: Task<Void, Never>?
    @ObservationIgnored private var securityScopedURL: URL?

    var hasPreviewContent: Bool {
        player != nil || posterImage != nil
    }

    deinit {
        // Backstop for owners that drop the controller without calling
        // `cleanup()`, else the 500 ms position-poll task loops forever.
        positionTask?.cancel()
        posterTask?.cancel()
    }

    func loadPoster(from url: URL, syncTime: CMTime? = nil) {
        guard player == nil else { return }

        assetURL = url
        posterTask?.cancel()
        isLoading = true
        lastError = nil

        let targetTime: CMTime
        if let syncTime, syncTime.isValid, !syncTime.seconds.isNaN {
            targetTime = syncTime
        } else {
            targetTime = .zero
        }

        posterTask = Task { [weak self] in
            let didStartScope = url.startAccessingSecurityScopedResource()
            defer {
                if didStartScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

                let loadedDuration = try? await asset.load(.duration)
                let (cgImage, actualTime) = try await generator.image(at: targetTime)

                guard !Task.isCancelled else { return }

                self?.posterImage = NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                )
                self?.currentPosition = Self.validSeconds(actualTime.seconds, fallback: 0)
                self?.duration = Self.validSeconds(loadedDuration?.seconds, fallback: 1)
                self?.isLoading = false
            } catch is CancellationError {
                self?.isLoading = false
            } catch {
                self?.lastError = error.localizedDescription
                self?.posterImage = nil
                self?.isLoading = false
            }
        }
    }

    func startPlaybackPreview(from url: URL, syncTo wallpaperPlayer: AVPlayer?) {
        cleanupPlayer()
        posterTask?.cancel()
        assetURL = url
        isLoading = true
        lastError = nil

        retainSecurityScope(for: url)

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 2.0

        let previewPlayer = AVPlayer(playerItem: playerItem)
        previewPlayer.volume = 0
        previewPlayer.isMuted = true
        previewPlayer.automaticallyWaitsToMinimizeStalling = false
        disableAudioTracks(for: playerItem)

        player = previewPlayer
        posterImage = nil
        isLoading = false

        if let wallpaperPlayer {
            sync(to: wallpaperPlayer)
        }

        configureItemStatusObserver(playerItem)
        configurePlayerObserver(previewPlayer)
        startPositionUpdates(for: previewPlayer)
        previewPlayer.play()
        isPlaying = true
    }

    func updateScrubPosition(_ position: Double) {
        currentPosition = min(max(position, 0), max(1, duration))
    }

    func seekToCurrentPosition() {
        player?.seek(to: CMTime(seconds: currentPosition, preferredTimescale: 600))
    }

    func togglePlayback() {
        guard let player else { return }
        if player.rate == 0 {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func cleanup() {
        posterTask?.cancel()
        posterTask = nil
        posterImage = nil
        assetURL = nil
        currentPosition = 0
        duration = 1
        lastError = nil
        cleanupPlayer()
    }

    private func configurePlayerObserver(_ player: AVPlayer) {
        playerObserver = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isPlaying = status == .playing
            }
    }

    private func configureItemStatusObserver(_ playerItem: AVPlayerItem) {
        itemStatusObserver = playerItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak playerItem] status in
                guard status == .failed else { return }
                guard let self else { return }
                self.lastError = playerItem?.error?.localizedDescription ?? "The preview could not be played."
                self.cleanupPlayer()
                self.isLoading = false
            }
    }

    private func startPositionUpdates(for player: AVPlayer) {
        positionTask?.cancel()
        positionTask = Task { [weak self, weak player] in
            while !Task.isCancelled {
                guard let self else { return }
                if let player {
                    let time = player.currentTime().seconds
                    self.currentPosition = Self.validSeconds(time, fallback: self.currentPosition)

                    let itemDuration = player.currentItem?.duration.seconds
                    self.duration = Self.validSeconds(itemDuration, fallback: self.duration)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func sync(to wallpaperPlayer: AVPlayer) {
        let wallpaperTime = wallpaperPlayer.currentTime()
        if wallpaperTime.isValid, !wallpaperTime.seconds.isNaN {
            player?.seek(to: wallpaperTime, toleranceBefore: .zero, toleranceAfter: .zero)
            currentPosition = wallpaperTime.seconds
        }
    }

    private func cleanupPlayer() {
        playerObserver?.cancel()
        playerObserver = nil
        itemStatusObserver?.cancel()
        itemStatusObserver = nil
        positionTask?.cancel()
        positionTask = nil
        player?.pause()
        player = nil
        isPlaying = false
        releaseSecurityScope()
    }

    private func retainSecurityScope(for url: URL) {
        releaseSecurityScope()
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }
    }

    private func releaseSecurityScope() {
        if let securityScopedURL {
            securityScopedURL.stopAccessingSecurityScopedResource()
            self.securityScopedURL = nil
        }
    }

    private func disableAudioTracks(for playerItem: AVPlayerItem) {
        playerItem.tracks
            .filter { $0.assetTrack?.mediaType == .audio }
            .forEach { $0.isEnabled = false }
    }

    private static func validSeconds(_ value: Double?, fallback: Double) -> Double {
        guard let value, !value.isNaN, !value.isInfinite, value > 0 else {
            return fallback
        }
        return value
    }
}
