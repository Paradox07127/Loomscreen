#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

/// UI-09 lock. Value/network/filesystem fixtures drive the production library
/// model; source contracts only inventory private SwiftUI wiring.
@Suite("Workshop Installed ownership characterization", .serialized)
struct WorkshopInstalledOwnershipCharacterizationTests {
    @Test("installed filters preserve category semantics and the current storage-location heuristic")
    func installedFilterSemantics() {
        let scene = entry(id: "100", type: .scene, location: .cache)
        let video = entry(id: "local-video", type: .video, location: .sourceFolder)
        let packagedVideo = entry(id: "300", type: .video, location: .sourceFolder)
        let app = entry(id: "200", type: .application, location: .sourceFolder)

        #expect(!WorkshopFilterMath.isNarrowing(Set<WPELibraryTypeKind>(), total: 4))
        #expect(!WorkshopFilterMath.isNarrowing(Set(WPELibraryTypeKind.allCases), total: 4))
        #expect(WorkshopFilterMath.isNarrowing(Set([WPELibraryTypeKind.scene]), total: 4))

        #expect(WPELibraryTypeKind.scene.matches(scene))
        #expect(WPELibraryTypeKind.video.matches(video))
        #expect(WPELibraryTypeKind.unsupported.matches(app))
        #expect(InstalledSource.steamWorkshop.matches(scene))
        #expect(InstalledSource.local.matches(video))
        #expect(InstalledStorageKind.managed.matches(scene))
        #expect(InstalledStorageKind.linked.matches(video))
        #expect(InstalledStorageKind.linked.matches(packagedVideo))
        // This filter is only a resourceLocation label, not a delete-ownership
        // oracle: packaged Workshop video/web may live in the app container
        // while still carrying `.sourceFolder`.
    }

    @Test("selection identity survives re-import while content refreshes")
    func selectionIdentitySurvivesReimport() {
        let old = entry(id: "100", title: "Old", importedAt: 10)
        let refreshed = entry(id: "100", title: "Refreshed", importedAt: 20)

        #expect(old.id == refreshed.id)
        #expect(old != refreshed)
        #expect([refreshed].first { $0.origin.workshopID == old.origin.workshopID } == refreshed)
    }

    @Test("Settings CAS removes only the exact import and atomically tombstones success")
    @MainActor
    func settingsIdentityAwareRemoval() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopInstalledSettingsCAS-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SettingsManager(directory: ConfigurationDirectory(root: root))
        manager.saveGlobalSettings(GlobalSettings())
        let old = entry(id: "same-id", title: "Old", importedAt: 10)
        let reimported = entry(id: "same-id", title: "New", importedAt: 20)
        manager.recordWPEImport(old)
        manager.recordWPEImport(reimported, clearsDeleteTombstone: true)

