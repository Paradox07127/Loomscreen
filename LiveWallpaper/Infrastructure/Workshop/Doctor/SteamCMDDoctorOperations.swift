#if !LITE_BUILD
    import Foundation

    @MainActor
    extension SteamCMDDoctorService {
        func runWallpaperEngineOwnershipProbe() async {
            guard isGreen(.cachedLogin) else {
                setProbe(.wallpaperEngineOwnership, status: .yellow(
                    message: "Cached Steam login must pass before ownership can be checked.",
                    command: nil
                ))
                return
            }

            do {
                try await operationCoordinator.withOperation(.ownershipValidation) { [weak self] lease in
                    guard let self else { return }
                    await performWallpaperEngineOwnershipProbe(
                        authorization: lease.filesystemMutation
                    )
                }
            } catch is CancellationError {
                setProbe(.wallpaperEngineOwnership, status: .yellow(
                    message: "Ownership check was cancelled.",
                    command: nil
                ))
            } catch {
                setProbe(.wallpaperEngineOwnership, status: .red(
                    message: redacted(error.localizedDescription),
                    command: nil
                ))
            }
        }

        private func performWallpaperEngineOwnershipProbe(
            authorization: SteamCMDDoctorFilesystemMutationLease
        ) async {
            do {
                let binary = try resolveBinaryURL()
                let workdir = try resolveWorkdirURL()
                guard let username else {
                    setProbe(.wallpaperEngineOwnership, status: .yellow(
                        message: "Enter your Steam username before checking ownership.",
                        command: nil
                    ))
                    return
                }

                let owner = WPEEngineAssetsFilesystemOwner(fileManager: fileManager)
                await Task.detached(priority: .utility) {
                    owner.cleanupSteamCMDAppState(authorization: authorization)
                }.value

                var removedIDs: [UInt64] = []
                for itemID in Self.ownershipProbeCandidateIDs {
                    let script = try SteamCMDScriptWriter.ownershipProbeScript(
                        username: username,
                        itemID: itemID
                    )
                    let result = try await runSteamCMDScript(
                        script,
                        binary: binary,
                        workdir: workdir,
                        timeout: 90
                    )
                    if result.stdout.range(
                        of: #"Success\. Downloaded item \#(itemID) to "#,
                        options: .regularExpression
                    ) != nil {
                        setProbe(.wallpaperEngineOwnership, status: .green(
                            detail: "Your Steam account has access to Wallpaper Engine downloads."
                        ))
                        return
                    }
                    if result.stdout.contains("ERROR! Download item \(itemID) failed (No Connection).") {
                        setProbe(.wallpaperEngineOwnership, status: .red(
                            message: "This Steam account doesn't own Wallpaper Engine, or downloads are restricted in your region.",
                            command: "steam://store/\(Self.wallpaperEngineAppID)"
                        ))
                        return
                    }
                    if result.stdout.contains("ERROR! Download item \(itemID) failed (No match).") {
                        removedIDs.append(itemID)
                        continue
                    }
                    if result.stdout.contains("ERROR! Download item \(itemID) failed (Failure).") || result.timedOut {
                        setProbe(.wallpaperEngineOwnership, status: .yellow(
                            message: "Steam is temporarily unreachable. Workshop downloads may be unavailable right now.",
                            command: nil
                        ))
                        return
                    }
                    setProbe(.wallpaperEngineOwnership, status: .yellow(
                        message: "Ownership probe returned an unrecognized response. Use Export diagnostics for the raw output.",
                        command: nil
                    ))
                    return
                }

                setProbe(.wallpaperEngineOwnership, status: .yellow(
                    message: "All built-in ownership probe items appear to have been removed from Steam: \(removedIDs.map(String.init).joined(separator: ", ")).",
                    command: nil
                ))
            } catch SteamCMDScriptError.invalidUsername {
                setProbe(.wallpaperEngineOwnership, status: .red(
                    message: "Steam username must match ^[A-Za-z0-9_]{1,32}$.",
                    command: nil
                ))
            } catch {
                setProbe(.wallpaperEngineOwnership, status: .red(
                    message: redacted(error.localizedDescription),
                    command: nil
                ))
            }
        }

        func updateWallpaperEngineApp(
            onProgress: SteamCMDProgressHandler? = nil,
            inheriting operationLease: SteamCMDDoctorOperationLease? = nil
        ) async -> WPEAppUpdateResult {
            do {
                return try await operationCoordinator.withOperation(
                    .appUpdate,
                    inheriting: operationLease
                ) { [weak self] _ in
                    guard let self else { return .failed(reason: "Update owner was released.") }
                    return await performWallpaperEngineAppUpdate(onProgress: onProgress)
                }
            } catch is CancellationError {
                return .failed(reason: "Download cancelled.")
            } catch {
                return .failed(reason: redacted(error.localizedDescription))
            }
        }

        private func performWallpaperEngineAppUpdate(
            onProgress: SteamCMDProgressHandler?
        ) async -> WPEAppUpdateResult {
            guard binaryBookmarkData != nil else {
                return .notConfigured(
                    reason: SteamCMDDoctorError.missingBinaryBinding.errorDescription
                        ?? "No SteamCMD binary is selected."
                )
            }
            guard workdirBookmarkData != nil else {
                return .notConfigured(
                    reason: SteamCMDDoctorError.missingWorkdirBinding.errorDescription
                        ?? "No SteamCMD working directory is selected."
                )
            }
            guard let username, SteamCMDScriptWriter.validateUsername(username) else {
                return .notConfigured(reason: "Enter your Steam username in the SteamCMD Doctor first.")
            }
            guard isGreen(.cachedLogin) else { return .loginRequired }

            do {
                let binary = try resolveBinaryURL()
                guard await ensureTrustedBinary(binary) else { return .untrustedBinary }
                let workdir = try resolveWorkdirURL()
                let workdirScope = workdir.startAccessingSecurityScopedResource()
                defer {
                    if workdirScope {
                        workdir.stopAccessingSecurityScopedResource()
                    }
                }

                let script = try SteamCMDScriptWriter.appUpdateScript(username: username)
                let result = try await runSteamCMDScript(
                    script,
                    binary: binary,
                    workdir: workdir,
                    timeout: Self.appUpdateTimeout,
                    onProgress: onProgress
                )

                if result.timedOut {
                    return .timedOut
                }
                if Task.isCancelled || result.killed {
                    return .failed(reason: "Download cancelled.")
                }

                let out = result.stdout
                if let installRoot = Self.resolveWPEInstallRoot(
                    workdir: workdir,
                    fileManager: fileManager
                ),
                    Self.isWPEContentComplete(installRoot: installRoot, fileManager: fileManager),
                    Self.isWPEStagingComplete(installRoot: installRoot, fileManager: fileManager) {
                    let buildID = Self.readInstalledBuildID(
                        installRoot: installRoot,
                        fileManager: fileManager
                    )
                    return .updated(installRoot: installRoot, buildID: buildID)
                }
                if out.contains("No subscription") {
                    return .notEntitled
                }
                return .failed(
                    reason: "SteamCMD didn't produce a complete Wallpaper Engine asset tree. Open the Doctor and use Export diagnostics for the raw output."
                )
            } catch SteamCMDScriptError.invalidUsername {
                return .notConfigured(reason: "Steam username must match ^[A-Za-z0-9_]{1,32}$.")
            } catch {
                return .failed(reason: redacted(error.localizedDescription))
            }
        }

        @discardableResult
        func deleteDownloadedItemFolders(workshopID: String) async -> Int {
            do {
                return try await operationCoordinator.withOperation(.workshopCleanup) { [weak self] lease in
                    guard let self else { return 0 }
                    return await performDeleteDownloadedItemFolders(
                        workshopID: workshopID,
                        authorization: lease.filesystemMutation
                    )
                }
            } catch {
                return 0
            }
        }

        private func performDeleteDownloadedItemFolders(
            workshopID: String,
            authorization: SteamCMDDoctorFilesystemMutationLease
        ) async -> Int {
            guard authorization.isActive,
                  authorization.kind == .workshopCleanup else { return 0 }
            guard WPEPathSafety.isSafeWorkshopID(workshopID) else { return 0 }
            let appSupport = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
            let workdir = (try? resolveWorkdirURL()).flatMap {
                WPEEngineAssetsLibrary.isContainerInternal($0) ? $0 : nil
            }
            let owner = SteamCMDWorkshopCleanupFilesystemOwner(fileManager: fileManager)
            return await Task.detached(priority: .utility) {
                owner.deleteDownloadedItemFolders(
                    workshopID: workshopID,
                    appSupport: appSupport,
                    scopedWorkdir: workdir,
                    authorization: authorization
                )
            }.value
        }
    }

    private struct SteamCMDWorkshopCleanupFilesystemOwner: @unchecked Sendable {
        private struct LiteralIdentity {
            let identifier: NSObject
            let isDirectory: Bool

            func matches(_ other: LiteralIdentity) -> Bool {
                isDirectory == other.isDirectory && identifier.isEqual(other.identifier)
            }
        }

        let fileManager: FileManager

        func deleteDownloadedItemFolders(
            workshopID: String,
            appSupport: URL?,
            scopedWorkdir: URL?,
            authorization: SteamCMDDoctorFilesystemMutationLease
        ) -> Int {
            guard authorization.isActive,
                  authorization.kind == .workshopCleanup,
                  WPEPathSafety.isSafeWorkshopID(workshopID) else { return 0 }
            var deleted = 0
            if let appSupport {
                let safeAppSupport = appSupport.standardizedFileURL.resolvingSymlinksInPath()
                // Resolve the Steam root and anchor it back under Application Support:
                // a symlinked `Steam` must not re-base the delete outside the container.
                // (WPEPathSafety.contains is a pure prefix check, so resolve first.)
                let steam = safeAppSupport
                    .appendingPathComponent("Steam", isDirectory: true)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                if WPEPathSafety.contains(steam, in: safeAppSupport),
                   deleteItemFolder(
                    workshopID: workshopID,
                    under: steam,
                    authorization: authorization
                ) {
                    deleted += 1
                }
            }
            if let workdir = scopedWorkdir {
                let scope = workdir.startAccessingSecurityScopedResource()
                defer {
                    if scope {
                        workdir.stopAccessingSecurityScopedResource()
                    }
                }
                if deleteItemFolder(
                    workshopID: workshopID,
                    under: workdir,
                    authorization: authorization
                ) {
                    deleted += 1
                }
            }
            return deleted
        }

        private func workshopContentRoot(under base: URL) -> URL {
            base.appendingPathComponent("steamapps", isDirectory: true)
                .appendingPathComponent("workshop", isDirectory: true)
                .appendingPathComponent("content", isDirectory: true)
                .appendingPathComponent("431960", isDirectory: true)
        }

        private func deleteItemFolder(
            workshopID: String,
            under base: URL,
            authorization: SteamCMDDoctorFilesystemMutationLease
        ) -> Bool {
            guard authorization.isActive,
                  authorization.kind == .workshopCleanup else { return false }
            let safeBase = base.standardizedFileURL.resolvingSymlinksInPath()
            let literalContentRoot = workshopContentRoot(under: safeBase).standardizedFileURL
            let resolvedContentRoot = literalContentRoot.resolvingSymlinksInPath()
            guard literalPath(literalContentRoot) == literalPath(resolvedContentRoot),
                  WPEPathSafety.contains(resolvedContentRoot, in: safeBase) else { return false }

            let item = literalContentRoot
                .appendingPathComponent(workshopID, isDirectory: true)
                .standardizedFileURL
            guard WPEPathSafety.contains(item, in: literalContentRoot),
                  literalPath(item) == literalPath(item.resolvingSymlinksInPath()),
                  let original = literalIdentity(at: item),
                  original.isDirectory,
                  let current = literalIdentity(at: item),
                  original.matches(current) else { return false }
            do {
                try fileManager.removeItem(at: item)
                return true
            } catch {
                return false
            }
        }

        private func literalIdentity(at url: URL) -> LiteralIdentity? {
            guard let values = try? url.resourceValues(forKeys: [
                .fileResourceIdentifierKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]),
                values.isSymbolicLink != true,
                let identifier = values.fileResourceIdentifier as? NSObject else { return nil }
            return LiteralIdentity(
                identifier: identifier,
                isDirectory: values.isDirectory == true
            )
        }

        private func literalPath(_ url: URL) -> String {
            var path = url.standardizedFileURL.path(percentEncoded: false)
            while path.count > 1, path.hasSuffix("/") {
                path.removeLast()
            }
            return path
        }
    }
#endif
