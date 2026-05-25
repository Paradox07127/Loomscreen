#if !LITE_BUILD
import Accelerate
import AVFoundation
import Foundation

/// Per-scene audio runtime. Plays every declared sound object via
/// `AVAudioEngine`, taps the main mixer output, and computes a 64-bin
/// FFT spectrum that the Metal renderer reads each frame to feed
/// audio-reactive shader uniforms (`g_AudioSpectrum*`).
///
/// Lifecycle:
///   - `start()` resolves each sound file relative to the scene cache,
///     attaches a player node + buffer per file, configures looping
///     playback at the per-object volume, and installs the FFT tap.
///   - `currentSpectrum` returns the latest 64-bin power spectrum
///     (normalized 0…1, low frequency → high). Defaults to silence
///     before the engine produces samples.
///   - `stop()` halts the engine and removes the tap.
final class WPESoundRuntime: @unchecked Sendable {
    /// FFT window size (must be a power of two). 2048 samples at
    /// 44.1 kHz → ≈47 ms latency between FFT updates which is well
    /// below the 60 fps render cadence.
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

    /// Boot the engine.
    func start(sounds: [WPESceneSoundObject]) -> Int {
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

        do {
            try engine.start()
        } catch {
            mainMixer.removeTap(onBus: 0)
            return 0
        }

        for player in players {
            player.play()
        }
        return attached
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

    /// Compress the half-spectrum into 64 perceptual bins by averaging adjacent values, then normalize to 0…1 on a log scale so the range matches what audio-reactive shaders expect.
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
