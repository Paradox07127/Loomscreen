import AppKit
import Foundation
import LiveWallpaperCore

/// Owns the optional read-only, security-scoped grants to the AI-agent log roots the monitor wallpaper reads: the Claude root (`~/.claude`) and the Codex root (`~/.codex`).
@MainActor
final class MonitorSourceAuthorization {
    static let shared = MonitorSourceAuthorization()

    enum Provider: CaseIterable {
        case claude
        case codex

        var defaultsKey: String {
            switch self {
            case .claude: return "monitor.source.claude.bookmark"
            case .codex:  return "monitor.source.codex.bookmark"
            }
        }

        /// Home-relative default the open panel is seeded with and the folder
        /// whose grant is being requested.
        var defaultDirectoryName: String {
            switch self {
            case .claude: return ".claude"
            case .codex:  return ".codex"
            }
        }
    }

    private let defaults: UserDefaults
    /// Scopes we have called `startAccessingSecurityScopedResource()` on and
    /// still owe a matching stop for, keyed by provider.
    private var activeScopes: [Provider: URL] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Authorization state

    func isAuthorized(_ provider: Provider) -> Bool {
        defaults.data(forKey: provider.defaultsKey) != nil
    }

    // MARK: - Grant

    func requestClaudeAccess(from window: NSWindow?, onGrant: (@MainActor () -> Void)? = nil) {
        requestAccess(for: .claude, from: window, onGrant: onGrant)
    }

    func requestCodexAccess(from window: NSWindow?, onGrant: (@MainActor () -> Void)? = nil) {
        requestAccess(for: .codex, from: window, onGrant: onGrant)
    }

    // MARK: - Revoke

    /// Fully drops the user's grant for a provider: stops the live security scope and deletes the persisted bookmark so `isAuthorized` reads false and nothing can re-resolve it.
    func revokeAccess(_ provider: Provider) {
        stopAccessing(provider)
        defaults.removeObject(forKey: provider.defaultsKey)
        Logger.info("Monitor: revoked grant for \(provider.defaultDirectoryName)", category: .fileAccess)
    }

    private func requestAccess(for provider: Provider, from window: NSWindow?, onGrant: (@MainActor () -> Void)?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = Self.defaultDirectory(for: provider)
        panel.prompt = String(
            localized: "Grant Access",
            defaultValue: "Grant Access",
            comment: "Confirm button in the monitor wallpaper's AI-log folder access panel."
        )
        panel.message = String(
            localized: "Choose the folder to read agent activity from (read-only, for the monitor wallpaper).",
            defaultValue: "Choose the folder to read agent activity from (read-only, for the monitor wallpaper).",
            comment: "Explanatory message in the monitor wallpaper's AI-log folder access panel."
        )

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard Self.isExpectedRoot(url, for: provider) else {
                monitorSourcesLog.warning("🛰️ grant(\(provider.defaultDirectoryName, privacy: .public)): rejected unexpected folder")
                self.presentWrongFolderAlert(for: provider, chosen: url, window: window)
                return
            }
            if self.storeBookmark(for: provider, url: url) {
                monitorSourcesLog.info("🛰️ grant(\(provider.defaultDirectoryName, privacy: .public)): accepted")
                onGrant?()
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    @discardableResult
    private func storeBookmark(for provider: Provider, url: URL) -> Bool {
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: provider.defaultsKey)
            Logger.info("Monitor: stored read-only grant for \(provider.defaultDirectoryName)", category: .fileAccess)
            return true
        } catch {
            Logger.error("Monitor: failed to bookmark \(provider.defaultDirectoryName): \(error.localizedDescription)", category: .fileAccess)
            return false
        }
    }

    // MARK: - Resolution

    func resolveClaudeRoot() -> URL? {
        resolveRoot(.claude)
    }

    func resolveCodexRoot() -> URL? {
        resolveRoot(.codex)
    }

