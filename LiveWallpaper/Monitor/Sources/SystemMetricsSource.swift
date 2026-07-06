import Foundation
import Darwin
import os

/// The headline Monitor module for non-AI users: a comprehensive host snapshot
/// (CPU total + per-core, memory + pressure, swap, GPU, thermal, network, disk,
/// battery, uptime, load, optional top processes) pushed every `interval` seconds
/// via `MonitorSnapshotSink`. All readings come from sandbox-legal read-only kernel /
/// IOKit / sysctl queries (see `SystemMetricsSamplers`); a probe that returns nothing
/// leaves its field `nil`/`0` — the snapshot itself never fails.
final class SystemMetricsSource: MonitorDataSource, Sendable {
    let sourceID = "system"

    private let interval: TimeInterval
    private let gpuSampleCadence: Int
    private let includeTopProcesses: Bool
    private let state = MetricsState()
    private let pressure = MemoryPressureWatcher()

    init(includeTopProcesses: Bool = false, interval: TimeInterval = 2.0, gpuSampleCadence: Int = 3) {
        self.includeTopProcesses = includeTopProcesses
        self.interval = interval
        self.gpuSampleCadence = gpuSampleCadence
    }

    func start(sink: any MonitorSnapshotSink) async {
        pressure.start()
        await state.startLoop(
            interval: interval,
            gpuSampleCadence: gpuSampleCadence,
            includeTopProcesses: includeTopProcesses,
            pressure: pressure,
            sink: sink
        )
    }

    func stop() async {
        await state.stopLoop()
        pressure.stop()
    }

    // MARK: - Delta bookkeeping + poll loop

    /// Owns everything that must persist across polls (previous counters, GPU cadence
    /// counter, the running Task). An actor keeps it Sendable-clean without locks.
    private actor MetricsState {
        private var task: Task<Void, Never>?
        private var updateCount = 0
        private var lastSampleTime: Date?
        private var prevCPU: SystemMetricsSamplers.CPURawCounters?
        private var prevNet: (rx: UInt64, tx: UInt64)?
        private var prevDisk: (read: UInt64, written: UInt64)?
        private var lastGPU: Double?
        private var prevProcessCounters: [Int32: SystemMetricsSamplers.ProcessCPUCounters] = [:]

        func startLoop(
            interval: TimeInterval,
            gpuSampleCadence: Int,
            includeTopProcesses: Bool,
            pressure: MemoryPressureWatcher,
            sink: any MonitorSnapshotSink
        ) {
            task?.cancel()
            task = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    await self.tick(
                        interval: interval,
                        gpuSampleCadence: gpuSampleCadence,
                        includeTopProcesses: includeTopProcesses,
                        pressure: pressure,
                        sink: sink
                    )
                    do {
                        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    } catch {
                        return
                    }
                }
            }
        }

        func stopLoop() {
            task?.cancel()
            task = nil
        }

        private func tick(
            interval: TimeInterval,
            gpuSampleCadence: Int,
            includeTopProcesses: Bool,
            pressure: MemoryPressureWatcher,
            sink: any MonitorSnapshotSink
        ) async {
            updateCount += 1
            let now = Date()
            let elapsed = lastSampleTime.map { now.timeIntervalSince($0) } ?? interval
            lastSampleTime = now

            let cpu = SystemMetricsSamplers.sampleCPU(previous: prevCPU)
            prevCPU = cpu.counters

            let memory = SystemMetricsSamplers.sampleMemory()

            let netRaw = SystemMetricsSamplers.sampleNetworkCounters()
            let netRx = SystemMetricsSamplers.rate(current: netRaw.rx, previous: prevNet?.rx ?? netRaw.rx, interval: elapsed)
            let netTx = SystemMetricsSamplers.rate(current: netRaw.tx, previous: prevNet?.tx ?? netRaw.tx, interval: elapsed)
            prevNet = netRaw

            let diskRaw = SystemMetricsSamplers.sampleDiskCounters()
            let diskRead = SystemMetricsSamplers.rate(current: diskRaw.read, previous: prevDisk?.read ?? diskRaw.read, interval: elapsed)
            let diskWrite = SystemMetricsSamplers.rate(current: diskRaw.written, previous: prevDisk?.written ?? diskRaw.written, interval: elapsed)
            prevDisk = diskRaw

            if MonitoringCadence.shouldSampleGPU(updateCount: updateCount, cadence: gpuSampleCadence) {
                lastGPU = SystemMetricsSamplers.sampleGPUUsage()
            }

            let battery = SystemMetricsSamplers.sampleBattery()

            var topProcesses: [MonitorProcessSample]?
            if includeTopProcesses {
                let result = SystemMetricsSamplers.sampleTopProcesses(
                    previous: prevProcessCounters,
                    interval: elapsed,
                    limit: 5
                )
                prevProcessCounters = result.counters
                topProcesses = result.samples.isEmpty ? nil : result.samples
            }

            let snapshot = MonitorSystemSnapshot(
                cpuTotal: cpu.sample.total,
                cpuUser: cpu.sample.user,
                cpuSystem: cpu.sample.system,
                perCore: cpu.sample.perCore.isEmpty ? nil : cpu.sample.perCore,
                memUsedBytes: memory.usedBytes,
                memTotalBytes: memory.totalBytes,
                memPressure: pressure.currentLevel(),
                swapUsedBytes: SystemMetricsSamplers.sampleSwapUsedBytes(),
                gpuUsage: lastGPU,
                thermalState: SystemMetricsSamplers.thermalString(ProcessInfo.processInfo.thermalState),
                netRxBytesPerSec: netRx,
                netTxBytesPerSec: netTx,
                diskReadBytesPerSec: diskRead,
                diskWriteBytesPerSec: diskWrite,
                batteryLevel: battery?.level,
                batteryCharging: battery?.charging,
                uptimeSeconds: ProcessInfo.processInfo.systemUptime,
                loadAverage1: SystemMetricsSamplers.sampleLoadAverage1(),
                topProcesses: topProcesses
            )

            await sink.updateSystem(snapshot)
            await sink.updateHealth(MonitorSourceHealth(
                sourceID: "system",
                state: "ok",
                detail: nil,
                lastUpdateAt: now.timeIntervalSince1970
            ))
        }
    }

}

/// GPU sampling is 3× more expensive than the rest, so it runs every Nth poll —
/// matching `SystemMonitor`'s cadence policy but kept local to avoid depending on the
/// Pro package.
enum MonitoringCadence {
    static func shouldSampleGPU(updateCount: Int, cadence: Int) -> Bool {
        guard cadence > 1, updateCount > 1 else { return true }
        return updateCount % cadence == 0
    }
}

/// Wraps a `DispatchSource` memory-pressure monitor. The kernel pushes warn/critical
/// transitions; between events the last level holds (default "normal"). Reads are
/// lock-guarded because the dispatch handler (writer) and the poll loop (reader) touch
/// it from different threads.
final class MemoryPressureWatcher: Sendable {
    private let level = OSAllocatedUnfairLock(initialState: "normal")
    private let source: DispatchSourceMemoryPressure

    init() {
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue(label: "com.livewallpaper.monitor.mempressure", qos: .utility)
        )
        let lock = level
        source.setEventHandler { [weak source] in
            guard let event = source?.data else { return }
            let value: String
            if event.contains(.critical) {
                value = "critical"
            } else if event.contains(.warning) {
                value = "warn"
            } else {
                value = "normal"
            }
            lock.withLock { $0 = value }
        }
    }

    func start() {
        source.activate()
    }

    func stop() {
        source.cancel()
    }

    func currentLevel() -> String {
        level.withLock { $0 }
    }
}
