#if !LITE_BUILD
    import Foundation
    import LiveWallpaperProWPE

    protocol SteamCMDWorkshopFileInventoryServing: AnyObject, Sendable {
        func resolveDownloadedItemFolder(
            stdout: String,
            itemID: UInt64,
            workdir: URL
        ) -> SteamCMDValidatedWorkshopItem?
        func projectFolders(
            under steamRoot: URL,
            anchoredTo trustAnchor: URL,
            skipping seen: Set<String>
        ) -> [SteamCMDValidatedWorkshopItem]
        func revalidatedURL(
            for candidate: SteamCMDValidatedWorkshopItem,
            requiringProjectJSON: Bool
        ) -> URL?
    }

    struct SteamCMDValidatedWorkshopItem: Sendable {
        let url: URL
        fileprivate let workshopID: String
        fileprivate let steamRoot: URL
        fileprivate let trustAnchor: URL
        fileprivate let identity: SteamCMDWorkshopDirectoryIdentity
    }

    enum SteamCMDWorkshopDirectoryIdentity: Equatable, Sendable {
        case resource(fileResourceIdentifier: Data, volumeIdentifier: Data)
        case deviceAndInode(deviceID: UInt64, inode: UInt64)

        var isTrusted: Bool {
            switch self {
            case let .resource(fileResourceIdentifier, volumeIdentifier):
                !fileResourceIdentifier.isEmpty && !volumeIdentifier.isEmpty
            case let .deviceAndInode(deviceID, inode):
                deviceID > 0 && inode > 0
            }
        }
    }

    typealias SteamCMDWorkshopIdentityReader = @Sendable (
        URL,
        URLResourceValues,
        FileManager
    ) -> SteamCMDWorkshopDirectoryIdentity?

    /// Owns SteamCMD Workshop path interpretation and target-only inventory reads.
    /// Callers retain security-scope ownership for user-selected work directories.
    final class SteamCMDWorkshopFileInventory: SteamCMDWorkshopFileInventoryServing, @unchecked Sendable {
        private static let wallpaperEngineAppID: UInt32 = 431_960

        private let fileManager: FileManager
        private let identityReader: SteamCMDWorkshopIdentityReader

        init(
            fileManager: FileManager = .default,
            identityReader: SteamCMDWorkshopIdentityReader? = nil
        ) {
            self.fileManager = fileManager
            self.identityReader = identityReader ?? Self.readDirectoryIdentity
        }

        /// Accepts a successful SteamCMD destination only when it is the exact item
        /// directory under either the selected workdir or our container Steam root.
        func resolveDownloadedItemFolder(
            stdout: String,
            itemID: UInt64,
            workdir: URL
        ) -> SteamCMDValidatedWorkshopItem? {
            guard let capturedPath = Self.capturedDownloadPath(stdout: stdout, itemID: itemID),
                  capturedPath.hasPrefix("/"),
                  !URL(fileURLWithPath: capturedPath).pathComponents.contains("..")
            else { return nil }

            let reported = URL(fileURLWithPath: capturedPath, isDirectory: true).standardizedFileURL
            for root in approvedSteamRoots(workdir: workdir) {
                guard let item = validatedItemDirectory(
                    workshopID: String(itemID),
                    under: root.steamRoot,
                    anchoredTo: root.trustAnchor,
                    requiringProjectJSON: false
                ),
                    reported.path(percentEncoded: false) == item.url.path(percentEncoded: false)
                else { continue }
                return item
            }
            return nil
        }

        /// Returns direct, numeric Workshop item directories with a regular
        /// `project.json`. Symlinked items and manifests are not inventory targets.
        func projectFolders(
            under steamRoot: URL,
            anchoredTo trustAnchor: URL,
            skipping seen: Set<String>
        ) -> [SteamCMDValidatedWorkshopItem] {
            guard let contentRoot = containedContentRoot(under: steamRoot, anchoredTo: trustAnchor),
                  let children = try? fileManager.contentsOfDirectory(
                      at: contentRoot,
                      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                      options: [.skipsHiddenFiles, .skipsPackageDescendants]
                  )
            else { return [] }

            return children.compactMap { child -> SteamCMDValidatedWorkshopItem? in
                let id = child.lastPathComponent
                guard !seen.contains(id) else { return nil }
                return validatedItemDirectory(
                    workshopID: id,
                    under: steamRoot,
                    anchoredTo: trustAnchor,
                    requiringProjectJSON: true
                )
            }.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        }

        /// The app's importer still consumes URLs, so this is an immediate
        /// identity/containment recheck rather than an atomic openat-style lease.
        /// Callers must invoke it directly before entering the URL callback.
        func revalidatedURL(
            for candidate: SteamCMDValidatedWorkshopItem,
            requiringProjectJSON: Bool
        ) -> URL? {
            guard let current = validatedItemDirectory(
                workshopID: candidate.workshopID,
                under: candidate.steamRoot,
                anchoredTo: candidate.trustAnchor,
                requiringProjectJSON: requiringProjectJSON
            ), current.url.path(percentEncoded: false) == candidate.url.path(percentEncoded: false),
            current.identity == candidate.identity
            else { return nil }
            return current.url
        }

        nonisolated static func capturedDownloadPath(stdout: String, itemID: UInt64) -> String? {
            let pattern = #"Success\. Downloaded item \#(itemID) to \"([^\"]+)\""#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: stdout, range: NSRange(stdout.startIndex..., in: stdout)),
                  let range = Range(match.range(at: 1), in: stdout)
            else { return nil }
            return String(stdout[range])
        }

        private func approvedSteamRoots(workdir: URL) -> [(steamRoot: URL, trustAnchor: URL)] {
            var roots = [(steamRoot: workdir, trustAnchor: workdir)]
            if let applicationSupport = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ) {
                roots.append((
                    steamRoot: applicationSupport.appendingPathComponent("Steam", isDirectory: true),
                    trustAnchor: applicationSupport
                ))
            }
            return roots
        }

        private func validatedItemDirectory(
            workshopID: String,
            under steamRoot: URL,
            anchoredTo trustAnchor: URL,
            requiringProjectJSON: Bool
        ) -> SteamCMDValidatedWorkshopItem? {
            guard Self.isNumericWorkshopID(workshopID) else { return nil }
            guard let contentRoot = containedContentRoot(under: steamRoot, anchoredTo: trustAnchor) else { return nil }
            let item = contentRoot
                .appendingPathComponent(workshopID, isDirectory: true)
                .standardizedFileURL
            guard let values = try? item.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileResourceIdentifierKey,
                .volumeIdentifierKey,
            ]),
                values.isDirectory == true,
                values.isSymbolicLink != true,
                let identity = identityReader(item, values, fileManager),
                identity.isTrusted
            else { return nil }
            let resolved = item.resolvingSymlinksInPath()
            guard WPEPathSafety.contains(resolved, in: contentRoot) else { return nil }
            if requiringProjectJSON {
                let project = resolved.appendingPathComponent("project.json", isDirectory: false)
                guard let projectValues = try? project.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]),
                    projectValues.isRegularFile == true,
                    projectValues.isSymbolicLink != true,
                    WPEPathSafety.contains(project.standardizedFileURL.resolvingSymlinksInPath(), in: resolved)
                else { return nil }
            }
            return SteamCMDValidatedWorkshopItem(
                url: resolved,
                workshopID: workshopID,
                steamRoot: steamRoot,
                trustAnchor: trustAnchor,
                identity: identity
            )
        }

        private func containedContentRoot(under steamRoot: URL, anchoredTo trustAnchor: URL) -> URL? {
            let anchor = trustAnchor.standardizedFileURL.resolvingSymlinksInPath()
            let root = steamRoot.standardizedFileURL.resolvingSymlinksInPath()
            guard WPEPathSafety.contains(root, in: anchor) else { return nil }
            let content = root
                .appendingPathComponent("steamapps", isDirectory: true)
                .appendingPathComponent("workshop", isDirectory: true)
                .appendingPathComponent("content", isDirectory: true)
                .appendingPathComponent(String(Self.wallpaperEngineAppID), isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard WPEPathSafety.contains(content, in: root) else { return nil }
            return content
        }

        private nonisolated static func isNumericWorkshopID(_ value: String) -> Bool {
            !value.isEmpty
                && UInt64(value) != nil
                && value.utf8.allSatisfy { (48 ... 57).contains($0) }
        }

        private static func readDirectoryIdentity(
            for url: URL,
            values: URLResourceValues,
            fileManager: FileManager
        ) -> SteamCMDWorkshopDirectoryIdentity? {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))
            return selectIdentity(
                fileResourceIdentifier: archivedIdentifier(values.fileResourceIdentifier),
                volumeIdentifier: archivedIdentifier(values.volumeIdentifier),
                deviceID: (attributes?[.systemNumber] as? NSNumber)?.uint64Value,
                inode: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value,
                attributesAreDirectory: attributes?[.type] as? FileAttributeType == .typeDirectory
            )
        }

        nonisolated static func selectIdentity(
            fileResourceIdentifier: Data?,
            volumeIdentifier: Data?,
            deviceID: UInt64?,
            inode: UInt64?,
            attributesAreDirectory: Bool
        ) -> SteamCMDWorkshopDirectoryIdentity? {
            if let fileResourceIdentifier, let volumeIdentifier {
                return .resource(
                    fileResourceIdentifier: fileResourceIdentifier,
                    volumeIdentifier: volumeIdentifier
                )
            }
            guard attributesAreDirectory,
                  let deviceID, deviceID > 0,
                  let inode, inode > 0
            else { return nil }
            return .deviceAndInode(deviceID: deviceID, inode: inode)
        }

        private nonisolated static func archivedIdentifier(_ value: Any?) -> Data? {
            guard let value else { return nil }
            return try? NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)
        }
    }
#endif
