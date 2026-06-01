#if !LITE_BUILD
import CoreAudio
import Foundation
import LiveWallpaperCore

/// App-wide system-audio capture engine. Owns ONE Core Audio Process Tap (a
/// global stereo mixdown of every process' output), drives it into a single
/// reusable `AudioSpectrumProcessor`, and publishes 64-bin stereo frames into a
/// shared `AudioSpectrumBroker` that every audio-reactive surface (Metal scene
/// uniforms, WebGL payload, HTML `wallpaperRegisterAudioListener`) reads.
///
/// This is the loopback source that mirrors Wallpaper Engine: the visualizer
/// follows whatever the user is actually playing (Spotify, a game, a browser),
/// not just the wallpaper's own declared sounds. `WPESoundRuntime` is demoted to
/// a pure player and no longer supplies the spectrum.
///
/// Lifecycle (all on the main thread): `start()` builds tap → private aggregate
/// device → IOProc and begins capture; `stop()` tears down in reverse. The
/// IOProc block runs on a dedicated serial queue and is allocation-free in
/// steady state — it deinterleaves into preallocated scratch buffers, runs the
/// FFT, and publishes via the broker's drop-on-contention `publish`.
///
/// Availability: `AudioHardwareCreateProcessTap` is macOS 14.2+. The product
/// floor is being raised to 26+, but the guard keeps the file compiling against
/// the current 14.0 deployment target until that bump lands.
@available(macOS 14.2, *)
final class SystemAudioCaptureService: @unchecked Sendable {
    enum CaptureError: Error, CustomStringConvertible {
        case tapCreationFailed(OSStatus)
        case tapUIDUnavailable(OSStatus)
        case tapFormatUnavailable(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case startFailed(OSStatus)

        var description: String {
            switch self {
            case .tapCreationFailed(let s): return "AudioHardwareCreateProcessTap failed (OSStatus \(s))"
            case .tapUIDUnavailable(let s): return "kAudioTapPropertyUID read failed (OSStatus \(s))"
            case .tapFormatUnavailable(let s): return "kAudioTapPropertyFormat read failed (OSStatus \(s))"
            case .aggregateCreationFailed(let s): return "AudioHardwareCreateAggregateDevice failed (OSStatus \(s))"
            case .ioProcCreationFailed(let s): return "AudioDeviceCreateIOProcIDWithBlock failed (OSStatus \(s))"
            case .startFailed(let s): return "AudioDeviceStart failed (OSStatus \(s))"
            }
        }
    }

    /// Strongly captured by the IOProc block (never `self`, so the HAL holding
    /// the block does not pin the service alive and block its own teardown).
    private final class IOContext {
        let processor: AudioSpectrumProcessor
        let broker: AudioSpectrumBroker
        var scratchLeft: [Float] = []
        var scratchRight: [Float] = []

        init(processor: AudioSpectrumProcessor, broker: AudioSpectrumBroker) {
            self.processor = processor
            self.broker = broker
        }
    }

    /// The shared sink. Readers (renderers / web bridges) take snapshots; the
    /// IOProc is the sole writer.
    let broker = AudioSpectrumBroker()

    private(set) var isRunning = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var context: IOContext?

    private let ioQueue = DispatchQueue(label: "com.livewallpaper.audio.capture.ioproc", qos: .userInitiated)

    // MARK: - Lifecycle

