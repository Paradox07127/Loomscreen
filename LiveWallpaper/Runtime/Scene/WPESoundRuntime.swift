#if !LITE_BUILD
import Accelerate
import AVFoundation
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

/// Per-scene audio runtime. Plays every declared sound object via
/// `AVAudioEngine`, taps the main mixer output, and computes a 64-bin
/// FFT spectrum that the Metal renderer reads each frame to feed
/// audio-reactive shader uniforms (`g_AudioSpectrum*`).
final class WPESoundRuntime: @unchecked Sendable {
    /// Must be a power of two. 2048 samples at 44.1 kHz → ≈47 ms latency
    /// between FFT updates, well below the 60 fps render cadence.
    static let fftSize = 2048
    static let binCount = 64

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var buffers: [AVAudioPCMBuffer] = []
    /// Per-player scene-declared `sound.volume` from scene.json. Kept so
    /// `applyAudioState` can rebuild each node's final volume as
    /// `sceneVolume × masterVolume` instead of overwriting the scene value.
    private var sceneVolumes: [Float] = []
    private var masterVolume: Float = 1.0
    private var isMuted: Bool = false
    private let resolver: WPEMultiRootResourceResolver
    /// Lock-protected so the audio render thread (tap) and the Metal
    /// render thread (spectrum read) don't race.
    private let spectrumLock = NSLock()
    private var latestSpectrum: [Double] = [Double](repeating: 0, count: WPESoundRuntime.binCount)

    private let fftSetup: vDSP.FFT<DSPSplitComplex>?
    private var window: [Float]
    private var realBuffer: [Float]
    private var imagBuffer: [Float]

    init(resolver: WPEMultiRootResourceResolver) {
        self.resolver = resolver
        let log2n = vDSP_Length(log2(Double(Self.fftSize)))
        self.fftSetup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
        var w = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&w, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        self.window = w
        self.realBuffer = [Float](repeating: 0, count: Self.fftSize / 2)
        self.imagBuffer = [Float](repeating: 0, count: Self.fftSize / 2)
    }

    /// `prepare` + `play` in one call. The renderer splits the two so the
    /// expensive `prepare` runs off the main actor and `play` only happens
    /// once the scene is confirmed current.
    @discardableResult
    func start(sounds: [WPESceneSoundObject]) -> Int {
        let attached = prepare(sounds: sounds)
        play()
        return attached
    }

    /// Resolve + decode the sound files and wire up the engine WITHOUT starting
    /// playback. This is the expensive part (file I/O + PCM buffer load,
    /// ~300-900ms) and is safe to run off the main actor; nothing is audible
    /// until `play()`. Returns the number of attached players.
    @discardableResult
    func prepare(sounds: [WPESceneSoundObject]) -> Int {
        let mainMixer = engine.mainMixerNode
        let outputFormat = mainMixer.outputFormat(forBus: 0)

        var attached = 0
        for sound in sounds where !sound.startSilent {
            for path in sound.soundRelativePaths {
                guard let url = try? resolver.resolveExistingFileURL(relativePath: path) else { continue }
                guard let file = try? AVAudioFile(forReading: url) else { continue }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { continue }
                do {
                    try file.read(into: buffer)
                } catch {
                    continue
                }
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: mainMixer, format: file.processingFormat)
                let sceneVolume = Float(sound.volume)
                player.volume = effectiveVolume(sceneVolume: sceneVolume)
                player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
                players.append(player)
                buffers.append(buffer)
                sceneVolumes.append(sceneVolume)
                attached += 1
                break
            }
        }

