import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

/// RR-15 E2 behavior and source contracts for Monitor-overlay visibility.
@Suite("RR-15 Monitor overlay visibility lifecycle")
struct MonitorOverlayVisibilityLifecycleCharacterizationTests {
    @Test("desktop uses detector occlusion while front remains paintable")
    func levelAndDesktopSurfacePolicy() {
        let visibleDesktop = MonitorOverlayVisibilityPolicy.resolve(
            hosts: [input(1, level: .desktop, occluded: false)],
            isUserAbsent: false
        )
        #expect(
            visibleDesktop
                == decision(
                    disposition: .active,
                    visible: [1],
                    suspended: []
                )
        )

        let occludedDesktop = MonitorOverlayVisibilityPolicy.resolve(
            hosts: [input(1, level: .desktop, occluded: true)],
            isUserAbsent: false
        )
        #expect(
            occludedDesktop
                == decision(
                    disposition: .paused,
                    visible: [],
                    suspended: [1]
                )
        )

        let frontAboveOcclusion = MonitorOverlayVisibilityPolicy.resolve(
            hosts: [input(1, level: .front, occluded: true)],
            isUserAbsent: false
        )
        #expect(
            frontAboveOcclusion
                == decision(
                    disposition: .active,
                    visible: [1],
                    suspended: []
                )
        )
    }

    @Test("user absence suspends every retained host and stops delivery")
    func userAbsencePolicy() {
        let result = MonitorOverlayVisibilityPolicy.resolve(
            hosts: [
                input(1, level: .desktop, occluded: false),
                input(2, level: .front, occluded: false),
            ],
            isUserAbsent: true
        )

        #expect(
            result
                == decision(
                    disposition: .paused,
                    visible: [],
                    suspended: [1, 2]
                )
        )
        #expect(!result.pumpShouldRun)
        #expect(result.snapshotRecipientIDs.isEmpty)
    }

    @Test("mixed displays expose only paintable snapshot recipients")
    func mixedMultiScreenVisibleUnion() {
        let result = MonitorOverlayVisibilityPolicy.resolve(
            hosts: [
                input(1, level: .desktop, occluded: true),
                input(2, level: .desktop, occluded: false),
                input(3, level: .front, occluded: true),
            ],
            isUserAbsent: false
        )

        #expect(
            result
                == decision(
                    disposition: .active,
                    visible: [2, 3],
                    suspended: [1]
                )
        )
        #expect(result.pumpShouldRun)
        #expect(result.snapshotRecipientIDs == [2, 3])
    }

    @Test("host removal transitions active to paused to released")
    func hostRemovalLifecycle() {
        let both = MonitorOverlayVisibilityPolicy.resolve(
            hosts: [
                input(1, level: .desktop, occluded: true),
                input(2, level: .front, occluded: true),
            ],
            isUserAbsent: false
        )
        #expect(
            both
                == decision(
                    disposition: .active,
                    visible: [2],
                    suspended: [1]
                )
        )

        let visibleRemoved = MonitorOverlayVisibilityPolicy.resolve(
            hosts: [input(1, level: .desktop, occluded: true)],
            isUserAbsent: false
        )
        #expect(
            visibleRemoved
                == decision(
                    disposition: .paused,
                    visible: [],
                    suspended: [1]
                )
        )

        let allRemoved = MonitorOverlayVisibilityPolicy.resolve(
            hosts: [],
            isUserAbsent: false
        )
        #expect(
            allRemoved
                == decision(
                    disposition: .released,
                    visible: [],
                    suspended: []
                )
        )
    }

    @Test("controller filters options and snapshots through visible hosts")
    func controllerDeliveryContracts() throws {
        let controller = try RepositoryRoot.source(
            "LiveWallpaper/Monitor/Overlay/MonitorOverlayController.swift"
        )
        let hostState = try sourceSlice(
            controller,
            from: "private final class Host {",
            to: "private var hosts:"
        )
        let hostCreation = try sourceSlice(
            controller,
            from: "let board = MonitorBoardHostView(",
            to: "func teardown(screenID:"
        )
        let visibilityUpdate = try sourceSlice(
            controller,
            from: "func updateVisibility(",
            to: "func setEditing("
        )
        let visibilityReconcile = try sourceSlice(
            controller,
            from: "private func reconcileVisibilityAndRuntime()",
            to: "private func makeOptions("
        )
        let options = try sourceSlice(
            controller,
            from: "private func makeOptions(",
            to: "private func scheduleRuntimeReconciliation()"
        )
        let delivery = try sourceSlice(
            controller,
            from: "private func applyDeliveryState()",
            to: "private func startPump()"
        )
        let pump = try sourceSlice(
            controller,
            from: "private func startPump()",
            to: "private func stopPump()"
        )
        let prime = try sourceSlice(
            controller,
            from: "private func primeHost(_ host: Host)",
            to: "private func pushLatest(force: Bool)"
        )
        let push = try sourceBlock(
            controller,
            from: "private func pushLatest(force: Bool)"
        )

        #expect(hostState.contains("var level: MonitorOverlayLevel"))
        #expect(hostState.contains("var isVisible = false"))
        #expect(hostState.contains("var isDeliveringSnapshots = false"))

        // A new board is parked before its window is shown. Only the serialized
        // delivery step can unsuspend and prime a currently visible host.
        #expect(hostCreation.contains("board.setSuspended(true)"))
        #expect(hostCreation.contains("reconcileVisibilityAndRuntime()"))
        #expect(visibilityUpdate.contains("guard self.isUserAbsent != isUserAbsent"))
        #expect(visibilityUpdate.contains("self.occludedScreenIDs != occludedScreenIDs"))
        #expect(visibilityReconcile.contains("MonitorOverlayVisibilityPolicy.resolve"))
        #expect(visibilityReconcile.contains("host.board.setSuspended(true)"))
        #expect(visibilityReconcile.contains("stopPump()"))

        #expect(
            options.contains(
                "for (screenID, host) in hosts where visibleHostIDs.contains(screenID)"
            )
        )
        #expect(delivery.contains("host.board.setSuspended(false)"))
        #expect(delivery.contains("newlyVisibleHosts.append(host)"))
        #expect(delivery.contains("primeHost(host)"))
        #expect(pump.contains("guard pumpTask == nil"))
        #expect(pump.contains("isDeliveringSnapshots"))

        #expect(prime.contains("guard host.isVisible, host.isDeliveringSnapshots"))
        #expect(push.contains("where host.isVisible && host.isDeliveringSnapshots"))
        #expect(push.contains("host.board.push(update.snapshot)"))
    }

    @Test("one serialized task owns acquire update pause and release ordering")
    func controllerRuntimeOrderingContracts() throws {
        let controller = try RepositoryRoot.source(
            "LiveWallpaper/Monitor/Overlay/MonitorOverlayController.swift"
        )
        let scheduling = try sourceSlice(
            controller,
            from: "private func scheduleRuntimeReconciliation()",
            to: "private func desiredRuntimeState()"
        )
        let applyRuntime = try sourceSlice(
            controller,
            from: "private func applyRuntimeState(",
            to: "private func applyDeliveryState()"
        )

        #expect(scheduling.contains("runtimeReconciliationRevision &+= 1"))
        #expect(scheduling.contains("guard runtimeReconciliationTask == nil"))
        #expect(scheduling.contains("await runRuntimeReconciliationLoop()"))
        #expect(scheduling.contains("guard revision == runtimeReconciliationRevision else"))
        #expect(scheduling.contains("applyDeliveryState()"))

        #expect(applyRuntime.contains("guard let lease = appliedRuntimeState.lease else"))
        #expect(applyRuntime.contains("await lease.release().value"))
        #expect(
            applyRuntime.contains(
                "guard let lease = appliedRuntimeState.lease,"
            )
        )
        #expect(applyRuntime.contains("await lease.setPaused(true).value"))
        #expect(applyRuntime.contains("let lease = runtimeLeaseSlot.acquire(options: options)"))
        #expect(applyRuntime.contains("await lease.waitUntilSettled()"))
        #expect(
            occursBefore(
                "await lease.updateOptions(options).value",
                "await lease.setPaused(false).value",
                in: applyRuntime
            )
        )

        // Runtime calls are confined to the single reconciliation task rather
        // than launched as independent fire-and-forget operations.
        #expect(!controller.contains("Task { await MonitorRuntime.shared"))
    }

    @Test("ScreenManager bridges absence and 85-percent union occlusion")
    func screenManagerSignalBridgeContracts() throws {
        let detector = try RepositoryRoot.source(
            "Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Power/FullScreenDetector.swift"
        )
        let monitor = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+Monitor.swift"
        )
        let observers = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+Observers.swift"
        )
        let screens = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+Screens.swift"
        )
        let window = try RepositoryRoot.source(
            "LiveWallpaper/Monitor/Overlay/MonitorOverlayWindow.swift"
        )

        let overlayReconcile = try sourceSlice(
            monitor,
            from: "func reconcileMonitorOverlays()",
            to: "func refreshMonitorOverlayVisibility()"
        )
        let visibilityBridge = try sourceSlice(
            monitor,
            from: "func refreshMonitorOverlayVisibility()",
            to: "private func scheduleMonitorOverlayReconcile()"
        )
        let desktopOverlayOwner = try sourceBlock(
            monitor,
            from: "var hasEnabledDesktopMonitorOverlay: Bool"
        )
        let overlayEnable = try sourceBlock(
            monitor,
            from: "func setMonitorOverlayEnabled("
        )
        let overlayLevel = try sourceBlock(
            monitor,
            from: "func setMonitorOverlayLevel("
        )
        let absence = try sourceBlock(
            observers,
            from: "private func setUserAbsence("
        )
        let fallbackPolling = try sourceBlock(
            observers,
            from: "func updateFullScreenFallbackPolling()"
        )
        let fullScreen = try sourceSlice(
            observers,
            from: "private func handleFullScreenChange(",
            to: "private func handlePowerStateChange("
        )
        let updateFrames = try sourceBlock(
            observers,
            from: "func updateAllWindowFrames()"
        )
        let wake = try sourceBlock(
            observers,
            from: "private func handleSystemWake()"
        )
        let refreshScreens = try sourceBlock(
            screens,
            from: "func refreshScreens("
        )
        let detectorOcclusion = try sourceSlice(
            detector,
            from: "for (screenID, cgScreenFrame) in screenFrames",
            to: "updateIfChanged(result, occlusion, fractions)"
        )
        let detectorNotifications = try sourceSlice(
            detector,
            from: "private func setupNotifications()",
            to: "public var isFallbackPollingEnabled"
        )
        let windowInitialization = try sourceSlice(
            window,
            from: "init(screenFrame:",
            to: "func apply(level:"
        )

        #expect(overlayReconcile.contains("refreshMonitorOverlayVisibility()"))
        #expect(overlayReconcile.contains("fullScreenDetector.checkNow()"))
        #expect(overlayReconcile.contains("updateFullScreenFallbackPolling()"))
        #expect(visibilityBridge.contains("fullScreenDetector.isDesktopOccluded"))
        #expect(visibilityBridge.contains("isUserAbsent: isUserAbsent"))
        #expect(visibilityBridge.contains("MonitorOverlayController.shared.updateVisibility"))
        #expect(desktopOverlayOwner.contains("overlay.enabled && overlay.level == .desktop"))
        #expect(overlayEnable.contains("scheduleMonitorOverlayReconcile()"))
        #expect(overlayLevel.contains("scheduleMonitorOverlayReconcile()"))
        #expect(absence.contains("refreshMonitorOverlayVisibility()"))
        #expect(fullScreen.contains("refreshMonitorOverlayVisibility()"))
        #expect(fallbackPolling.contains("wallpaperPolicyNeedsPolling || hasEnabledDesktopMonitorOverlay"))
        #expect(updateFrames.contains("reconcileMonitorOverlays()"))
        #expect(refreshScreens.contains("updateAllWindowFrames()"))
        #expect(wake.contains("refreshScreens()"))
        #expect(occursBefore("refreshScreens()", "setUserAbsence(.systemSleep, present: false)", in: wake))

        #expect(detector.contains(".excludeDesktopElements"))
        #expect(detector.contains("Self.shouldExcludeWindowOwner(ownerName)"))
        #expect(detectorOcclusion.contains("occlusion[screenID] = fraction >= 0.85"))
        #expect(
            detectorNotifications.contains(
                "publisher(for: NSWorkspace.activeSpaceDidChangeNotification)"
            )
        )

        // The E2 bridge must not change the window's cross-Space contract.
        #expect(windowInitialization.contains(".canJoinAllSpaces"))
        #expect(windowInitialization.contains(".stationary"))
        #expect(windowInitialization.contains(".fullScreenAuxiliary"))

        // REAL-DEVICE TODO (RR-15 P2): turn off "Displays have separate Spaces"
        // and verify desktop/front visibility across full-screen Space changes.
        // Keep the current strategy until that matrix has device evidence.
    }

    @Test("ordinary Finder windows participate in desktop occlusion")
    func finderWindowOwnerPolicy() {
        #expect(!FullScreenDetector.shouldExcludeWindowOwner("Finder"))
        #expect(FullScreenDetector.shouldExcludeWindowOwner("Dock"))
        #expect(FullScreenDetector.shouldExcludeWindowOwner("Window Server"))
        #expect(FullScreenDetector.shouldExcludeWindowOwner("SystemUIServer"))
    }

    private func input(
        _ id: CGDirectDisplayID,
        level: MonitorOverlayLevel,
        occluded: Bool
    ) -> MonitorOverlayVisibilityInput {
        MonitorOverlayVisibilityInput(
            screenID: id,
            level: level,
            isDesktopOccluded: occluded
        )
    }

    private func decision(
        disposition: MonitorOverlayVisibilityDecision.RuntimeDisposition,
        visible: Set<CGDirectDisplayID>,
        suspended: Set<CGDirectDisplayID>
    ) -> MonitorOverlayVisibilityDecision {
        MonitorOverlayVisibilityDecision(
            runtimeDisposition: disposition,
            visibleHostIDs: visible,
            suspendedHostIDs: suspended
        )
    }

    private func sourceSlice(
        _ source: String,
        from startNeedle: String,
        to endNeedle: String
    ) throws -> String {
        guard let start = source.range(of: startNeedle),
              let end = source.range(
                  of: endNeedle,
                  range: start.upperBound ..< source.endIndex
              ) else {
            throw OverlayVisibilityFixtureError.missingSourceBoundary
        }
        return String(source[start.lowerBound ..< end.lowerBound])
    }

    private func sourceBlock(_ source: String, from startNeedle: String) throws -> String {
        guard let start = source.range(of: startNeedle),
              let openingBrace = source[start.lowerBound...].firstIndex(of: "{") else {
            throw OverlayVisibilityFixtureError.missingSourceBoundary
        }

        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[start.lowerBound ... index])
                }
            default:
                break
            }
            index = source.index(after: index)
        }
        throw OverlayVisibilityFixtureError.missingSourceBoundary
    }

    private func occursBefore(_ first: String, _ second: String, in source: String) -> Bool {
        guard let firstRange = source.range(of: first),
              let secondRange = source.range(of: second) else {
            return false
        }
        return firstRange.lowerBound < secondRange.lowerBound
    }
}

private enum OverlayVisibilityFixtureError: Error {
    case missingSourceBoundary
}