    /// Builds the tap + private aggregate device + IOProc and starts capture.
    /// Idempotent: a second call while running is a no-op. Throws a typed
    /// `CaptureError` (with the underlying `OSStatus`) and cleans up partial
    /// state on any failure.
    func start() throws {
        guard !isRunning else { return }

        // 1. Global stereo, private, unmuted tap of every process' output.
        //    `isExclusive == true` + empty `processes` == "tap all except none".
        let description = CATapDescription()
        description.name = "LiveWallpaper System Audio"
        description.processes = []
        description.isExclusive = true
        description.isMixdown = true
        description.isMono = false
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr, newTapID != AudioObjectID(kAudioObjectUnknown) else {
            throw CaptureError.tapCreationFailed(tapStatus)
        }
        tapID = newTapID

        // 2. Resolve the tap's UID + stream format.
        let tapUID: CFString
        do {
            tapUID = try readTapUID(tapID)
        } catch {
            teardown()
            throw error
        }

        var asbd = AudioStreamBasicDescription()
        let formatStatus = readTapFormat(tapID, into: &asbd)
        guard formatStatus == noErr, asbd.mSampleRate > 0 else {
            teardown()
            throw CaptureError.tapFormatUnavailable(formatStatus)
        }

        // 3. Private aggregate device that auto-starts the sub-tap.
        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "LiveWallpaper Audio Capture",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: true
                ]
            ]
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &newAggregateID
        )
        guard aggregateStatus == noErr, newAggregateID != AudioObjectID(kAudioObjectUnknown) else {
            teardown()
            throw CaptureError.aggregateCreationFailed(aggregateStatus)
        }
        aggregateID = newAggregateID

        // 4. Processor matched to the tap's real sample rate; shared context for
        //    the IOProc (captured instead of `self`).
        let processor = AudioSpectrumProcessor(
            configuration: AudioSpectrumProcessor.Configuration(sampleRate: Float(asbd.mSampleRate))
        )
        let ioContext = IOContext(processor: processor, broker: broker)
        context = ioContext

        let channelCount = Int(asbd.mChannelsPerFrame)
        let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0

        var newIOProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newIOProcID,
            aggregateID,
            ioQueue
        ) { _, inInputData, _, _, _ in
            Self.handleIO(
                input: inInputData,
                channelCount: channelCount,
                isInterleaved: isInterleaved,
                context: ioContext
            )
        }
        guard ioStatus == noErr, let resolvedIOProcID = newIOProcID else {
            teardown()
            throw CaptureError.ioProcCreationFailed(ioStatus)
        }
        ioProcID = resolvedIOProcID

        let startStatus = AudioDeviceStart(aggregateID, resolvedIOProcID)
        guard startStatus == noErr else {
            teardown()
            throw CaptureError.startFailed(startStatus)
        }

        isRunning = true
        Logger.notice(
            "[AudioCapture] started — tap=\(tapID) aggregate=\(aggregateID) "
                + "rate=\(Int(asbd.mSampleRate)) ch=\(channelCount) "
                + "interleaved=\(isInterleaved)",
            category: .audioCapture
        )
    }

    /// Stops capture and releases every Core Audio object. Safe to call when
    /// not running, and safe to call repeatedly.
    func stop() {
        guard isRunning || tapID != AudioObjectID(kAudioObjectUnknown) else { return }
        teardown()
        broker.resetToSilence()
        Logger.notice("[AudioCapture] stopped", category: .audioCapture)
    }

    deinit {
        teardown()
    }

    // MARK: - Teardown

    private func teardown() {
        if let ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        context = nil
        isRunning = false
    }

    // MARK: - IOProc (realtime-ish; runs on ioQueue)

    private static func handleIO(
        input: UnsafePointer<AudioBufferList>,
        channelCount: Int,
        isInterleaved: Bool,
        context: IOContext
    ) {
        let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard bufferList.count > 0 else { return }

        let timestampNanos = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())

        if isInterleaved || bufferList.count == 1 {
            // One interleaved (or single mono) buffer.
            let buffer = bufferList[0]
            guard let raw = buffer.mData else { return }
            let channels = max(Int(buffer.mNumberChannels), channelCount, 1)
            let frameCount = channels > 0 ? Int(buffer.mDataByteSize) / (MemoryLayout<Float>.stride * channels) : 0
            guard frameCount > 0 else { return }
            ensureScratch(context, frameCount: frameCount)
            let source = raw.assumingMemoryBound(to: Float.self)
            context.scratchLeft.withUnsafeMutableBufferPointer { left in
                context.scratchRight.withUnsafeMutableBufferPointer { right in
                    writeInterleavedStereo(
                        source,
                        channelCount: channels,
                        frameCount: frameCount,
                        left: left.baseAddress!,
                        right: right.baseAddress!
                    )
                }
            }
            publish(context, frameCount: frameCount, timestampNanos: timestampNanos)
        } else {
            // Non-interleaved: buffer 0 = left, buffer 1 = right (if present).
            let leftBuffer = bufferList[0]
            guard let leftRaw = leftBuffer.mData else { return }
            let frameCount = Int(leftBuffer.mDataByteSize) / MemoryLayout<Float>.stride
            guard frameCount > 0 else { return }
            ensureScratch(context, frameCount: frameCount)
            let leftSource = UnsafePointer(leftRaw.assumingMemoryBound(to: Float.self))
            var rightSource: UnsafePointer<Float>?
            if bufferList.count > 1, let rightRaw = bufferList[1].mData {
                rightSource = UnsafePointer(rightRaw.assumingMemoryBound(to: Float.self))
            }
            context.scratchLeft.withUnsafeMutableBufferPointer { left in
                context.scratchRight.withUnsafeMutableBufferPointer { right in
                    writePlanarStereo(
                        left: leftSource,
                        right: rightSource,
                        frameCount: frameCount,
                        left: left.baseAddress!,
                        right: right.baseAddress!
                    )
                }
            }
            publish(context, frameCount: frameCount, timestampNanos: timestampNanos)
        }
    }

    private static func publish(_ context: IOContext, frameCount: Int, timestampNanos: UInt64) {
        let frame = context.processor.process(
            left: context.scratchLeft,
            right: context.scratchRight,
            timestampNanos: timestampNanos
        )
        context.broker.publish(frame)
    }

    /// Resizes scratch buffers only when the hardware buffer size changes
    /// (rare). Steady-state callbacks reuse the existing storage with no alloc.
    private static func ensureScratch(_ context: IOContext, frameCount: Int) {
        if context.scratchLeft.count != frameCount {
            context.scratchLeft = [Float](repeating: 0, count: frameCount)
        }
        if context.scratchRight.count != frameCount {
            context.scratchRight = [Float](repeating: 0, count: frameCount)
        }
    }

    // MARK: - Channel extraction (pure, unit-tested)

    /// Deinterleaves an interleaved float buffer into stereo L/R. Mono input
    /// (`channelCount <= 1`) is duplicated to both channels; >2 channels take
    /// channels 0 and 1. Caller preallocates `left`/`right` to `frameCount`.
    static func writeInterleavedStereo(
        _ source: UnsafePointer<Float>,
        channelCount: Int,
        frameCount: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>
    ) {
        if channelCount <= 1 {
            for index in 0..<frameCount {
                let sample = source[index]
                left[index] = sample
                right[index] = sample
            }
        } else {
            for index in 0..<frameCount {
                left[index] = source[index * channelCount]
                right[index] = source[index * channelCount + 1]
            }
        }
    }

    /// Copies non-interleaved (planar) channels into stereo L/R. A missing
    /// right channel duplicates the left. Caller preallocates buffers.
    static func writePlanarStereo(
        left source0: UnsafePointer<Float>,
        right source1: UnsafePointer<Float>?,
        frameCount: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>
    ) {
        for index in 0..<frameCount {
            left[index] = source0[index]
        }
        if let source1 {
            for index in 0..<frameCount {
                right[index] = source1[index]
            }
        } else {
            for index in 0..<frameCount {
                right[index] = source0[index]
            }
        }
    }

    // MARK: - Core Audio property reads

    private func readTapUID(_ tap: AudioObjectID) throws -> CFString {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString?
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &uid)
        guard status == noErr, let resolved = uid else {
            throw CaptureError.tapUIDUnavailable(status)
        }
        return resolved
    }

    private func readTapFormat(_ tap: AudioObjectID, into asbd: inout AudioStreamBasicDescription) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
    }
}
#endif
