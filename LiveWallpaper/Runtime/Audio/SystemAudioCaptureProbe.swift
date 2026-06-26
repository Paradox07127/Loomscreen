#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// On-device verification hook for `SystemAudioCaptureService`. The Core Audio
/// Process Tap path cannot be validated statically — whether the sandbox +
/// hardened-runtime + `LSUIElement` agent can create the tap, trigger the
/// "System Audio Recording" TCC prompt, and actually receive non-zero samples
/// is only knowable on a real signed run. This probe makes that one run cheap:
///
///   defaults write <bundle-id> WPEAudioCaptureProbe -bool YES
///   # launch the app, play some music, then:
///   log stream --predicate 'category == "AudioCapture"' --info
///
/// It starts a capture, logs per-second peak/energy of the published spectrum
/// for 30 s, then stops. Non-zero `peakL/peakR` while audio plays == the tap
/// works under our sandbox. A `probe start FAILED` line (with the OSStatus)
/// means the tap/aggregate/IOProc was rejected — read the status to decide
/// whether the `audio-input` entitlement alone is insufficient.
@available(macOS 14.2, *)
@MainActor
enum SystemAudioCaptureProbe {
    private static let defaultsKey = "WPEAudioCaptureProbe"
    private static let probeDurationTicks = 30

    private static var service: SystemAudioCaptureService?
    private static var timer: Timer?
    private static var ticks = 0

    /// No-op unless the `WPEAudioCaptureProbe` default is set. Called once at app launch.
    static func runIfRequested() {
        guard UserDefaults.standard.bool(forKey: defaultsKey) else { return }
        guard service == nil else { return }

        Logger.notice(
            "[AudioCapture] probe requested — starting system-audio capture diagnostics",
            category: .audioCapture
        )

        let captureService = SystemAudioCaptureService()
        do {
            try captureService.start()
        } catch {
            Logger.warning("[AudioCapture] probe start FAILED: \(error)", category: .audioCapture)
            return
        }

        service = captureService
        ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
    }

    private static func tick() {
        ticks += 1
        guard let captureService = service else {
            timer?.invalidate()
            timer = nil
            return
        }

        let frame = captureService.broker.snapshot()
        let peakLeft = frame.left.max() ?? 0
        let peakRight = frame.right.max() ?? 0
        let avgLeft = frame.left.isEmpty ? 0 : frame.left.reduce(0, +) / Float(frame.left.count)
        // How many of the 64 bins are pegged near max — should be small on a
        // well-ranged spectrum, large when normalization saturates.
        let saturatedLeft = frame.left.filter { $0 >= 0.99 }.count
        let inputPeak = captureService.lastInputPeak

        Logger.notice(
            String(
                format: "[AudioCapture] probe t=%ds inputPeak=%.3f | peakL=%.3f peakR=%.3f avgL=%.3f satL=%d/64 ts=%llu",
                ticks, inputPeak, peakLeft, peakRight, avgLeft, saturatedLeft, frame.timestampNanos
            ),
            category: .audioCapture
        )

        if ticks >= probeDurationTicks {
            Logger.notice("[AudioCapture] probe finished — stopping capture", category: .audioCapture)
            captureService.stop()
            service = nil
            timer?.invalidate()
            timer = nil
        }
    }
}
#endif