        #expect(!manager.removeWPEImport(
            workshopID: "same-id",
            matchingImportedAt: old.importedAt
        ))
        var persisted = manager.loadGlobalSettings()
        #expect(persisted.recentWPEImports == [reimported])
        #expect(!persisted.deletedWorkshopIDs.contains("same-id"))

        #expect(manager.removeWPEImport(
            workshopID: "same-id",
            matchingImportedAt: reimported.importedAt
        ))
        persisted = manager.loadGlobalSettings()
        #expect(persisted.recentWPEImports.isEmpty)
        #expect(persisted.deletedWorkshopIDs.first == "same-id")
    }

    @Test("stale delete confirmation preserves same-ID re-import bookmark and files")
    @MainActor
    func staleDeleteConfirmationIsInertAndExactConfirmationCleansUp() async throws {
        let old = entry(id: "same-id", title: "Old", type: .video, importedAt: 10)
        let reimported = entry(id: "same-id", title: "New", type: .video, importedAt: 20)
        let store = WorkshopInstalledLibraryStoreProbe(entries: [old])
        let model = WorkshopInstalledLibraryModel(
            dependencies: store.dependencies,
            lifecycleOwner: WorkshopInstalledPageLifecycleOwner(monitorHooks: .noOp)
        )
        let bookmarkPersistence = WorkshopInstalledBookmarkPersistenceProbe()
        let bookmarks = BookmarkStore(persistence: bookmarkPersistence)
        _ = bookmarks.add(
            label: "New",
            content: .video(bookmarkData: Data([0x20])),
            wpeOrigin: reimported.origin
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkshopInstalledStaleDelete-\(UUID().uuidString)", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let download = root.appendingPathComponent("download", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [cache, download] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([0xCA]).write(to: directory.appendingPathComponent("sentinel"))
        }

        var tombstones: [String] = []
        var cacheDeleteCount = 0
        var downloadDeleteCount = 0
        let services = WorkshopInstalledLibraryModel.DeleteServices(
            containsBookmark: { bookmarks.containsWPEBookmark(workshopID: $0) },
            removeBookmarks: { bookmarks.removeWPEBookmarks(workshopID: $0) },
            removeImportIfMatching: { identity in
                guard let index = store.entries.firstIndex(where: {
                    WorkshopInstalledEntryIdentity($0) == identity
                }) else { return false }
                store.entries.remove(at: index)
                tombstones.insert(identity.workshopID, at: 0)
                return true
            },
            deleteCacheFiles: { _ in
                cacheDeleteCount += 1
                try FileManager.default.removeItem(at: cache)
                return true
            },
            deleteDownloadedFolders: { _ in
                downloadDeleteCount += 1
                try? FileManager.default.removeItem(at: download)
                return 1
            }
        )

        model.onAppear()
        model.requestDelete(old)
        store.entries = [reimported]
        model.historyDidChange()
        #expect(model.pendingDelete == nil)
        model.performDelete(old, services: services)
        #expect(model.entries == [reimported])
        #expect(bookmarks.containsWPEBookmark(workshopID: "same-id"))
        #expect(tombstones.isEmpty)
        #expect(cacheDeleteCount == 0)
        #expect(downloadDeleteCount == 0)
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("sentinel").path))
        #expect(FileManager.default.fileExists(atPath: download.appendingPathComponent("sentinel").path))

        model.requestDelete(reimported)
        model.performDelete(reimported, services: services)
        await waitForDeleteDrain(model)
        #expect(store.entries.isEmpty)
        #expect(!bookmarks.containsWPEBookmark(workshopID: "same-id"))
        #expect(tombstones == ["same-id"])
        #expect(cacheDeleteCount == 1)
        #expect(downloadDeleteCount == 1)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(!FileManager.default.fileExists(atPath: download.path))
        model.onDisappear()
    }

    @Test("cache deletion is scoped to the selected managed item")
    func cacheDeleteScope() async throws {
        let fm = FileManager.default
        let fixtureRoot = fm.temporaryDirectory
            .appendingPathComponent("WorkshopInstalledDelete-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = fixtureRoot.appendingPathComponent("cache", isDirectory: true)
        let selected = cacheRoot.appendingPathComponent("100", isDirectory: true)
        let sibling = cacheRoot.appendingPathComponent("200", isDirectory: true)
        let linkedExternal = fixtureRoot.appendingPathComponent("linked-user-folder", isDirectory: true)
        defer { try? fm.removeItem(at: fixtureRoot) }

        for directory in [selected, sibling, linkedExternal] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([0xCA, 0xFE]).write(to: directory.appendingPathComponent("sentinel"))
        }

        let cache = WallpaperEngineCache(rootURL: cacheRoot)
        #expect(try await cache.deleteFiles(workshopID: "100"))
        #expect(!fm.fileExists(atPath: selected.path))
        #expect(fm.fileExists(atPath: sibling.appendingPathComponent("sentinel").path))
        #expect(fm.fileExists(atPath: linkedExternal.appendingPathComponent("sentinel").path))

        await #expect(throws: WPECacheError.self) {
            try await cache.deleteFiles(workshopID: "../linked-user-folder")
        }
        #expect(fm.fileExists(atPath: linkedExternal.appendingPathComponent("sentinel").path))
    }

    @Test("Steam metadata request and update epoch decode stay stable")
    @MainActor
    func workshopMetadataNetworkFixture() async throws {
        let endpoint = SteamWorkshopMetadataService.endpoint
        let service = metadataService { request in
            #expect(request.url == endpoint)
            #expect(request.httpMethod == "POST")
            #expect(String(data: request.httpBody ?? Data(), encoding: .utf8)
                == "itemcount=1&publishedfileids%5B0%5D=100")
            return .http(
                status: 200,
                headers: [:],
                body: Self.metadataPayload(id: "100", updated: 1_720_000_000)
            )
        }

        let result = await service.fetch(publishedFileID: 100)
        let metadata = try result.get()
        #expect(metadata.publishedFileID == 100)
        #expect(metadata.title == "Fixture")
        #expect(metadata.timeUpdated == Date(timeIntervalSince1970: 1_720_000_000))
    }

    @Test("Steam metadata maps cancellation, rate limit and transient network failure")
    @MainActor
    func workshopMetadataFailureFixtures() async {
        var service = metadataService { _ in .error(URLError(.cancelled)) }
        #expect(await service.fetch(publishedFileID: 100) == .failure(.cancelled))

        service = metadataService { _ in
            .http(status: 429, headers: ["Retry-After": "37"], body: Data())
        }
        #expect(await service.fetch(publishedFileID: 100) == .failure(.rateLimited(retryAfter: 37)))

        service = metadataService { _ in .error(URLError(.networkConnectionLost)) }
        #expect(await service.fetch(publishedFileID: 100) == .failure(.networkUnreachable))
    }

    @Test("Installed page routes state and commands through one library model")
    func lifecycleOwnerProductionWiring() throws {
        let view = try installedViewSource()
        let model = try installedModelSource()
        #expect(view.contains("@State private var model = WorkshopInstalledLibraryModel()"))
        #expect(view.contains(".onAppear { model.onAppear() }"))
        #expect(view.contains(".onDisappear { model.onDisappear() }"))
        #expect(view.contains("model.historyDidChange()"))
        #expect(!view.contains("@State private var entries"))
        #expect(!view.contains("private func checkForUpdatesIfNeeded"))
        #expect(!view.contains("private func installDragEndMonitors"))

        #expect(model.contains("@Observable"))
        #expect(model.contains("final class WorkshopInstalledLibraryModel"))
        #expect(model.contains("let lifecycleOwner: WorkshopInstalledPageLifecycleOwner"))
        #expect(model.contains("lifecycleOwner.installDragEndMonitors"))
        #expect(model.contains("lifecycleOwner.replaceUpdate"))
        #expect(model.components(separatedBy: "lifecycleOwner.canContinue(ticket)").count - 1 == 2)
        #expect(model.contains("lifecycleOwner.commitUpdate(replacement)"))
    }

    @Test("drag monitor replacement, teardown and deinit leave no dynamic monitor")
    @MainActor
    func dragMonitorLifecycleIsBounded() {
        let probe = WorkshopDragMonitorProbe()
        let hooks = WorkshopInstalledPageLifecycleOwner.DragMonitorHooks(
            installLocal: { _ in probe.install() },
            installGlobal: { _ in probe.install() },
            remove: { probe.remove($0) }
        )
        var owner: WorkshopInstalledPageLifecycleOwner? = WorkshopInstalledPageLifecycleOwner(
            monitorHooks: hooks
        )

        owner?.installDragEndMonitors {}
        #expect(owner?.activeDragMonitorCount == 2)
        #expect(probe.activeCount == 2)

        owner?.installDragEndMonitors {}
        #expect(owner?.activeDragMonitorCount == 2)
        #expect(probe.activeCount == 2)
        #expect(probe.removeCount == 2)

        owner?.tearDown()
        #expect(owner?.activeDragMonitorCount == 0)
        #expect(probe.activeCount == 0)

        owner?.installDragEndMonitors {}
        #expect(probe.activeCount == 2)
        owner = nil
        #expect(probe.activeCount == 0)
        #expect(probe.removeCount == 6)
    }

    @Test("replacement and cancellation reject late generation publication")
    @MainActor
    func updateLifecycleIsNewestWins() async {
        let owner = WorkshopInstalledPageLifecycleOwner(monitorHooks: .noOp)
        let gate = WorkshopInstalledUpdateGate()
        var publications: [String] = []

        let old = Task { @MainActor in
            await owner.replaceUpdate(operation: { _ in
                await gate.suspend("old")
            })
        }
        await gate.waitUntilSuspended("old")

        let newest = Task { @MainActor in
            await owner.replaceUpdate(operation: { _ in
                await gate.suspend("new")
            })
        }
        await gate.waitUntilSuspended("new")
        await gate.resume("new", value: "new")
        let newestResult = await newest.value
        #expect(newestResult != nil)
        if let newestResult {
            #expect(owner.commitUpdate(newestResult) { publications.append($0) })
        }
        await gate.resume("old", value: "old")
        let oldResult = await old.value
        #expect(oldResult == nil)

        #expect(publications == ["new"])
        #expect(!owner.hasActiveUpdate)

        let readyOld = Task { @MainActor in
            await owner.replaceUpdate(operation: { _ in
                await gate.suspend("ready-old")
            })
        }
        await gate.waitUntilSuspended("ready-old")
        await gate.resume("ready-old", value: "ready-old")
        let readyOldResult = await readyOld.value
        #expect(readyOldResult != nil)
        #expect(owner.hasActiveUpdate)

        let successor = Task { @MainActor in
            await owner.replaceUpdate(operation: { _ in
                await gate.suspend("successor")
            })
        }
        await gate.waitUntilSuspended("successor")
        if let readyOldResult {
            #expect(!owner.commitUpdate(readyOldResult) { publications.append($0) })
        }
        #expect(publications == ["new"])
        await gate.resume("successor", value: "successor")
        let successorResult = await successor.value
        if let successorResult {
            #expect(owner.commitUpdate(successorResult) { publications.append($0) })
        }
        #expect(publications == ["new", "successor"])

        let cancelled = Task { @MainActor in
            await owner.replaceUpdate(operation: { _ in
                await gate.suspend("cancelled")
            })
        }
        await gate.waitUntilSuspended("cancelled")
        owner.cancelUpdate()
        #expect(!owner.hasActiveUpdate)
        await gate.resume("cancelled", value: "late")
        let cancelledValue = await cancelled.value
        #expect(cancelledValue == nil)
        #expect(publications == ["new", "successor"])
    }

    @Test("Inspector load and download attempts guard every async publication boundary")
    @MainActor
    func loadAndDownloadPublicationGuards() async throws {
        let oldEntry = entry(id: "same-id", importedAt: 10)
        let reimportedEntry = entry(id: "same-id", importedAt: 20)
        let oldIdentity = WorkshopInstalledLocalInfoLoadIdentity(
            entryID: oldEntry.id,
            importedAt: oldEntry.importedAt
        )
        let reimportedIdentity = WorkshopInstalledLocalInfoLoadIdentity(
            entryID: reimportedEntry.id,
            importedAt: reimportedEntry.importedAt
        )
        #expect(oldIdentity.entryID == reimportedIdentity.entryID)
        #expect(oldIdentity != reimportedIdentity)

        let loadOwner = WorkshopInstalledLocalInfoLoadOwner()
        let gate = WorkshopInstalledUpdateGate()
        let oldTicket = loadOwner.begin(identity: oldIdentity)
        let lateOldLoad = Task { @MainActor in
            _ = await gate.suspend("old-local-info")
            return loadOwner.canPublish(oldTicket)
        }
        await gate.waitUntilSuspended("old-local-info")
        let reimportedTicket = loadOwner.begin(identity: reimportedIdentity)
        await gate.resume("old-local-info", value: "loaded")
        let oldLoadCanPublish = await lateOldLoad.value
        #expect(!oldLoadCanPublish)
        #expect(loadOwner.canPublish(reimportedTicket))
        loadOwner.invalidate()
        #expect(!loadOwner.canPublish(reimportedTicket))

        let inspector = try projectSource("LiveWallpaper/Views/Workshop/WorkshopInstalledInspector.swift")
        #expect(inspector.contains(".task(id: localInfoLoadIdentity)"))
        #expect(inspector.contains("localInfoLoadOwner.begin(identity: localInfoLoadIdentity)"))
        #expect(inspector.contains("let loadedInfo = await loadWPELocalProjectInfo(for: entry)"))
        #expect(inspector.contains("guard localInfoLoadOwner.canPublish(ticket) else { return }"))
        #expect(inspector.contains(".onDisappear { localInfoLoadOwner.invalidate() }"))

        let download = try projectSource("LiveWallpaper/Infrastructure/Workshop/WorkshopDownloadCoordinator.swift")
        let importBoundary = try sourceSlice(
            download,
            from: "let result = try? await self.importService.importProject(folder: folderURL)",
            to: "\n            }\n        )"
        )
        #expect(importBoundary.contains("guard !Task.isCancelled, self.attempts[itemID] == attemptID"))

        let doctorBoundary = try sourceSlice(
            download,
            from: "let result = await doctor.downloadWorkshopItem(",
            to: "\n        switch result"
        )
        #expect(doctorBoundary.contains("guard !Task.isCancelled, attempts[itemID] == attemptID else { return }"))
    }

    @Test("private selection and destructive orchestration retain current scope")
    func selectionAndDeleteSourceContract() throws {
        let view = try installedViewSource()
        let model = try installedModelSource()
        #expect(model.contains("if selectedEntry?.id == entry.id"))
        #expect(model.contains("selectedEntry = entries.first { $0.origin.workshopID == current.origin.workshopID }"))
        #expect(model.contains("services.removeBookmarks(workshopID)"))
        #expect(model.contains("guard services.removeImportIfMatching(identity)"))
        #expect(model.contains("services.deleteCacheFiles(workshopID)"))
        #expect(model.contains("services.deleteDownloadedFolders(workshopID)"))
        #expect(model.contains("guard canContinueDeleteCleanup(ticket)"))
        let disappear = try sourceSlice(
            model,
            from: "func onDisappear()",
            to: "func historyDidChange()"
        )
        #expect(!disappear.contains("deleteHandles"))
        #expect(view.contains("WallpaperEngineCache.shared.deleteFiles(workshopID: $0)"))
        #expect(view.contains("doctor.deleteDownloadedItemFolders(workshopID: $0)"))
        #expect(view.contains("matchingImportedAt: $0.importedAt"))
        #expect(!view.contains("removeImport: { screenManager.removeWPEImport(workshopID:"))
    }

    @Test("update policy keeps the daily throttle, partial results and retry semantics")
    func updateLifecyclePolicySourceContract() throws {
        let source = try installedModelSource()
        #expect(source.contains("private static let updateInterval: TimeInterval = 86400"))
        let update = try sourceSlice(
            source,
            from: "func checkForUpdatesIfNeeded() async",
            to: "private func scheduleUpdateCheck()"
        )
        #expect(update.contains("let snapshot = entries"))
        #expect(update.contains("let initialEpochs = cachedRemoteUpdateEpochs.filter"))
        #expect(update.contains("if case .rateLimited = error"))
        #expect(update.contains("break fetchLoop"))
        #expect(update.contains("continue"))
        #expect(update.contains("cachedRemoteUpdateEpochs = remoteEpochs"))
        let commit = try sourceSlice(
            update,
            from: "lifecycleOwner.commitUpdate(replacement)",
            to: "\n            }\n        }"
        )
        #expect(commit.contains("cachedRemoteUpdateEpochs = remoteEpochs"))
        #expect(commit.contains("dependencies.saveRemoteUpdateEpochs(remoteEpochs)"))
        #expect(update.contains("reconcileUpdateFlags()"))
        #expect(update.contains("dependencies.saveLastUpdateCheckEpoch(now)"))
    }

    @Test("production model skips fresh checks then saves stale metadata and clears re-import badge")
    @MainActor
    func productionUpdateModelThrottleCacheFlagsAndReimport() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let requests = WorkshopMetadataRequestRecorder()
        let service = metadataService { request in
            let id = requests.record(request)
            return .http(
                status: 200,
                headers: [:],
                body: Self.metadataPayload(id: id ?? "0", updated: 900_000)
            )
        }
        let old = entry(id: "100", importedAt: 100)
        let store = WorkshopInstalledLibraryStoreProbe(
            entries: [old],
            remoteEpochs: ["100": 200, "orphan": 300],
            now: now,
            lastUpdateCheckEpoch: now.timeIntervalSince1970 - 3600,
            makeMetadataService: { service }
        )
        let model = WorkshopInstalledLibraryModel(
            dependencies: store.dependencies,
            lifecycleOwner: WorkshopInstalledPageLifecycleOwner(monitorHooks: .noOp)
        )

        model.onAppear()
        await Task.yield()
        await model.checkForUpdatesIfNeeded()
        #expect(requests.ids.isEmpty)
        #expect(store.remoteSaveCount == 0)
        #expect(store.lastCheckSaveCount == 0)

        store.lastUpdateCheckEpoch = now.timeIntervalSince1970 - 86401
        await model.checkForUpdatesIfNeeded()
        #expect(requests.ids == ["100"])
        #expect(store.remoteEpochs == ["100": 900_000])
        #expect(store.remoteSaveCount == 1)
        #expect(store.lastUpdateCheckEpoch == now.timeIntervalSince1970)
        #expect(store.lastCheckSaveCount == 1)
        #expect(model.updatedWorkshopIDs == ["100"])

        store.entries = [entry(id: "100", title: "Re-imported", importedAt: 950_000)]
        model.historyDidChange()
        #expect(model.updatedWorkshopIDs.isEmpty)
        model.onDisappear()
    }

    @Test("production model preserves unvisited cache entries after 429")
    @MainActor
    func productionUpdateModelRateLimitPartialPreserve() async {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let requests = WorkshopMetadataRequestRecorder()
        let service = metadataService { request in
            switch requests.record(request) {
            case "100":
                .http(
                    status: 200,
                    headers: [:],
                    body: Self.metadataPayload(id: "100", updated: 444)
                )
            case "200":
                .http(status: 429, headers: ["Retry-After": "60"], body: Data())
            default:
                .http(status: 500, headers: [:], body: Data())
            }
        }
        let store = WorkshopInstalledLibraryStoreProbe(
            entries: [
                entry(id: "100", importedAt: 10),
                entry(id: "200", importedAt: 10),
                entry(id: "300", importedAt: 10),
            ],
            remoteEpochs: ["100": 111, "200": 222, "300": 333],
            now: now,
            lastUpdateCheckEpoch: now.timeIntervalSince1970,
            makeMetadataService: { service }
        )
        let model = WorkshopInstalledLibraryModel(
            dependencies: store.dependencies,
            lifecycleOwner: WorkshopInstalledPageLifecycleOwner(monitorHooks: .noOp)
        )

        model.onAppear()
        await Task.yield()
        store.lastUpdateCheckEpoch = now.timeIntervalSince1970 - 86401
        await model.checkForUpdatesIfNeeded()
        #expect(requests.ids == ["100", "200"])
        #expect(store.remoteEpochs == ["100": 444, "200": 222, "300": 333])
        #expect(store.remoteSaveCount == 1)
        #expect(store.lastCheckSaveCount == 1)
        #expect(model.updatedWorkshopIDs == ["100", "200", "300"])
        model.onDisappear()
    }

    @Test("library model owns filtering and refreshes same-ID selection to the new import")
    @MainActor
    func libraryModelFilterAndSelectionIdentity() {
        let old = entry(id: "100", title: "Beta", type: .scene, importedAt: 10)
        let other = entry(id: "200", title: "Alpha", type: .video, importedAt: 20)
        let store = WorkshopInstalledLibraryStoreProbe(
            entries: [old, other],
            remoteEpochs: ["100": 30]
        )
        let model = WorkshopInstalledLibraryModel(
            dependencies: store.dependencies,
            lifecycleOwner: WorkshopInstalledPageLifecycleOwner(monitorHooks: .noOp)
        )

        model.onAppear()
        model.sortOrder = .updateAvailable
        #expect(model.visibleEntries.map(\.id) == ["100", "200"])
        model.searchText = "alpha"
        #expect(model.visibleEntries.map(\.id) == ["200"])
        model.searchText = ""
        model.isolateType(.scene)
        #expect(model.visibleEntries.map(\.id) == ["100"])
        model.resetFilters()

        model.select(old)
        let reimported = entry(id: "100", title: "Beta refreshed", type: .scene, importedAt: 40)
        store.entries = [reimported, other]
        model.historyDidChange()
        #expect(model.selectedEntry == reimported)
        #expect(model.selectedEntry != old)
        model.onDisappear()
    }

    @Test("re-import and disappear reject cancellation-insensitive apply publication")
    @MainActor
    func applyPublicationUsesEntryAndAppearanceTickets() async {
        let old = entry(id: "same-id", title: "Old", importedAt: 10)
        let store = WorkshopInstalledLibraryStoreProbe(entries: [old])
        let model = WorkshopInstalledLibraryModel(
            dependencies: store.dependencies,
            lifecycleOwner: WorkshopInstalledPageLifecycleOwner(monitorHooks: .noOp)
        )
        let gate = WorkshopInstalledUpdateGate()
        model.onAppear()
        model.select(old)

        model.startApply(entry: old) {
            _ = await gate.suspend("reimport-apply")
            return true
        }
        await gate.waitUntilSuspended("reimport-apply")
        let reimported = entry(id: "same-id", title: "New", importedAt: 20)
        store.entries = [reimported]
        model.historyDidChange()
        await gate.resume("reimport-apply", value: "failed")
        await waitForCommandDrain(model)
        #expect(model.errorMessage == nil)
        #expect(model.selectedEntry == reimported)

        model.startApply(entry: reimported) {
            _ = await gate.suspend("disappear-apply")
            return true
        }
        await gate.waitUntilSuspended("disappear-apply")
        let dropTicket = model.makeDropTicket()
        model.onDisappear()
        await gate.resume("disappear-apply", value: "failed")
        await Task.yield()
        #expect(model.errorMessage == nil)
        #expect(model.activeApplyCommandCount == 0)
        #expect(model.consumeDrop(dropTicket, workshopID: reimported.id, loadFailed: false) == nil)
    }

    @Test("delete completion cannot publish over a same-ID re-import")
    @MainActor
    func deletePublicationRejectsReimport() async {
        let old = entry(id: "same-id", title: "Old", importedAt: 10)
        let store = WorkshopInstalledLibraryStoreProbe(entries: [old])
        let model = WorkshopInstalledLibraryModel(
            dependencies: store.dependencies,
            lifecycleOwner: WorkshopInstalledPageLifecycleOwner(monitorHooks: .noOp)
        )
        let gate = WorkshopInstalledUpdateGate()
        var downloadsCleanupCalled = false
        model.onAppear()
        model.select(old)

        model.performDelete(
            old,
            services: WorkshopInstalledLibraryModel.DeleteServices(
                containsBookmark: { _ in false },
                removeBookmarks: { _ in },
                removeImportIfMatching: { identity in
                    guard let index = store.entries.firstIndex(where: {
                        WorkshopInstalledEntryIdentity($0) == identity
                    }) else { return false }
                    store.entries.remove(at: index)
                    return true
                },
                deleteCacheFiles: { _ in
                    _ = await gate.suspend("delete")
                    return false
                },
                deleteDownloadedFolders: { _ in
                    downloadsCleanupCalled = true
                    return 0
                }
            )
        )
        await gate.waitUntilSuspended("delete")
        #expect(model.selectedEntry == nil)

        let reimported = entry(id: "same-id", title: "New", importedAt: 20)
        store.entries = [reimported]
        model.historyDidChange()
        #expect(model.activeDeleteCommandCount == 0)
        await gate.resume("delete", value: "failed")
        await Task.yield()
        #expect(model.errorMessage == nil)
        #expect(model.entries == [reimported])
        #expect(!downloadsCleanupCalled)
        model.onDisappear()
    }

    @Test("page disappearance rejects UI publication but does not abandon committed cleanup")
    @MainActor
    func deleteCleanupOutlivesPage() async {
        let entry = entry(id: "cleanup", importedAt: 10)
        let store = WorkshopInstalledLibraryStoreProbe(entries: [entry])
        let model = WorkshopInstalledLibraryModel(
            dependencies: store.dependencies,
            lifecycleOwner: WorkshopInstalledPageLifecycleOwner(monitorHooks: .noOp)
        )
        let gate = WorkshopInstalledUpdateGate()
        var downloadsCleanupCalled = false
        model.onAppear()

        model.performDelete(
            entry,
            services: WorkshopInstalledLibraryModel.DeleteServices(
                containsBookmark: { _ in false },
                removeBookmarks: { _ in },
                removeImportIfMatching: { identity in
                    guard let index = store.entries.firstIndex(where: {
                        WorkshopInstalledEntryIdentity($0) == identity
                    }) else { return false }
                    store.entries.remove(at: index)
                    return true
                },
                deleteCacheFiles: { _ in
                    _ = await gate.suspend("disappear-delete")
                    return false
                },
                deleteDownloadedFolders: { _ in
                    downloadsCleanupCalled = true
                    return 0
                }
            )
        )
        await gate.waitUntilSuspended("disappear-delete")
        model.onDisappear()
        #expect(model.activeDeleteCommandCount == 1)
        await gate.resume("disappear-delete", value: "done")
        await waitForDeleteDrain(model)
        #expect(downloadsCleanupCalled)
        #expect(model.errorMessage == nil)
    }

    @MainActor
    private func waitForCommandDrain(_ model: WorkshopInstalledLibraryModel) async {
        for _ in 0..<100 where model.activeApplyCommandCount != 0 {
            await Task.yield()
        }
        #expect(model.activeApplyCommandCount == 0)
    }

    @MainActor
    private func waitForDeleteDrain(_ model: WorkshopInstalledLibraryModel) async {
        for _ in 0..<100 where model.activeDeleteCommandCount != 0 {
            await Task.yield()
        }
        #expect(model.activeDeleteCommandCount == 0)
    }

    private func installedModelSource() throws -> String {
        try projectSource("LiveWallpaper/Views/Workshop/WorkshopInstalledLibraryModel.swift")
    }

    private func entry(
        id: String,
        title: String = "Fixture",
        type: WPEType = .scene,
        location: WPEResourceLocation = .cache,
        importedAt: TimeInterval = 10
    ) -> WPEHistoryEntry {
        WPEHistoryEntry(
            origin: WPEOrigin(
                workshopID: id,
                title: title,
                originalType: type,
                sourceFolderBookmark: Data("bookmark-\(id)".utf8),
                cacheRelativePath: location == .cache ? "wpe-cache/\(id)" : nil,
                previewFileName: "preview.jpg",
                entryFile: "entry",
                resourceLocation: location
            ),
            importedAt: Date(timeIntervalSince1970: importedAt)
        )
    }

    private func installedViewSource() throws -> String {
        try projectSource("LiveWallpaper/Views/Workshop/WorkshopInstalledView.swift")
    }

    private func projectSource(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceSlice(_ source: String, from start: String, to end: String) throws -> String {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    @MainActor
    private func metadataService(
        _ plan: @escaping @Sendable (URLRequest) -> WorkshopMetadataURLProtocolStub.Plan
    ) -> SteamWorkshopMetadataService {
        WorkshopMetadataURLProtocolStub.plan = plan
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkshopMetadataURLProtocolStub.self]
        return SteamWorkshopMetadataService(session: URLSession(configuration: configuration))
    }

    private static func metadataPayload(id: String, updated: Int) -> Data {
        Data("""
        {"response":{"result":1,"resultcount":1,"publishedfiledetails":[{
          "publishedfileid":"\(id)","result":1,"consumer_app_id":431960,
          "title":" Fixture ","short_description":"summary","time_updated":\(updated),
          "visibility":0,"banned":0
        }]}}
        """.utf8)
    }
}

