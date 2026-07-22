import Darwin
import Foundation

/// Publishes host CPU, memory, GPU, thermal, network, disk, and power metrics.
final class SystemMetricsSource: MonitorDataSource, Sendable {
    let sourceID = "system"

    /// Per-concern demand gates.
    struct Options: Sendable, Equatable {
        var gpu: Bool = true
        var topProcesses: Bool = false
        var ane: Bool = false
        var accessories: Bool = true
        /// SMC temperature/power reads (CPU/GPU widgets' B-tier row).
        var sensors: Bool = false
        /// Per-app disk I/O attribution (rusage deltas inside the top-processes walk; needs the `process-info-rusage` sbpl exception).
        var processIO: Bool = false

        static let `default` = Options()
    }

    private let interval: TimeInterval
    private let gpuSampleCadence: Int
    private let options: Options
    private let loadAverageSampler: @Sendable () -> [Double]?
    private let pressure: any MemoryPressureReading
    private let state = MetricsState()
    private let netPath = MonitorNetworkPathObserver()

    /// Preserves the original call site `SystemMetricsSource(includeTopProcesses:)`;
    /// only the top-processes gate is caller-driven here, everything else defaults.
    init(
        includeTopProcesses: Bool = false,
        interval: TimeInterval = 2.0,
        gpuSampleCadence: Int = 3,
        loadAverageSampler: @escaping @Sendable () -> [Double]? = {
            SystemMetricsSamplers.sampleLoadAverages()
        },
        memoryPressureReader: any MemoryPressureReading = SystemMemoryPressureWatcher.shared
    ) {
        var options = Options.default
        options.topProcesses = includeTopProcesses
        self.options = options
        self.interval = interval
        self.gpuSampleCadence = gpuSampleCadence
        self.loadAverageSampler = loadAverageSampler
        pressure = memoryPressureReader
    }

    /// Full demand-gated init for the board orchestrator (wave 3).
    init(
        options: Options,
        interval: TimeInterval = 2.0,
        gpuSampleCadence: Int = 3,
        loadAverageSampler: @escaping @Sendable () -> [Double]? = {
            SystemMetricsSamplers.sampleLoadAverages()
        },
        memoryPressureReader: any MemoryPressureReading = SystemMemoryPressureWatcher.shared
    ) {
        self.options = options
        self.interval = interval
        self.gpuSampleCadence = gpuSampleCadence
        self.loadAverageSampler = loadAverageSampler
        pressure = memoryPressureReader
    }

    /// Pure wire mapping used by the polling actor. The monitor observes the
    /// app-wide watcher but never owns or mutates its dispatch-source lifecycle.
    static func memoryPressureWireValue(from reader: any MemoryPressureReading) -> String {
        reader.currentLevel().rawValue
    }

    func start(sink: any MonitorSnapshotSink) async {
        netPath.start()
        await state.startLoop(
            interval: interval,
            gpuSampleCadence: gpuSampleCadence,
            options: options,
            loadAverageSampler: loadAverageSampler,
            pressure: pressure,
            netPath: netPath,
            sink: sink
        )
    }

    func stop() async {
        await state.stopLoop()
        netPath.stop()
    }

    // MARK: - Delta bookkeeping + poll loop

    /// Owns everything that must persist across polls (previous counters, GPU cadence counter, once-sampled hardware identity, the running Task).
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
        /// Lazily opened on the first sensors-enabled tick; caches its SMC connection.
        private var sensorSampler: MonitorSensorSampler?
        private var cpuInfo: MonitorCPUInfo?
        private var gpuDeviceName: String?

        func startLoop(
            interval: TimeInterval,
            gpuSampleCadence: Int,
            options: Options,
            loadAverageSampler: @escaping @Sendable () -> [Double]?,
            pressure: any MemoryPressureReading,
            netPath: MonitorNetworkPathObserver,
            sink: any MonitorSnapshotSink
        ) {
            task?.cancel()
            task = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    await tick(
                        interval: interval,
                        gpuSampleCadence: gpuSampleCadence,
                        options: options,
                        loadAverageSampler: loadAverageSampler,
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
            loadAverageSampler: @Sendable () -> [Double]?,
            pressure: any MemoryPressureReading,
            netPath: MonitorNetworkPathObserver,
            sink: any MonitorSnapshotSink
        ) async {
            updateCount += 1
            let now = Date()
            let elapsed = lastSampleTime.map { now.timeIntervalSince($0) } ?? interval
            lastSampleTime = now

            if cpuInfo == nil {
                cpuInfo = SystemMetricsSamplers.sampleCPUInfo()
            }

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
                if gpuDeviceName == nil {
                    gpuDeviceName = SystemMetricsSamplers.sampleGPUDeviceName()
                }
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
                if sensorSampler == nil {
                    sensorSampler = MonitorSensorSampler()
                }
                sensors = sensorSampler?.sample()
            }

            let loadAverages = loadAverageSampler()

            let snapshot = MonitorSystemSnapshot(
                cpuTotal: cpu.sample.total,
                cpuUser: cpu.sample.user,
                cpuSystem: cpu.sample.system,
                perCore: cpu.sample.perCore.isEmpty ? nil : cpu.sample.perCore,
                memUsedBytes: memory.usedBytes,
                memTotalBytes: memory.totalBytes,
                memPressure: SystemMetricsSource.memoryPressureWireValue(from: pressure),
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
                loadAverage1: loadAverages?.first,
                topProcesses: topProcesses,
                cpuInfo: cpuInfo,
                cpuLoadAvg: loadAverages,
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

/// GPU sampling is 3× more expensive than the rest, so it runs every Nth poll — matching `SystemMonitor`'s cadence policy but kept local to avoid depending on the Pro package.
enum MonitoringCadence {
    static func shouldSampleGPU(updateCount: Int, cadence: Int) -> Bool {
        guard cadence > 1, updateCount > 1 else { return true }
        return updateCount % cadence == 0
    }
}
