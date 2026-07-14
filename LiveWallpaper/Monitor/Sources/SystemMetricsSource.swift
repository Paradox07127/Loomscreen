import Foundation
import Darwin
import os

/// The headline Monitor module for non-AI users: a comprehensive host snapshot
/// (CPU total + per-core + topology, memory + breakdown + pressure, swap, GPU +
/// renderer/tiler, thermal, network + per-interface + path, disk, battery + power
/// detail, accessories, ANE footprint, uptime, load, optional top processes) pushed
/// every `interval` seconds via `MonitorSnapshotSink`. All readings come from
/// sandbox-legal read-only kernel / IOKit / sysctl queries (see
/// `SystemMetricsSamplers`); a probe that returns nothing leaves its field `nil`/`0`
/// — the snapshot itself never fails.
final class SystemMetricsSource: MonitorDataSource, Sendable {
    let sourceID = "system"

    /// Per-concern demand gates. Each expensive walk (GPU / top processes / ANE /
    /// accessories) runs only when its flag is set. Defaults preserve the pre-v2
    /// behavior and the existing public call sites: GPU + accessories on (cheap /
    /// low-cadence), top processes driven by the caller's flag, ANE off (its
    /// per-PID rusage walk is the most expensive and only the AI Engine widget needs
    /// it). Wave 3's board orchestrator computes the union of active widget kinds and
    /// hands the resulting `Options` in via `init(options:)` — no other call site
    /// needs to change.
    struct Options: Sendable, Equatable {
        var gpu: Bool = true
        var topProcesses: Bool = false
        var ane: Bool = false
        var accessories: Bool = true
        /// SMC temperature/power reads (CPU/GPU widgets' B-tier row). Off by
        /// default — the read is cheap but sandbox-gated, so only turn it on when a
        /// widget that shows sensors is on the board.
        var sensors: Bool = false
        /// Per-app disk I/O attribution (rusage deltas inside the top-processes
        /// walk; needs the `process-info-rusage` sbpl exception). Demanded by
        /// the Disk widget's L top-list.
        var processIO: Bool = false

        static let `default` = Options()
    }

    private let interval: TimeInterval
    private let gpuSampleCadence: Int
    private let options: Options
    private let state = MetricsState()
    private let pressure = MemoryPressureWatcher()
    private let netPath = MonitorNetworkPathObserver()

    /// Preserves the original call site `SystemMetricsSource(includeTopProcesses:)`;
    /// only the top-processes gate is caller-driven here, everything else defaults.
    init(includeTopProcesses: Bool = false, interval: TimeInterval = 2.0, gpuSampleCadence: Int = 3) {
        var options = Options.default
        options.topProcesses = includeTopProcesses
        self.options = options
        self.interval = interval
        self.gpuSampleCadence = gpuSampleCadence
    }

    /// Full demand-gated init for the board orchestrator (wave 3).
    init(options: Options, interval: TimeInterval = 2.0, gpuSampleCadence: Int = 3) {
        self.options = options
        self.interval = interval
        self.gpuSampleCadence = gpuSampleCadence
    }

    func start(sink: any MonitorSnapshotSink) async {
        pressure.start()
        netPath.start()
        await state.startLoop(
            interval: interval,
            gpuSampleCadence: gpuSampleCadence,
            options: options,
            pressure: pressure,
            netPath: netPath,
            sink: sink
        )
    }

    func stop() async {
        await state.stopLoop()
        pressure.stop()
        netPath.stop()
    }

    // MARK: - Delta bookkeeping + poll loop

