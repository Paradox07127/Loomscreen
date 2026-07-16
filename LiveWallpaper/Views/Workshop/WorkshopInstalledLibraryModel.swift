#if !LITE_BUILD
    import AppKit
    import Foundation
    import Observation

    struct WorkshopInstalledEntryIdentity: Equatable, Hashable, Sendable {
        let workshopID: String
        let importedAt: Date

        init(_ entry: WPEHistoryEntry) {
            workshopID = entry.origin.workshopID
            importedAt = entry.importedAt
        }
    }

    /// State and command owner for the Installed page. The SwiftUI view supplies
    /// environment-bound operations, while this model owns publication lifetime.
    @MainActor
    @Observable
    final class WorkshopInstalledLibraryModel {
        struct Dependencies {
            let loadEntries: @MainActor () -> [WPEHistoryEntry]
            let loadRemoteUpdateEpochs: @MainActor () -> [String: Double]
            let saveRemoteUpdateEpochs: @MainActor ([String: Double]) -> Void
            let loadLastUpdateCheckEpoch: @MainActor () -> Double
            let saveLastUpdateCheckEpoch: @MainActor (Double) -> Void
            let makeMetadataService: @MainActor () -> SteamWorkshopMetadataService
            let now: @MainActor () -> Date

            static let live = Dependencies(
                loadEntries: { SettingsManager.shared.loadGlobalSettings().recentWPEImports },
                loadRemoteUpdateEpochs: {
                    UserDefaults.standard.dictionary(forKey: WorkshopInstalledLibraryModel.remoteUpdateEpochsKey)
                        as? [String: Double] ?? [:]
                },
                saveRemoteUpdateEpochs: {
                    UserDefaults.standard.set($0, forKey: WorkshopInstalledLibraryModel.remoteUpdateEpochsKey)
                },
                loadLastUpdateCheckEpoch: {
                    UserDefaults.standard.double(forKey: WorkshopInstalledLibraryModel.lastUpdateCheckEpochKey)
                },
                saveLastUpdateCheckEpoch: {
                    UserDefaults.standard.set($0, forKey: WorkshopInstalledLibraryModel.lastUpdateCheckEpochKey)
                },
                makeMetadataService: { SteamWorkshopMetadataService() },
                now: Date.init
            )
        }

        struct DeleteServices {
            let containsBookmark: @MainActor (String) -> Bool
            let removeBookmarks: @MainActor (String) -> Void
            let removeImportIfMatching: @MainActor (WorkshopInstalledEntryIdentity) -> Bool
            let deleteCacheFiles: @MainActor (String) async throws -> Bool
            let deleteDownloadedFolders: @MainActor (String) async -> Int
        }

        struct DropTicket: Equatable, Sendable {
            fileprivate let appearanceGeneration: UInt64
        }

        private struct DeleteTicket: Equatable, Sendable {
            let token: UUID
            let appearanceGeneration: UInt64
            let identity: WorkshopInstalledEntryIdentity
        }

        private struct DeleteHandle {
            let ticket: DeleteTicket
            let task: Task<Void, Never>
        }

        @ObservationIgnored private let dependencies: Dependencies
        @ObservationIgnored let lifecycleOwner: WorkshopInstalledPageLifecycleOwner
        @ObservationIgnored private var updateLaunchTask: Task<Void, Never>?
        @ObservationIgnored private var applyTasks: [UUID: Task<Void, Never>] = [:]
        @ObservationIgnored private var deleteHandles: [String: DeleteHandle] = [:]
        @ObservationIgnored private var appearanceGeneration: UInt64 = 0
        @ObservationIgnored private var isActive = false

        private(set) var entries: [WPEHistoryEntry] = []
        var searchText = ""
        private(set) var selectedTypes = Set(WPELibraryTypeKind.allCases)
        private(set) var selectedSources = Set(InstalledSource.allCases)
        private(set) var selectedStorage = Set(InstalledStorageKind.allCases)
        var showFilters = false
        var sortOrder: WPELibrarySortOrder = .recommended
        var errorMessage: String?
        var pendingDelete: WPEHistoryEntry?
        private(set) var selectedEntry: WPEHistoryEntry?
        var inspectorHidden = false
        private(set) var isDraggingEntry = false
        private(set) var updatedWorkshopIDs: Set<String> = []
        private var cachedRemoteUpdateEpochs: [String: Double] = [:]

        static let remoteUpdateEpochsKey = "loomscreen.workshop.updateCheck.remoteEpochs.v1"
        static let lastUpdateCheckEpochKey = "loomscreen.workshop.updateCheck.epoch.v1"
        private static let updateInterval: TimeInterval = 86400

        init(
            dependencies: Dependencies = .live,
            lifecycleOwner: WorkshopInstalledPageLifecycleOwner = WorkshopInstalledPageLifecycleOwner()
        ) {
            self.dependencies = dependencies
            self.lifecycleOwner = lifecycleOwner
        }

        deinit {
            updateLaunchTask?.cancel()
            applyTasks.values.forEach { $0.cancel() }
            deleteHandles.values.forEach { $0.task.cancel() }
        }

        var visibleEntries: [WPEHistoryEntry] {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let filtered = entries.filter { entry in
                typeMatches(entry)
                    && sourceMatches(entry)
                    && storageMatches(entry)
                    && matchesSearch(entry, query: query)
            }
            return WPEInstalledLibrarySorter.sorted(
                filtered,
                by: sortOrder,
                updatedWorkshopIDs: updatedWorkshopIDs
            )
        }

        var activeFilterCount: Int {
            var count = 0
            if WorkshopFilterMath.isNarrowing(selectedTypes, total: WPELibraryTypeKind.allCases.count) {
                count += 1
            }
            if WorkshopFilterMath.isNarrowing(selectedSources, total: InstalledSource.allCases.count) {
                count += 1
            }
            if WorkshopFilterMath.isNarrowing(selectedStorage, total: InstalledStorageKind.allCases.count) {
                count += 1
            }
            return count
        }

        var activeApplyCommandCount: Int {
            applyTasks.count
        }

        var activeDeleteCommandCount: Int {
            deleteHandles.count
        }

        func onAppear() {
            if !isActive {
                appearanceGeneration &+= 1
                isActive = true
            }
            reload()
            loadUpdateFlags()
            scheduleUpdateCheck()
        }

        func onDisappear() {
            guard isActive else { return }
            isActive = false
            appearanceGeneration &+= 1
            updateLaunchTask?.cancel()
            updateLaunchTask = nil
            lifecycleOwner.tearDown()
            applyTasks.values.forEach { $0.cancel() }
            applyTasks.removeAll()
            isDraggingEntry = false
        }

        func historyDidChange() {
            reload()
            reconcileUpdateFlags()
            refreshSelectedEntry()
            scheduleUpdateCheck()
        }

        func select(_ entry: WPEHistoryEntry) {
            if selectedEntry?.id == entry.id {
                selectedEntry = nil
            } else {
                selectedEntry = entry
                inspectorHidden = false
            }
        }

        func clearSelection() {
            selectedEntry = nil
        }

        func clearSelectionAndBrowse(tag: String, action: (String) -> Void) {
            selectedEntry = nil
            action(tag)
        }

        func requestDelete(_ entry: WPEHistoryEntry) {
            pendingDelete = entry
        }

        func cancelDelete() {
            pendingDelete = nil
        }

        func toggleType(_ kind: WPELibraryTypeKind) {
            if selectedTypes.contains(kind) {
                selectedTypes.remove(kind)
            } else {
                selectedTypes.insert(kind)
            }
        }

        func isolateType(_ kind: WPELibraryTypeKind) {
            selectedTypes = [kind]
        }

        func toggleSource(_ source: InstalledSource) {
            if selectedSources.contains(source) {
                selectedSources.remove(source)
            } else {
                selectedSources.insert(source)
            }
        }

        func isolateSource(_ source: InstalledSource) {
            selectedSources = [source]
        }

        func toggleStorage(_ storage: InstalledStorageKind) {
            if selectedStorage.contains(storage) {
                selectedStorage.remove(storage)
            } else {
                selectedStorage.insert(storage)
            }
        }

        func isolateStorage(_ storage: InstalledStorageKind) {
            selectedStorage = [storage]
        }

        func resetFilters() {
            selectedTypes = Set(WPELibraryTypeKind.allCases)
            selectedSources = Set(InstalledSource.allCases)
            selectedStorage = Set(InstalledStorageKind.allCases)
        }

        func reload() {
            entries = dependencies.loadEntries()
            invalidatePendingDeleteIfStale()
            invalidateDeletesForReimports()
        }

        func startApply(
            entry: WPEHistoryEntry,
            operation: @escaping @MainActor () async -> Bool
        ) {
            errorMessage = nil
            let token = UUID()
            let generation = appearanceGeneration
            let identity = WorkshopInstalledEntryIdentity(entry)
            let task = Task { @MainActor [weak self] in
                let failed = await operation()
                guard let self else { return }
                defer { self.applyTasks.removeValue(forKey: token) }
                guard canPublish(generation: generation, identity: identity) else { return }
                if failed {
                    errorMessage = String(
                        localized: "Couldn't apply \(entry.origin.title).",
                        comment: "Workshop installed apply failure. Placeholder is the wallpaper title."
                    )
                }
                reload()
                refreshSelectedEntry()
            }
            applyTasks[token] = task
        }

        func performDelete(_ entry: WPEHistoryEntry, services: DeleteServices) {
            errorMessage = nil
            let identity = WorkshopInstalledEntryIdentity(entry)
            pendingDelete = nil
            guard services.removeImportIfMatching(identity) else {
                reload()
                refreshSelectedEntry()
                return
            }
            if selectedEntry.map(WorkshopInstalledEntryIdentity.init) == identity {
                selectedEntry = nil
            }

            let workshopID = entry.origin.workshopID
            if services.containsBookmark(workshopID) {
                services.removeBookmarks(workshopID)
            }
            reload()

            guard !workshopID.isEmpty else { return }
            deleteHandles.removeValue(forKey: workshopID)?.task.cancel()
            let expectedToFree = deletesFiles(entry)
            let ticket = DeleteTicket(
                token: UUID(),
                appearanceGeneration: appearanceGeneration,
                identity: identity
            )
            // History/bookmark removal already committed synchronously. Keep
            // cleanup alive when the transient page disappears.
            let task = Task { @MainActor [self] in
                guard canContinueDeleteCleanup(ticket) else {
                    finishDelete(ticket)
                    return
                }
                let cacheDeleted = await (try? services.deleteCacheFiles(workshopID)) ?? false
                guard canContinueDeleteCleanup(ticket) else {
                    finishDelete(ticket)
                    return
                }
                let downloadsRemoved = await services.deleteDownloadedFolders(workshopID)
                let shouldPublish = canPublishDelete(ticket)
                finishDelete(ticket)
                guard shouldPublish else { return }
                if expectedToFree, !cacheDeleted, downloadsRemoved == 0 {
                    errorMessage = String(
                        localized: "Removed \(entry.origin.title) from the library, but its files couldn't be deleted.",
                        comment: "Workshop delete: history removed but managed files couldn't be deleted."
                    )
                }
            }
            deleteHandles[workshopID] = DeleteHandle(ticket: ticket, task: task)
        }

        func deletesFiles(_ entry: WPEHistoryEntry) -> Bool {
            let id = entry.origin.workshopID
            guard WPEPathSafety.isSafeWorkshopID(id) else { return false }
            let fileManager = FileManager.default
            if let contentRoot = WPEStoragePaths.containerWorkshopContentRoot() {
                let download = contentRoot.appendingPathComponent(id, isDirectory: true)
                if fileManager.fileExists(atPath: download.path(percentEncoded: false)) {
                    return true
                }
            }
            let cacheItem = WallpaperEngineCache.defaultRootURL.appendingPathComponent(id, isDirectory: true)
            return fileManager.fileExists(atPath: cacheItem.path(percentEncoded: false))
        }

        func showInFinder(_ entry: WPEHistoryEntry) {
            guard let folder = try? SecurityScopedBookmarkResolver.shared
                .resolve(entry.origin.sourceFolderBookmark, target: .transient).get().url
            else { return }
            let didStart = folder.startAccessingSecurityScopedResource()
            defer {
                if didStart {
                    folder.stopAccessingSecurityScopedResource()
                }
            }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }

        func toggleBookmark(_ entry: WPEHistoryEntry, store: BookmarkStore) {
            errorMessage = nil
            let workshopID = entry.origin.workshopID
            if store.containsWPEBookmark(workshopID: workshopID) {
                store.removeWPEBookmarks(workshopID: workshopID)
                return
            }
            guard let content = WPECachedContentResolver().content(for: entry.origin) else {
                errorMessage = String(
                    localized: "Couldn't add \(entry.origin.title) to Bookmarks.",
                    comment: "Workshop installed bookmark failure. Placeholder is the wallpaper title."
                )
                return
            }
            _ = store.add(
                label: entry.origin.title,
                content: content,
                sourceDisplayName: workshopID,
                wpeOrigin: entry.origin
            )
        }

        func canAddBookmark(_ entry: WPEHistoryEntry) -> Bool {
            let origin = entry.origin
            guard let entryFile = origin.entryFile, !entryFile.isEmpty else { return false }
            switch origin.resourceLocation {
            case .cache:
                return origin.originalType == .video || origin.originalType == .web || origin.originalType == .scene
            case .sourceFolder:
                return origin.originalType == .video || origin.originalType == .web
            default:
                return false
            }
        }

        func beginEntryDrag(_ entry: WPEHistoryEntry) -> String {
            isDraggingEntry = true
            lifecycleOwner.installDragEndMonitors { [weak self] in self?.endEntryDrag() }
            return entry.origin.workshopID
        }

        func endEntryDrag() {
            isDraggingEntry = false
            lifecycleOwner.removeDragEndMonitors()
        }

        func makeDropTicket() -> DropTicket {
            DropTicket(appearanceGeneration: appearanceGeneration)
        }

        func consumeDrop(
            _ ticket: DropTicket,
            workshopID: String?,
            loadFailed: Bool
        ) -> WPEHistoryEntry? {
            endEntryDrag()
            guard !loadFailed,
                  isActive,
                  ticket.appearanceGeneration == appearanceGeneration,
                  let workshopID
            else { return nil }
            return entries.first { $0.origin.workshopID == workshopID }
        }

        func checkForUpdatesIfNeeded() async {
            guard isActive else { return }
            let now = dependencies.now().timeIntervalSince1970
            guard now - dependencies.loadLastUpdateCheckEpoch() >= Self.updateInterval else { return }
            let snapshot = entries
            guard !snapshot.isEmpty else { return }

            let service = dependencies.makeMetadataService()
            let currentIDs = Set(snapshot.map(\.origin.workshopID))
            let initialEpochs = cachedRemoteUpdateEpochs.filter { currentIDs.contains($0.key) }
            let generation = appearanceGeneration

            guard let replacement = await lifecycleOwner.replaceUpdate(operation: { ticket -> [String: Double]? in
                var remoteEpochs = initialEpochs
                fetchLoop: for entry in snapshot {
                    guard self.lifecycleOwner.canContinue(ticket) else { return nil }
                    guard let id = UInt64(entry.origin.workshopID) else { continue }
                    let result = await service.fetch(publishedFileID: id)
                    guard self.lifecycleOwner.canContinue(ticket) else { return nil }
                    switch result {
                    case let .success(metadata):
                        if let remoteUpdated = metadata.timeUpdated {
                            remoteEpochs[entry.origin.workshopID] = remoteUpdated.timeIntervalSince1970
                        } else {
                            remoteEpochs.removeValue(forKey: entry.origin.workshopID)
                        }
                    case let .failure(error):
                        if case .rateLimited = error {
                            break fetchLoop
                        }
                        continue
                    }
                }
                return remoteEpochs
            }) else { return }

            lifecycleOwner.commitUpdate(replacement) { remoteEpochs in
                guard isActive, generation == appearanceGeneration else { return }
                cachedRemoteUpdateEpochs = remoteEpochs
                dependencies.saveRemoteUpdateEpochs(remoteEpochs)
                reconcileUpdateFlags()
                dependencies.saveLastUpdateCheckEpoch(now)
            }
        }

        private func scheduleUpdateCheck() {
            updateLaunchTask?.cancel()
            updateLaunchTask = Task { @MainActor [weak self] in
                await self?.checkForUpdatesIfNeeded()
            }
        }

        private func loadUpdateFlags() {
            cachedRemoteUpdateEpochs = dependencies.loadRemoteUpdateEpochs()
            reconcileUpdateFlags()
        }

        private func reconcileUpdateFlags() {
            updatedWorkshopIDs = Set(entries.compactMap { entry in
                guard let remoteEpoch = cachedRemoteUpdateEpochs[entry.origin.workshopID],
                      remoteEpoch > entry.importedAt.timeIntervalSince1970
                else { return nil }
                return entry.origin.workshopID
            })
        }

        private func refreshSelectedEntry() {
            guard let current = selectedEntry else { return }
            selectedEntry = entries.first { $0.origin.workshopID == current.origin.workshopID }
        }

        private func invalidatePendingDeleteIfStale() {
            guard let pendingDelete else { return }
            let identity = WorkshopInstalledEntryIdentity(pendingDelete)
            guard !entries.contains(where: { WorkshopInstalledEntryIdentity($0) == identity }) else { return }
            self.pendingDelete = nil
        }

        private func invalidateDeletesForReimports() {
            let staleWorkshopIDs = deleteHandles.compactMap { workshopID, handle -> String? in
                guard let current = entries.first(where: { $0.origin.workshopID == workshopID }),
                      WorkshopInstalledEntryIdentity(current) != handle.ticket.identity
                else { return nil }
                return workshopID
            }
            for workshopID in staleWorkshopIDs {
                deleteHandles.removeValue(forKey: workshopID)?.task.cancel()
            }
        }

        private func canPublish(generation: UInt64, identity: WorkshopInstalledEntryIdentity) -> Bool {
            guard isActive, generation == appearanceGeneration, !Task.isCancelled else { return false }
            guard let current = entries.first(where: { $0.origin.workshopID == identity.workshopID }) else {
                return false
            }
            return WorkshopInstalledEntryIdentity(current) == identity
        }

        private func canPublishDelete(_ ticket: DeleteTicket) -> Bool {
            guard isActive,
                  ticket.appearanceGeneration == appearanceGeneration,
                  deleteHandles[ticket.identity.workshopID]?.ticket == ticket,
                  !Task.isCancelled
            else { return false }
            guard let current = entries.first(where: { $0.origin.workshopID == ticket.identity.workshopID }) else {
                return true
            }
            return WorkshopInstalledEntryIdentity(current) == ticket.identity
        }

        /// Re-read the persisted library before every destructive phase. Page
        /// disappearance may continue cleanup; a same-ID re-import may not.
        private func canContinueDeleteCleanup(_ ticket: DeleteTicket) -> Bool {
            guard deleteHandles[ticket.identity.workshopID]?.ticket == ticket,
                  !Task.isCancelled
            else { return false }
            return !dependencies.loadEntries().contains {
                $0.origin.workshopID == ticket.identity.workshopID
            }
        }

        private func finishDelete(_ ticket: DeleteTicket) {
            guard deleteHandles[ticket.identity.workshopID]?.ticket == ticket else { return }
            deleteHandles.removeValue(forKey: ticket.identity.workshopID)
        }

        private func matchesSearch(_ entry: WPEHistoryEntry, query: String) -> Bool {
            guard !query.isEmpty else { return true }
            return entry.origin.title.localizedCaseInsensitiveContains(query)
                || entry.origin.workshopID.localizedCaseInsensitiveContains(query)
                || entry.origin.localizedDisplayTypeName.localizedCaseInsensitiveContains(query)
        }

        private func typeMatches(_ entry: WPEHistoryEntry) -> Bool {
            if selectedTypes.isEmpty || selectedTypes.count == WPELibraryTypeKind.allCases.count {
                return true
            }
            return selectedTypes.contains { $0.matches(entry) }
        }

        private func sourceMatches(_ entry: WPEHistoryEntry) -> Bool {
            if selectedSources.isEmpty || selectedSources.count == InstalledSource.allCases.count {
                return true
            }
            return selectedSources.contains { $0.matches(entry) }
        }

        private func storageMatches(_ entry: WPEHistoryEntry) -> Bool {
            if selectedStorage.isEmpty || selectedStorage.count == InstalledStorageKind.allCases.count {
                return true
            }
            return selectedStorage.contains { $0.matches(entry) }
        }
    }
#endif
