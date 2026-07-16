import Foundation

@MainActor
extension ScreenManager {
    func setupMemoryPressureMonitoring() {
        memoryPressureWatcher.start { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self, !self.isTerminating else { return }
                self.applyMemoryPressureLevel(level)
            }
        }
        applyMemoryPressureLevel(memoryPressureWatcher.currentLevel())
    }

    private func applyMemoryPressureLevel(_ level: SystemMemoryPressureLevel) {
        guard !isTerminating else { return }
        setMemoryPressure(level != .normal)
    }

    /// Suspends all wallpaper types while memory pressure holds without changing
    /// the user's play/pause intent, then restores the prior policy when it clears.
    private func setMemoryPressure(_ active: Bool) {
        guard isUnderMemoryPressure != active else { return }
        isUnderMemoryPressure = active
        Logger.notice(
            active ? "Memory pressure: suspending wallpapers" : "Memory pressure cleared: restoring wallpapers",
            category: .memory
        )
        refreshPerformancePolicyForAllScreens()
    }
}