    /// Owns everything that must persist across polls (previous counters, GPU cadence
    /// counter, once-sampled hardware identity, the running Task). An actor keeps it
    /// Sendable-clean without locks.
    private actor MetricsState {
        private var task: Task<Void, Never>?
        private var updateCount = 0
        private var lastSampleTime: Date?
        private var prevCPU: SystemMetricsSamplers.CPURawCounters?
        private var prevNet: (rx: UInt64, tx: UInt64)?
        private var prevNetInterfaces: [String: SystemMetricsSamplers.InterfaceCounters] = [:]
        private var prevDisk: (read: UInt64, written: UInt64)?
        private var lastGPU: SystemMetricsSamplers.GPUSample?
        private var lastGPUSampledAt: Double?
        private var prevProcessCounters: [Int32: SystemMetricsSamplers.ProcessCPUCounters] = [:]
        private var lastANE: SystemMetricsSamplers.ANESample?
        private var lastANESampledAt: Date?
        // Lazily opened on the first sensors-enabled tick; caches its SMC connection.
        private var sensorSampler: MonitorSensorSampler?
        // Hardware identity is fixed for the boot — sample once, then reuse.
        private var cpuInfo: MonitorCPUInfo?
        private var gpuDeviceName: String?

        func startLoop(
            interval: TimeInterval,
            gpuSampleCadence: Int,
            options: Options,
            pressure: MemoryPressureWatcher,
            netPath: MonitorNetworkPathObserver,
            sink: any MonitorSnapshotSink
        ) {
            task?.cancel()
            task = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    await self.tick(
                        interval: interval,
                        gpuSampleCadence: gpuSampleCadence,
                        options: options,
                        pressure: pressure,
                        netPath: netPath,
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

        func stopLoop() async {
            guard let task else { return }
            self.task = nil
            task.cancel()
            // Await the in-flight tick so a running poll can't publish into the
            // shared broker after MonitorRuntime.stopPipeline() has cleared it.
            await task.value
        }

        private func tick(
            interval: TimeInterval,
            gpuSampleCadence: Int,
            options: Options,
            pressure: MemoryPressureWatcher,
            netPath: MonitorNetworkPathObserver,
            sink: any MonitorSnapshotSink
        ) async {
            updateCount += 1
            let now = Date()
            let elapsed = lastSampleTime.map { now.timeIntervalSince($0) } ?? interval
            lastSampleTime = now

            if cpuInfo == nil { cpuInfo = SystemMetricsSamplers.sampleCPUInfo() }

            let cpu = SystemMetricsSamplers.sampleCPU(previous: prevCPU)
            prevCPU = cpu.counters

            let memory = SystemMetricsSamplers.sampleMemory()

            let netRaw = SystemMetricsSamplers.sampleNetworkCounters()
            let netRx = SystemMetricsSamplers.rate(current: netRaw.rx, previous: prevNet?.rx ?? netRaw.rx, interval: elapsed)
            let netTx = SystemMetricsSamplers.rate(current: netRaw.tx, previous: prevNet?.tx ?? netRaw.tx, interval: elapsed)
            let pathSnapshot = netPath.currentSnapshot()
            let netInterfaces = SystemMetricsSamplers.networkInterfaces(
                previous: prevNetInterfaces,
                current: netRaw.interfaces,
                interval: elapsed,
                activeName: pathSnapshot?.activeInterfaceName
            )
            prevNet = (netRaw.rx, netRaw.tx)
            prevNetInterfaces = Dictionary(
                netRaw.interfaces.map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            let diskRaw = SystemMetricsSamplers.sampleDiskCounters()
            let diskRead = SystemMetricsSamplers.rate(current: diskRaw.read, previous: prevDisk?.read ?? diskRaw.read, interval: elapsed)
            let diskWrite = SystemMetricsSamplers.rate(current: diskRaw.written, previous: prevDisk?.written ?? diskRaw.written, interval: elapsed)
            prevDisk = diskRaw

            if options.gpu, MonitoringCadence.shouldSampleGPU(updateCount: updateCount, cadence: gpuSampleCadence) {
                lastGPU = SystemMetricsSamplers.sampleGPU()
                lastGPUSampledAt = now.timeIntervalSince1970
                if gpuDeviceName == nil { gpuDeviceName = SystemMetricsSamplers.sampleGPUDeviceName() }
            }

            let power = SystemMetricsSamplers.samplePower()

            var accessories: [MonitorAccessoryBattery]?
            if options.accessories {
                let read = SystemMetricsSamplers.sampleAccessoryBatteries()
                accessories = read.isEmpty ? nil : read
            }

            var topProcesses: [MonitorProcessSample]?
            var topIOProcesses: [MonitorProcessSample]?
            if options.topProcesses || options.processIO {
                let result = SystemMetricsSamplers.sampleTopProcesses(
                    previous: prevProcessCounters,
                    interval: elapsed,
                    // Matches the widgets' ceiling: the processes stepper and
                    // the L board tile both go up to 12 rows (Apple L frame
                    // physically fits 19; 12 keeps the tail readable).
                    limit: 12,
                    includeIO: options.processIO
                )
                prevProcessCounters = result.counters
                topProcesses = result.samples.isEmpty ? nil : result.samples
                topIOProcesses = result.ioSamples.isEmpty ? nil : result.ioSamples
            }

            // ANE's per-PID rusage walk is the priciest probe → ≥5s cadence, gated.
            if options.ane, shouldSampleANE(now: now) {
                lastANE = SystemMetricsSamplers.sampleANE()
                lastANESampledAt = now
            }

            // SMC temperature/power. The reader caches its connection; a first-tick
            // sandbox denial makes every sample nil, so the sensor rows stay hidden.
            var sensors: MonitorSensorReadings?
            if options.sensors {
                if sensorSampler == nil { sensorSampler = MonitorSensorSampler() }
                sensors = sensorSampler?.sample()
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
                gpuUsage: lastGPU?.deviceUtil,
                thermalState: SystemMetricsSamplers.thermalString(ProcessInfo.processInfo.thermalState),
                netRxBytesPerSec: netRx,
                netTxBytesPerSec: netTx,
                diskReadBytesPerSec: diskRead,
                diskWriteBytesPerSec: diskWrite,
                batteryLevel: power.battery?.level,
                batteryCharging: power.battery?.charging,
                uptimeSeconds: ProcessInfo.processInfo.systemUptime,
                loadAverage1: SystemMetricsSamplers.sampleLoadAverages()?.first,
                topProcesses: topProcesses,
                cpuInfo: cpuInfo,
                cpuLoadAvg: SystemMetricsSamplers.sampleLoadAverages(),
                memBreakdown: memory.breakdown,
                gpuDeviceName: gpuDeviceName,
                gpuCoreCount: lastGPU?.coreCount,
                gpuSampledAt: lastGPUSampledAt,
                gpuRendererUtil: lastGPU?.rendererUtil,
                gpuTilerUtil: lastGPU?.tilerUtil,
                netInterfaces: netInterfaces.isEmpty ? nil : netInterfaces,
                netPath: pathSnapshot?.path,
                batteryIsCharged: power.battery?.isCharged,
                powerSource: power.powerSource,
                batteryMinutesRemaining: power.battery?.minutesRemaining,
                batteryMinutesToFull: power.battery?.minutesToFull,
                lowPowerMode: power.lowPowerMode,
                accessories: accessories,
                aneProcesses: lastANE.flatMap { $0.processes.isEmpty ? nil : $0.processes },
                aneActive: lastANE?.active,
                sensors: sensors,
                topIOProcesses: topIOProcesses,
                gpuMemUsedBytes: lastGPU?.memUsedBytes
            )

            // Bail before publishing if stop() cancelled us mid-tick, so a late
            // poll can't land in the broker after the pipeline was torn down.
            guard !Task.isCancelled else { return }
            await sink.updateSystem(snapshot)
            await sink.updateHealth(MonitorSourceHealth(
                sourceID: "system",
                state: "ok",
                detail: nil,
                lastUpdateAt: now.timeIntervalSince1970
            ))
        }

        /// ANE walk fires on the first enabled tick, then no more often than every 5s.
        private func shouldSampleANE(now: Date) -> Bool {
            guard let last = lastANESampledAt else { return true }
            return now.timeIntervalSince(last) >= 5.0
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