    /// Resolves the Claude grant into an EPHEMERAL security scope that is opened and closed entirely within `body`, without ever touching `activeScopes`.
    func withResolvedClaudeRoot<T>(_ body: (URL) throws -> T) rethrows -> T? {
        let provider = Provider.claude
        let target = SecurityScopedBookmarkResolver.Target(label: "monitor.\(provider.defaultDirectoryName).ephemeral") { [weak self] original, refreshed in
            guard let self else { return }
            Task { @MainActor in
                if self.defaults.data(forKey: provider.defaultsKey) == original {
                    self.defaults.set(refreshed, forKey: provider.defaultsKey)
                }
            }
        }

        guard case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
            defaults.data(forKey: provider.defaultsKey),
            target: target
        ) else {
            return nil
        }
        guard resolved.url.startAccessingSecurityScopedResource() else {
            Logger.warning("Monitor: ephemeral startAccessingSecurityScopedResource failed for \(provider.defaultDirectoryName)", category: .fileAccess)
            return nil
        }
        defer { resolved.url.stopAccessingSecurityScopedResource() }
        return try body(resolved.url)
    }

    /// Resolves the stored grant, starts its security scope, and tracks it so `release()` can balance the access.
    private func resolveRoot(_ provider: Provider) -> URL? {
        let target = SecurityScopedBookmarkResolver.Target(label: "monitor.\(provider.defaultDirectoryName)") { [weak self] original, refreshed in
            guard let self else { return }
            Task { @MainActor in
                if self.defaults.data(forKey: provider.defaultsKey) == original {
                    self.defaults.set(refreshed, forKey: provider.defaultsKey)
                }
            }
        }

        switch SecurityScopedBookmarkResolver.shared.resolve(defaults.data(forKey: provider.defaultsKey), target: target) {
        case .success(let resolved):
            stopAccessing(provider)
            guard resolved.url.startAccessingSecurityScopedResource() else {
                Logger.warning("Monitor: startAccessingSecurityScopedResource failed for \(provider.defaultDirectoryName)", category: .fileAccess)
                monitorSourcesLog.warning("🛰️ resolve(\(provider.defaultDirectoryName, privacy: .public)): scopeStartFailed")
                return nil
            }
            activeScopes[provider] = resolved.url
            monitorSourcesLog.info("🛰️ resolve(\(provider.defaultDirectoryName, privacy: .public)): ok")
            return resolved.url
        case .failure(let failure):
            if case .resolutionFailed(let reason) = failure {
                Logger.warning("Monitor: \(provider.defaultDirectoryName) grant unresolved: \(reason)", category: .fileAccess)
                monitorSourcesLog.warning("🛰️ resolve(\(provider.defaultDirectoryName, privacy: .public)): resolveFailed")
            } else {
                monitorSourcesLog.info("🛰️ resolve(\(provider.defaultDirectoryName, privacy: .public)): missing (no grant stored)")
            }
            return nil
        }
    }

    // MARK: - Scope lifecycle

    private func stopAccessing(_ provider: Provider) {
        if let url = activeScopes.removeValue(forKey: provider) {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Balances every started scope. Called when the wallpaper session tears
    /// down so the sandbox extensions don't leak past the wallpaper's life.
    func release() {
        for (_, url) in activeScopes {
            url.stopAccessingSecurityScopedResource()
        }
        activeScopes.removeAll()
    }

    // MARK: - Selection validation

    /// Accepts only the provider root to avoid granting a broader sandbox extension.
    private static func isExpectedRoot(_ url: URL, for provider: Provider) -> Bool {
        let chosen = url.standardizedFileURL
        // The selected folder's OWN name must match — this is what blocks picking
        // `~` or `/` (whose last component is never `.claude`/`.codex`).
        guard chosen.lastPathComponent == provider.defaultDirectoryName else { return false }
        let parent = chosen.deletingLastPathComponent().standardizedFileURL
        let home = realHomeDirectory().standardizedFileURL
        if parent.path == home.path { return true }
        return parent.resolvingSymlinksInPath().standardizedFileURL.path
            == home.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func presentWrongFolderAlert(for provider: Provider, chosen: URL, window: NSWindow?) {
        Logger.warning("Monitor: rejected grant outside \(provider.defaultDirectoryName): \(chosen.path)", category: .fileAccess)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "That's not the expected folder",
            defaultValue: "That's not the expected folder",
            comment: "Monitor wallpaper AI-log access: title shown when the user grants a folder other than the provider's own root."
        )
        alert.informativeText = String(
            localized: "Choose your \(provider.defaultDirectoryName) folder in your home directory. A wider folder can't be granted for the monitor wallpaper.",
            comment: "Monitor wallpaper AI-log access: explanation shown when the chosen folder is not the provider root; %@ is a folder name like .claude or .codex."
        )
        alert.addButton(withTitle: String(
            localized: "OK",
            defaultValue: "OK",
            comment: "Dismiss button on the monitor wallpaper wrong-folder alert."
        ))
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Defaults

    private static func defaultDirectory(for provider: Provider) -> URL {
        realHomeDirectory()
            .appendingPathComponent(provider.defaultDirectoryName, isDirectory: true)
    }

    /// The user's REAL home directory.
    private static func realHomeDirectory() -> URL {
        if let dir = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
