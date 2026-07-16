#if !LITE_BUILD
    import AppKit
    import Foundation
    @testable import LiveWallpaper
    import os
    import Testing

    /// AF-14 E2: lock event-driven memory pressure and visible-only ownership of
    /// the legacy telemetry sampler. No test manufactures a kernel pressure event
    /// or claims an Energy-impact result.
    @Suite("AF-14: monitor sampler ownership characterization", .serialized)
    struct MonitorSamplerOwnershipCharacterizationTests {
        @Test("menu and settings references share one task and balance independently")
        func visibleReferenceLifecycle() {
            var counter = MonitoringReferenceCounter()

            // #expect's expansion makes `counter` immutable, so every mutating call
            // has to land in a local first.
            #expect(counter.count == 0)
            // Menu becomes visible: first owner starts the sampler.
            let menuStarted = counter.start()
            #expect(menuStarted)
            #expect(counter.count == 1)
            // Settings becomes visible: second owner shares the same task.
            let settingsStarted = counter.start()
            #expect(!settingsStarted)
            #expect(counter.count == 2)
            // Either surface may disappear first without stopping the survivor.
            let firstStopped = counter.stop()
            #expect(!firstStopped)
            #expect(counter.count == 1)
            let lastStopped = counter.stop()
            #expect(lastStopped)
            #expect(counter.count == 0)
            let extraStopped = counter.stop()
            #expect(!extraStopped)

            // Final app shutdown consumes all outstanding UI references together;
            // late SwiftUI disappear releases then remain harmless.
            let restarted = counter.start()
            #expect(restarted)
            let restartedAgain = counter.start()
            #expect(!restartedAgain)
            let didReset = counter.reset()
            #expect(didReset)
            #expect(counter.count == 0)
            let stoppedAfterReset = counter.stop()
            #expect(!stoppedAfterReset)
            let resetAfterReset = counter.reset()
            #expect(!resetAfterReset)
        }

        @Test("no visible legacy UI has zero owner while v2 has no implicit lease")
        func noUIBaselineSourceContract() throws {
            let manager = try productionSource("LiveWallpaper/App/ScreenManager.swift")
            #expect(manager.contains("setupMemoryPressureMonitoring()"))
            #expect(!manager.contains("SystemMonitor.shared.startMonitoring()"))
            #expect(!manager.contains("systemMonitorActive"))
            #expect(!manager.contains("allDisplaysAsleep"))

            let observers = try productionSource("LiveWallpaper/App/ScreenManager+MemoryPressure.swift")
            let setup = try slice(
                observers,
                from: "func setupMemoryPressureMonitoring() {",
                until: "private func applyMemoryPressureLevel"
            )
            #expect(setup.contains("memoryPressureWatcher.start"))
            #expect(!setup.contains("SystemMonitor"))
            #expect(!observers.contains("systemMemoryWarning"))
            #expect(!observers.contains("systemMemoryNormal"))

            // Monitor v2 has no implicit/global owner: no leases means no merged
            // options and therefore no pipeline.
            #expect(MonitorRuntime.merged([]) == nil)
        }

        @Test("watcher is app-lifetime across sleep wake and rejects late termination callbacks")
        @MainActor
        func memoryPressureWatcherLifecycle() async {
            let watcher = AF14MemoryPressureWatcher()
            let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
                restoreSavedWallpapers: false,
                startAutomation: false,
                powerMonitor: FakePowerMonitor(),
                fullScreenDetector: FakeFullScreenDetector(),
                playableVideoLoader: FakePlayableVideoLoader(),
                displayRegistry: FakeDisplayRegistry(),
                memoryPressureWatcher: watcher,
                featureCatalog: .unconfigured
            ))

            #expect(watcher.startCount == 1)
            #expect(watcher.stopCount == 0)
            #expect(!manager.isUnderMemoryPressure)

            watcher.emit(.warning)
            await settleMainActorTasks()
            #expect(manager.isUnderMemoryPressure)
            watcher.emit(.critical)
            await settleMainActorTasks()
            #expect(manager.isUnderMemoryPressure)
            watcher.emit(.normal)
            await settleMainActorTasks()
            #expect(!manager.isUnderMemoryPressure)

            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.screensDidSleepNotification,
                object: nil
            )
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.screensDidWakeNotification,
                object: nil
            )
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.willSleepNotification,
                object: nil
            )
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.didWakeNotification,
                object: nil
            )
            #expect(watcher.startCount == 1)
            #expect(watcher.stopCount == 0)

            manager.tearDownForTermination()
            manager.tearDownForTermination()
            #expect(watcher.startCount == 1)
            #expect(watcher.stopCount == 1)

            // `stop()` is intentionally not a callback barrier. Model a callback
            // that was already dequeued before cancellation; the MainActor owner
            // must reject it using its termination latch.
            watcher.emitLate(.critical)
            await settleMainActorTasks()
            #expect(!manager.isUnderMemoryPressure)
        }

        @Test("menu root and real settings window are the only legacy owners")
        func visibleConsumerOwnershipSourceContract() throws {
            let monitor = try productionSource(
                "Packages/LiveWallpaperProFeatures/Sources/LiveWallpaperProFeatures/SystemMonitor/SystemMonitor.swift"
            )
            let start = try slice(
                monitor,
                from: "public func startMonitoring() {",
                until: "public func stopMonitoring()"
            )
            #expect(start.contains("guard references.start() else { return }"))
            #expect(start.contains("updateTask = Task"))
            let stop = try slice(
                monitor,
                from: "public func stopMonitoring() {",
                until: "public func formattedMemoryUsage()"
            )
            #expect(stop.contains("guard references.stop() else { return }"))
            #expect(stop.contains("updateTask?.cancel()"))
            let shutdown = try slice(
                monitor,
                from: "public func shutdown() {",
                until: "public func formattedMemoryUsage()"
            )
            #expect(shutdown.contains("guard !isShutdown else { return }"))
            #expect(shutdown.contains("references.reset()"))
            #expect(shutdown.contains("updateTask?.cancel()"))

            let pill = try productionSource(
                "Packages/LiveWallpaperProFeatures/Sources/LiveWallpaperProFeatures/SystemMonitor/SystemMonitorPill.swift"
            )
            #expect(!pill.contains("startMonitoring()"))
            #expect(!pill.contains("stopMonitoring()"))
            #expect(pill.contains("SystemMonitorView("))

            let expanded = try productionSource(
                "Packages/LiveWallpaperProFeatures/Sources/LiveWallpaperProFeatures/SystemMonitor/SystemMonitorView.swift"
            )
            #expect(!expanded.contains("monitor.startMonitoring()"))
            #expect(!expanded.contains("monitor.stopMonitoring()"))

            let menu = try productionSource("LiveWallpaper/Views/MenuBarContent.swift")
            #expect(menu.contains("private var monitor: SystemMonitor { .shared }"))
            #expect(menu.contains("@State private var ownsSystemMonitorLease = false"))
            #expect(menu.contains(".onAppear(perform: acquireSystemMonitorLeaseIfNeeded)"))
            #expect(menu.contains(".onDisappear(perform: releaseSystemMonitorLeaseIfNeeded)"))

            let app = try productionSource("LiveWallpaper/App/LiveWallpaperApp.swift")
            let prewarm = try slice(
                app,
                from: "func prewarmSettingsWindow() {",
                until: "func showSettings("
            )
            #expect(!prewarm.contains("startMonitoring()"))
            let present = try slice(
                app,
                from: "private func presentSettingsWindow(",
                until: "private func postSettingsWindowRequest("
            )
            #expect(present.contains("guard window.isVisible else { return }"))
            #expect(present.contains("acquireSettingsSystemMonitorLeaseIfNeeded()"))
            #expect(present.contains("featureCatalog.isEnabled(.systemMonitor) == true"))
            #expect(present.contains("SystemMonitor.shared.startMonitoring()"))
            let close = try slice(
                app,
                from: "func windowShouldClose(",
                until: "func windowWillClose("
            )
            #expect(close.contains("releaseSettingsSystemMonitorLeaseIfNeeded()"))
            #expect(close.contains("sender.orderOut(nil)"))
            #expect(app.contains("func windowDidMiniaturize("))
            #expect(app.contains("func windowDidDeminiaturize("))
            #expect(app.contains("SystemMonitor.shared.shutdown()"))
        }

        @Test("v2 unions wallpaper overlay and HUD demand into one system concern set")
        func monitorV2DemandUnion() {
            var wallpaper = MonitorRuntimeOptions(system: true)
            wallpaper.activeWidgetKinds = [.cpu, .gpu]
            wallpaper.gpuSampleSeconds = 6

            var overlay = MonitorRuntimeOptions(system: true)
            overlay.activeWidgetKinds = [.memory, .network]
            overlay.gpuSampleSeconds = 2

            var hud = MonitorRuntimeOptions(system: false)
            hud.agents = true

            let merged = MonitorRuntime.merged([wallpaper, overlay, hud])
            #expect(merged?.system == true)
            #expect(merged?.agents == true)
            #expect(merged?.activeWidgetKinds == [.cpu, .gpu, .memory, .network])
            #expect(merged?.gpuSampleSeconds == 2)

            let gates = MonitorRuntime.systemOptions(for: merged?.activeWidgetKinds ?? [])
            #expect(gates.gpu)
            #expect(gates.topProcesses)
            #expect(gates.sensors)
            #expect(!gates.ane)
            #expect(!gates.accessories)
            #expect(!gates.processIO)
        }

        @Test("empty and agent-only widget sets do not demand system metrics")
        func agentOnlyDemandGate() {
            #expect(!MonitorWallpaperView.requiresSystemMetrics(for: []))
            #expect(!MonitorWallpaperView.requiresSystemMetrics(for: [.fleet]))
            #expect(!MonitorWallpaperView.requiresSystemMetrics(for: [.usage]))
            #expect(!MonitorWallpaperView.requiresSystemMetrics(for: [.fleet, .usage]))

            let kinds: Set<MonitorWidgetKind> = [.fleet, .usage]
            let options = MonitorRuntimeOptions(
                system: MonitorWallpaperView.requiresSystemMetrics(for: kinds),
                agents: kinds.contains(.fleet),
                usage: kinds.contains(.usage),
                activeWidgetKinds: kinds
            )
            #expect(!options.system)
            #expect(options.agents)
            #expect(options.usage)
        }

        @Test("mixed system and agent widgets keep both pipelines demanded")
        func mixedDemandGate() {
            #expect(MonitorWallpaperView.requiresSystemMetrics(for: [.cpu, .fleet]))
            #expect(MonitorWallpaperView.requiresSystemMetrics(for: [.network, .usage]))

            let kinds: Set<MonitorWidgetKind> = [.cpu, .fleet, .usage]
            let options = MonitorRuntimeOptions(
                system: MonitorWallpaperView.requiresSystemMetrics(for: kinds),
                agents: kinds.contains(.fleet),
                usage: kinds.contains(.usage),
                activeWidgetKinds: kinds
            )
            #expect(options.system)
            #expect(options.agents)
            #expect(options.usage)

            let agentKinds: Set<MonitorWidgetKind> = [.fleet, .usage]
            for kind in Set(MonitorWidgetKind.allCases).subtracting(agentKinds) {
                #expect(MonitorWallpaperView.requiresSystemMetrics(for: [kind]))
            }
        }

        @Test("v2 surface contracts show system demand and agents-only HUD")
        func monitorV2ConsumerSourceContract() throws {
            let wallpaper = try productionSource("LiveWallpaper/Monitor/MonitorWallpaperView.swift")
            let wallpaperOptions = try slice(
                wallpaper,
                from: "private func makeRuntimeOptions() -> MonitorRuntimeOptions {",
                until: "/// Repoint the shared lease"
            )
            #expect(wallpaperOptions.contains("let kinds = Set(configuration.widgets.map(\\.kind))"))
            #expect(wallpaperOptions.contains("system: Self.requiresSystemMetrics(for: kinds)"))
            #expect(!wallpaperOptions.contains("system: true"))
            #expect(wallpaperOptions.contains("activeWidgetKinds: kinds"))
            #expect(wallpaper.contains("runtimeLease.setPaused(paused)"))

            let overlay = try productionSource(
                "LiveWallpaper/Monitor/Overlay/MonitorOverlayController.swift"
            )
            let overlayOptions = try slice(
                overlay,
                from: "private func makeOptions(visibleHostIDs:",
                until: "private func scheduleRuntimeReconciliation()"
            )
            #expect(overlayOptions.contains("where visibleHostIDs.contains(screenID)"))
            #expect(overlayOptions.contains("kinds.formUnion"))
            #expect(
                overlayOptions.contains(
                    "system: MonitorWallpaperView.requiresSystemMetrics(for: kinds)"
                )
            )
            #expect(!overlayOptions.contains("system: true"))

            let hud = try productionSource("LiveWallpaper/Monitor/HUD/MonitorHUDController.swift")
            let hudAcquire = try slice(
                hud,
                from: "private func acquireRuntime() {",
                until: "private func releaseRuntime()"
            )
            #expect(
                hudAcquire.contains("MonitorRuntimeOptions(system: false, agents: true, usage: false)")
            )

            let runtime = try productionSource("LiveWallpaper/Monitor/MonitorRuntime.swift")
            let build = try slice(
                runtime,
                from: "private func performRebuild(force: Bool) async {",
                until: "static func composeUsageSnapshot("
            )
            #expect(build.contains("let target = Self.merged("))
            #expect(build.contains("if resolved.system"))
            #expect(build.contains("built.append(SystemMetricsSource("))
        }

        @Test("legacy and v2 duplicate headline system concerns when a board is active")
        func samplerConcernOverlapSourceContract() throws {
            let legacy = try productionSource(
                "Packages/LiveWallpaperProFeatures/Sources/LiveWallpaperProFeatures/SystemMonitor/SystemMonitor.swift"
            )
            let legacySample = try slice(
                legacy,
                from: "private func sampleAndApply() async {",
                until: "/// Diff guards"
            )
            for call in [
                "sampleAppCPUUsage()",
                "sampleSystemCPUUsage(prev:",
                "sampleAppMemoryUsage()",
                "sampleSystemMemoryUsage()",
                "sampleGPUUsage()",
                "ProcessInfo.processInfo.thermalState",
            ] {
                #expect(legacySample.contains(call))
            }

            let v2 = try productionSource("LiveWallpaper/Monitor/Sources/SystemMetricsSource.swift")
            let tick = try slice(
                v2,
                from: "private func tick(",
                until: "/// ANE walk fires"
            )
            for call in [
                "SystemMetricsSamplers.sampleCPU(",
                "SystemMetricsSamplers.sampleMemory()",
                "SystemMetricsSamplers.sampleNetworkCounters()",
                "SystemMetricsSamplers.sampleDiskCounters()",
                "SystemMetricsSamplers.samplePower()",
                "SystemMetricsSamplers.sampleGPU()",
                "ProcessInfo.processInfo.thermalState",
            ] {
                #expect(tick.contains(call))
            }
            #expect(tick.contains("if options.gpu"))

            let legacyConcerns: Set<SamplerConcern> = [
                .appCPU, .systemCPU, .appMemory, .systemMemory, .gpu, .thermal,
            ]
            let v2BaseConcerns: Set<SamplerConcern> = [
                .systemCPU, .systemMemory, .network, .disk, .power, .thermal,
            ]
            #expect(legacyConcerns.intersection(v2BaseConcerns) == [.systemCPU, .systemMemory, .thermal])
            #expect(
                legacyConcerns.intersection(v2BaseConcerns.union([.gpu])) == [
                    .systemCPU, .systemMemory, .gpu, .thermal,
                ]
            )
        }

        @Test("visible legacy telemetry retains App and System scope readings")
        func legacyScopeReadingsRemainAvailable() throws {
            let monitor = try productionSource(
                "Packages/LiveWallpaperProFeatures/Sources/LiveWallpaperProFeatures/SystemMonitor/SystemMonitor.swift"
            )
            for symbol in [
                "sampleAppCPUUsage()",
                "sampleSystemCPUUsage(",
                "sampleAppMemoryUsage()",
                "sampleSystemMemoryUsage()",
                "public private(set) var cpuUsage",
                "public private(set) var systemCpuUsage",
                "public private(set) var memoryUsage",
                "public private(set) var systemMemoryUsage",
            ] {
                #expect(monitor.contains(symbol))
            }

            let view = try productionSource(
                "Packages/LiveWallpaperProFeatures/Sources/LiveWallpaperProFeatures/SystemMonitor/SystemMonitorView.swift"
            )
            #expect(view.contains("@AppStorage(\"Dashboard.RAMScope\")"))
            #expect(view.contains("ramScopeRaw == \"app\" ? monitor.memoryPercentage()"))
            #expect(view.contains("ramScopeRaw == \"app\" ? monitor.cpuUsage"))
            #expect(view.contains("monitor.systemMemoryUsage * 100"))
            #expect(view.contains("monitor.systemCpuUsage"))
        }

        @MainActor
        private func settleMainActorTasks() async {
            for _ in 0 ..< 4 {
                await Task.yield()
            }
        }

        private func productionSource(_ relativePath: String) throws -> String {
            let projectRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(
                contentsOf: projectRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
        }

        private func slice(_ source: String, from start: String, until end: String) throws -> String {
            let startRange = try #require(source.range(of: start))
            let endRange = try #require(
                source.range(of: end, range: startRange.upperBound ..< source.endIndex)
            )
            return String(source[startRange.lowerBound ..< endRange.lowerBound])
        }
    }

    private final class AF14MemoryPressureWatcher: MemoryPressureWatching {
        private struct State {
            var level = SystemMemoryPressureLevel.normal
            var startCount = 0
            var stopCount = 0
            var handler: SystemMemoryPressureChangeHandler?
            var lateHandler: SystemMemoryPressureChangeHandler?
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        var startCount: Int {
            state.withLock { $0.startCount }
        }

        var stopCount: Int {
            state.withLock { $0.stopCount }
        }

        func start(onChange: SystemMemoryPressureChangeHandler?) {
            state.withLock { state in
                state.startCount += 1
                guard state.handler == nil else { return }
                state.handler = onChange
            }
        }

        func stop() {
            state.withLock { state in
                state.stopCount += 1
                state.lateHandler = state.handler
                state.handler = nil
            }
        }

        func currentLevel() -> SystemMemoryPressureLevel {
            state.withLock { $0.level }
        }

        func emit(_ level: SystemMemoryPressureLevel) {
            let handler = state.withLock { state -> SystemMemoryPressureChangeHandler? in
                state.level = level
                return state.handler
            }
            handler?(level)
        }

        func emitLate(_ level: SystemMemoryPressureLevel) {
            state.withLock { $0.lateHandler }?(level)
        }
    }

    private enum SamplerConcern: Hashable {
        case appCPU
        case systemCPU
        case appMemory
        case systemMemory
        case gpu
        case thermal
        case network
        case disk
        case power
    }
#endif
