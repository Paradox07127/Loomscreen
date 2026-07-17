import CoreGraphics
import Foundation
import LiveWallpaperCore

@MainActor
final class WallpaperAutomationCoordinator {
    private var automationTask: Task<Void, Never>?

    func start(
        screenProvider: @escaping @MainActor () -> [Screen],
        configurationProvider: @escaping @MainActor (CGDirectDisplayID) -> ScreenConfiguration?,
        scheduleHandler: @escaping @MainActor (Screen) -> Void,
        playlistHandler: @escaping @MainActor (Screen) -> Void
    ) {
        stop()

        // Single 60s tick for both duties (schedule check + playlist rotation)
        // instead of two identical sleep/wake loops — halves periodic wakeups.
        automationTask = Task { @MainActor in
            for screen in screenProvider() {
                scheduleHandler(screen)
            }

            var lastRotation: [CGDirectDisplayID: Date] = [:]

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }

                for screen in screenProvider() {
                    scheduleHandler(screen)
                }

                let now = Date()
                let screens = screenProvider()
                let liveIDs = Set(screens.map(\.id))
                lastRotation = lastRotation.filter { liveIDs.contains($0.key) }
                for screen in screens {
                    guard let configuration = configurationProvider(screen.id),
                          let rotationMinutes = configuration.playlistRotationMinutes,
                          configuration.playlistBookmarks?.isEmpty == false else {
                        continue
                    }

                    guard let lastTime = lastRotation[screen.id] else {
                        lastRotation[screen.id] = now
                        continue
                    }

                    if PlaylistPolicy.shouldRotate(
                        now: now,
                        lastRotation: lastTime,
                        rotationMinutes: rotationMinutes
                    ) {
                        lastRotation[screen.id] = now
                        playlistHandler(screen)
                    }
                }
            }
        }
    }

    func stop() {
        automationTask?.cancel()
        automationTask = nil
    }

    deinit {
        automationTask?.cancel()
    }
}
