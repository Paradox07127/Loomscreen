#if !LITE_BUILD
import AppKit

/// Feeds a `WPEPointerMailbox` from AppKit so the render thread never reads
/// `NSEvent` / `NSView`. Owns only the mouse-position and window-geometry slots;
/// `pointerFrame` and `clickCaptureEnabled` are pushed by the view/renderer.
///
/// Global + local monitors are both required. `addGlobalMonitorForEvents` sees
/// events destined for *other* processes — including the desktop the wallpaper
/// sits behind — but never this app's own windows. `addLocalMonitorForEvents`
/// sees only this app's own events. Wallpaper parallax must track the cursor
/// everywhere on screen, so only their union is complete; neither alone covers
/// both "over another app / the desktop" and "over our own settings window".
@MainActor
final class WPEPointerPublisher {
    private let mailbox: WPEPointerMailbox
    private weak var view: NSView?
    private let now: () -> TimeInterval
    private let throttleInterval: TimeInterval

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var geometryObservers: [NSObjectProtocol] = []
    private var lastMousePublishAt: TimeInterval = -.greatestFiniteMagnitude

    private static let mouseMask: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
    ]

    /// `throttleFPS` bounds mailbox writes to display cadence: at 120 Hz a burst
    /// of sub-8 ms mouse events collapses to one write. Safe because the mailbox
    /// is last-write-wins and the renderer re-reads every frame — a dropped
    /// intermediate move is one the renderer would never have sampled. Cost: the
    /// final move before the cursor stops can lag by up to one interval (< 1
    /// frame), invisible at parallax cadence. `throttleFPS <= 0` disables it.
    init(
        mailbox: WPEPointerMailbox,
        view: NSView?,
        throttleFPS: Double = 120,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.mailbox = mailbox
        self.view = view
        self.now = now
        self.throttleInterval = throttleFPS > 0 ? 1.0 / throttleFPS : 0
    }

    var isRunning: Bool { globalMonitor != nil || localMonitor != nil }

    /// Idempotent: a second `start()` while already running is a no-op.
    func start() {
        guard !isRunning else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mouseMask) { [weak self] event in
            self?.handleMouseEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.mouseMask) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }
        installGeometryObservers()
        publishGeometry() // seed current geometry so the first read isn't `.none`
        // Seed the cursor too: the old live sampler read `NSEvent.mouseLocation`
        // every frame, so before any mouse *event* arrives the mailbox must still
        // report the real cursor (not the off-screen sentinel) or the first frames
        // would freeze parallax at center.
        let time = now()
        lastMousePublishAt = time
        mailbox.publishMouseLocation(NSEvent.mouseLocation, timestampNanos: Self.nanos(from: time))
    }

    /// Idempotent: unloads both monitors and the geometry observers; safe to call
    /// when never started or already stopped.
    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        for observer in geometryObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        geometryObservers.removeAll()
    }

    // MARK: - Mouse

    private func handleMouseEvent(_ event: NSEvent) {
        let time = now()
        if throttleInterval > 0, time - lastMousePublishAt < throttleInterval { return }
        lastMousePublishAt = time
        // Global-monitor events carry no window; `NSEvent.mouseLocation` is the
        // screen-space cursor for both monitors, so the event's own coords are
        // deliberately unused.
        mailbox.publishMouseLocation(
            NSEvent.mouseLocation,
            timestampNanos: Self.nanos(from: time)
        )
    }

    // MARK: - Geometry

    private func installGeometryObservers() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
            NSApplication.didChangeScreenParametersNotification
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishGeometry() }
            }
            geometryObservers.append(observer)
        }
    }

    private func publishGeometry() {
        mailbox.publishGeometry(Self.geometry(of: view))
    }

    /// The view's current frame in screen coordinates. Missing view/window or a
    /// degenerate bounds yields `.none`, matching `sampleSceneUV`'s guards so the
    /// mailbox resolves `.inactive`.
    static func geometry(of view: NSView?) -> WPEPointerMailbox.Geometry {
        guard let view,
              let window = view.window,
              view.bounds.width > 0,
              view.bounds.height > 0 else {
            return .none
        }
        let windowRect = view.convert(view.bounds, to: nil)
        return WPEPointerMailbox.Geometry(
            viewFrameInScreen: window.convertToScreen(windowRect)
        )
    }

    private static func nanos(from seconds: TimeInterval) -> UInt64 {
        seconds > 0 ? UInt64(seconds * 1_000_000_000) : 0
    }
}
#endif
