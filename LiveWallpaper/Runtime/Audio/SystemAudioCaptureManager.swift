#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// App-wide owner of the single system-audio capture pipeline. There is exactly
/// one tap + one `AudioSpectrumBroker` for the whole app; every audio-reactive
/// surface (Metal scene uniforms, WebGL payload, HTML `wallpaperRegisterAudioListener`)
/// reads snapshots from `broker`. This mirrors Wallpaper Engine: one loopback
/// capture fanned out to N consumers and N displays — never a tap per renderer.
///
/// Lifecycle is driven by `GlobalSettings.audioResponseEnabled` via `setEnabled`,
/// and (once sinks are wired) by a consumer ref-count so the tap only runs while
/// an audio-reactive wallpaper is actually on screen.
@MainActor
final class SystemAudioCaptureManager {
    static let shared = SystemAudioCaptureManager()

    enum State: Equatable {
        case idle
        case capturing
        case failed(String)
        case unsupported
    }

    private(set) var state: State = .idle

    private var isEnabled = false
    private var consumerCount = 0
    /// Type-erased so the stored property doesn't require macOS 14.2 at the
    /// declaration site (the manager itself is reachable on the 14.0 floor).
    private var serviceBox: AnyObject?

    private init() {}

    /// The shared spectrum sink. `nil` while capture isn't running. Sinks take
    /// `broker?.snapshot()` each frame/tick.
    var broker: AudioSpectrumBroker? {
        guard #available(macOS 14.2, *) else { return nil }
        return (serviceBox as? SystemAudioCaptureService)?.broker
    }

    var isCapturing: Bool {
        if case .capturing = state { return true }
        return false
    }

    /// Master switch, mirrors `GlobalSettings.audioResponseEnabled`.
    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        Logger.notice("[AudioCapture] manager: enabled=\(enabled)", category: .audioCapture)
        reconcile()
    }

    /// Active audio-reactive wallpapers retain/release the capture so the tap
    /// only runs while something consumes it. (Sinks call these in a later step;
    /// until then capture follows `isEnabled` alone.)
    func retain() {
        consumerCount += 1
        reconcile()
    }

    func release() {
        consumerCount = max(0, consumerCount - 1)
        reconcile()
    }

    // MARK: - Reconciliation

    /// Until sinks wire `retain()`/`release()`, run whenever enabled so the
    /// feature is usable/testable; once consumers exist, also require
    /// `consumerCount > 0` here.
    private var shouldRun: Bool { isEnabled }

    private func reconcile() {
        if shouldRun {
            startIfNeeded()
        } else {
            stopIfNeeded()
        }
    }

    private func startIfNeeded() {
        guard serviceBox == nil else { return }
        guard #available(macOS 14.2, *) else {
            state = .unsupported
            Logger.warning("[AudioCapture] manager: system audio capture needs macOS 14.2+", category: .audioCapture)
            return
        }
        let service = SystemAudioCaptureService()
        do {
            try service.start()
            serviceBox = service
            state = .capturing
        } catch {
            serviceBox = nil
            state = .failed("\(error)")
            Logger.warning("[AudioCapture] manager: capture start failed: \(error)", category: .audioCapture)
        }
    }

    private func stopIfNeeded() {
        if #available(macOS 14.2, *), let service = serviceBox as? SystemAudioCaptureService {
            service.stop()
        }
        serviceBox = nil
        if state != .unsupported {
            state = .idle
        }
    }
}
#endif
