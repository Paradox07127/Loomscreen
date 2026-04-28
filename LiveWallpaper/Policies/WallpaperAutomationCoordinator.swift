import CoreGraphics
import Foundation

@MainActor
final class WallpaperAutomationCoordinator {
    private var scheduleMonitorTask: Task<Void, Never>?
    private var playlistRotationTask: Task<Void, Never>?

    func start(
        screenProvider: @escaping @MainActor () -> [Screen],
        configurationProvider: @escaping @MainActor (CGDirectDisplayID) -> ScreenConfiguration?,
        scheduleHandler: @escaping @MainActor (Screen) -> Void,
        playlistHandler: @escaping @MainActor (Screen) -> Void
    ) {
        stop()

        scheduleMonitorTask = Task { @MainActor in
            for screen in screenProvider() {
                scheduleHandler(screen)
            }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }

                for screen in screenProvider() {
                    scheduleHandler(screen)
                }
            }
        }

        playlistRotationTask = Task { @MainActor in
            var lastRotation: [CGDirectDisplayID: Date] = [:]

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }

                let now = Date()
                for screen in screenProvider() {
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
        scheduleMonitorTask?.cancel()
        scheduleMonitorTask = nil
        playlistRotationTask?.cancel()
        playlistRotationTask = nil
    }

    deinit {
        scheduleMonitorTask?.cancel()
        playlistRotationTask?.cancel()
    }
}