        let bufferSize = AVAudioFrameCount(Self.fftSize)
        mainMixer.installTap(onBus: 0, bufferSize: bufferSize, format: outputFormat) { [weak self] buffer, _ in
            self?.processTap(buffer: buffer)
        }
        engine.prepare()
        return attached
    }

    /// Start the engine and begin looping playback. Fast — call only after the
    /// caller has confirmed the scene is still current. No-op-safe when nothing
    /// was prepared. Returns false (and removes the tap) if the engine won't start.
    @discardableResult
    func play() -> Bool {
        guard !players.isEmpty else { return false }
        do {
            try engine.start()
        } catch {
            // Keep the (already-installed, still-valid) FFT tap so a later
            // resume() can recover audio-reactive data — the callback can't fire
            // while the engine is stopped anyway.
            Logger.warning("WPESoundRuntime play: engine.start() failed: \(error.localizedDescription)", category: .wpeRender)
            return false
        }
        for player in players {
            player.play()
        }
        return true
    }

    func stop() {
        engine.mainMixerNode.removeTap(onBus: 0)
        for player in players {
            player.stop()
        }
        engine.stop()
        players.removeAll(keepingCapacity: false)
        buffers.removeAll(keepingCapacity: false)
        sceneVolumes.removeAll(keepingCapacity: false)
    }

    /// Suspend playback without discarding the prepared players/buffers/tap.
    /// Unlike `stop()` (which tears the graph down and needs a full re-decode
    /// to come back), this just halts the engine so a paused wallpaper costs no
    /// audio CPU — the FFT tap stops firing — while the loaded PCM stays
    /// resident for an instant `resume()`. Used by the `.suspended` profile.
    func pause() {
        guard engine.isRunning else { return }
        engine.pause()
    }

    /// Start (or resume) looping playback for already-prepared players. Handles
    /// both cases the renderer needs:
    ///   - resuming after `pause()` (engine paused, players still "playing"), and
    ///   - starting a runtime that was `prepare`-d while suspended and never
    ///     `play()`-ed (engine stopped, players idle).
    /// No-op when nothing was prepared. On engine-start failure the tap is left
    /// intact (it's still valid) so a later retry can recover audio-reactive FFT.
    func resume() {
        guard !players.isEmpty else { return }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                Logger.warning("WPESoundRuntime resume: engine.start() failed: \(error.localizedDescription)", category: .wpeRender)
                return
            }
        }
        for player in players where !player.isPlaying {
            player.play()
        }
    }

    /// Master mute applied on top of the scene-declared per-sound volume.
    /// `applyAudioState` rebuilds each player's `.volume` so subsequent
    /// `setMasterVolume(_:)` calls keep the scene mix intact.
    func setMuted(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted
        applyAudioState()
    }

    /// `[0, 1]` master gain multiplied into every scene-declared
    /// `sound.volume`. Out-of-range values are clamped.
    func setMasterVolume(_ volume: Double) {
        let clamped = Float(min(max(volume, 0), 1))
        guard abs(masterVolume - clamped) > 0.001 else { return }
        masterVolume = clamped
        applyAudioState()
    }

    private func applyAudioState() {
        for (index, player) in players.enumerated() {
            let sceneVolume = index < sceneVolumes.count ? sceneVolumes[index] : 1.0
            player.volume = effectiveVolume(sceneVolume: sceneVolume)
        }
    }

    private func effectiveVolume(sceneVolume: Float) -> Float {
        guard !isMuted else { return 0 }
        return max(0, min(1, sceneVolume * masterVolume))
    }

    /// Snapshot of the latest 64-bin spectrum. Safe to call from any
    /// thread; protected by an internal lock.
    var currentSpectrum: [Double] {
        spectrumLock.lock()
        defer { spectrumLock.unlock() }
        return latestSpectrum
    }

    private func processTap(buffer: AVAudioPCMBuffer) {
        guard let fftSetup else { return }
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength >= Self.fftSize else { return }

        var mono = [Float](repeating: 0, count: Self.fftSize)
        let channelCount = Int(buffer.format.channelCount)
        for ch in 0..<channelCount {
            let pointer = channelData[ch]
            for i in 0..<Self.fftSize {
                mono[i] += pointer[i]
            }
        }
        if channelCount > 1 {
            let inv = 1.0 / Float(channelCount)
            for i in 0..<Self.fftSize { mono[i] *= inv }
        }

        vDSP.multiply(mono, window, result: &mono)

        var real = realBuffer
        var imag = imagBuffer
        mono.withUnsafeBufferPointer { monoBuf in
            monoBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.fftSize / 2) { complexPointer in
                real.withUnsafeMutableBufferPointer { rBuf in
                    imag.withUnsafeMutableBufferPointer { iBuf in
                        var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                        vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                        fftSetup.forward(input: split, output: &split)
                        var magnitudes = [Float](repeating: 0, count: Self.fftSize / 2)
                        vDSP.absolute(split, result: &magnitudes)
                        publishSpectrum(magnitudes: magnitudes)
                    }
                }
            }
        }
    }

    /// Normalizes to 0…1 on a log scale so the range matches what
    /// audio-reactive shaders expect.
    private func publishSpectrum(magnitudes: [Float]) {
        let inputBins = magnitudes.count
        let groupSize = max(1, inputBins / Self.binCount)
        var spectrum = [Double](repeating: 0, count: Self.binCount)
        for i in 0..<Self.binCount {
            let start = i * groupSize
            let end = min(start + groupSize, inputBins)
            guard start < end else { continue }
            var sum: Float = 0
            for j in start..<end { sum += magnitudes[j] }
            let mean = sum / Float(end - start)
            let normalized = max(0, min(Double(log10(max(mean, 1e-6)) / 6.0 + 1.0), 1.0))
            spectrum[i] = normalized
        }
        spectrumLock.lock()
        latestSpectrum = spectrum
        spectrumLock.unlock()
    }
}
#endif