@MainActor
private final class WorkshopInstalledLibraryStoreProbe {
    var entries: [WPEHistoryEntry]
    var remoteEpochs: [String: Double]
    var lastUpdateCheckEpoch: Double
    var now: Date
    var makeMetadataService: @MainActor () -> SteamWorkshopMetadataService
    private(set) var remoteSaveCount = 0
    private(set) var lastCheckSaveCount = 0

    init(
        entries: [WPEHistoryEntry],
        remoteEpochs: [String: Double] = [:],
        now: Date = Date(timeIntervalSince1970: 1000),
        lastUpdateCheckEpoch: Double? = nil,
        makeMetadataService: @escaping @MainActor () -> SteamWorkshopMetadataService = {
            SteamWorkshopMetadataService()
        }
    ) {
        self.entries = entries
        self.remoteEpochs = remoteEpochs
        self.now = now
        self.lastUpdateCheckEpoch = lastUpdateCheckEpoch ?? now.timeIntervalSince1970
        self.makeMetadataService = makeMetadataService
    }

    var dependencies: WorkshopInstalledLibraryModel.Dependencies {
        WorkshopInstalledLibraryModel.Dependencies(
            loadEntries: { [weak self] in self?.entries ?? [] },
            loadRemoteUpdateEpochs: { [weak self] in self?.remoteEpochs ?? [:] },
            saveRemoteUpdateEpochs: { [weak self] in
                self?.remoteEpochs = $0
                self?.remoteSaveCount += 1
            },
            loadLastUpdateCheckEpoch: { [weak self] in self?.lastUpdateCheckEpoch ?? 0 },
            saveLastUpdateCheckEpoch: { [weak self] in
                self?.lastUpdateCheckEpoch = $0
                self?.lastCheckSaveCount += 1
            },
            makeMetadataService: { [weak self] in
                self?.makeMetadataService() ?? SteamWorkshopMetadataService()
            },
            now: { [weak self] in self?.now ?? .distantPast }
        )
    }
}

@MainActor
private final class WorkshopInstalledBookmarkPersistenceProbe: BookmarkPersisting {
    private var stored: [WallpaperBookmark] = []

    func load() -> [WallpaperBookmark] {
        stored
    }

    func save(_ bookmarks: [WallpaperBookmark]) {
        stored = bookmarks
    }
}

private final class WorkshopMetadataURLProtocolStub: URLProtocol, @unchecked Sendable {
    enum Plan: @unchecked Sendable {
        case http(status: Int, headers: [String: String], body: Data)
        case error(Error)
    }

    nonisolated(unsafe) static var plan: (@Sendable (URLRequest) -> Plan)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let plan = Self.plan else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        switch plan(request) {
        case .http(let status, let headers, let body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .error(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class WorkshopMetadataRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var ids: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func record(_ request: URLRequest) -> String? {
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        let id = body?.components(separatedBy: "publishedfileids%5B0%5D=").last
        lock.lock()
        if let id {
            storage.append(id)
        }
        lock.unlock()
        return id
    }
}

@MainActor
private final class WorkshopDragMonitorProbe {
    private final class Token {}

    private var activeTokens: Set<ObjectIdentifier> = []
    private(set) var removeCount = 0

    var activeCount: Int { activeTokens.count }

    func install() -> Any {
        let token = Token()
        activeTokens.insert(ObjectIdentifier(token))
        return token
    }

    func remove(_ token: Any) {
        guard let token = token as? Token else {
            Issue.record("Unexpected drag monitor token")
            return
        }
        if activeTokens.remove(ObjectIdentifier(token)) != nil {
            removeCount += 1
        }
    }
}

private extension WorkshopInstalledPageLifecycleOwner.DragMonitorHooks {
    static var noOp: Self {
        Self(installLocal: { _ in nil }, installGlobal: { _ in nil }, remove: { _ in })
    }
}

private actor WorkshopInstalledUpdateGate {
    private var resultContinuations: [String: CheckedContinuation<String, Never>] = [:]
    private var suspendedKeys: Set<String> = []
    private var suspensionWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func suspend(_ key: String) async -> String {
        await withCheckedContinuation { continuation in
            resultContinuations[key] = continuation
            suspendedKeys.insert(key)
            suspensionWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
        }
    }

    func waitUntilSuspended(_ key: String) async {
        guard !suspendedKeys.contains(key) else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters[key, default: []].append(continuation)
        }
    }

    func resume(_ key: String, value: String) {
        suspendedKeys.remove(key)
        guard let continuation = resultContinuations.removeValue(forKey: key) else {
            Issue.record("No suspended update operation for \(key)")
            return
        }
        continuation.resume(returning: value)
    }
}
#endif
