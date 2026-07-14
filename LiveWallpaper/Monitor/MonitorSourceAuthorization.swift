import AppKit
import Foundation
import LiveWallpaperCore

/// Owns the optional read-only, security-scoped grants to the AI-agent log
/// roots the monitor wallpaper reads: the Claude root (`~/.claude`) and the
/// Codex root (`~/.codex`). Both live OUTSIDE the app sandbox container, so a
/// user-approved `NSOpenPanel` grant + persisted bookmark is required before
/// the agent data sources can tail them.
///
/// A missing grant is not an error — it simply means the corresponding agent
/// source reports `unauthorized` health and contributes no sessions. Only the
/// Pro `.agentFleet` capability ever surfaces the authorization UI, but this
/// store is SKU-agnostic (it compiles into Lite too and just goes unused).
///
/// Bookmark resolution goes through the shared `SecurityScopedBookmarkResolver`
/// so a stale bookmark is transparently refreshed in place; started scopes are
/// tracked and balanced on `release()`.
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

    /// Fully drops the user's grant for a provider: stops the live security
    /// scope and deletes the persisted bookmark so `isAuthorized` reads false
    /// and nothing can re-resolve it. The corresponding agent source falls back
    /// to `unauthorized` health on the next `MonitorRuntime.refreshSources()`.
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
                monitorSourcesLog.warning("🛰️ grant(\(provider.defaultDirectoryName, privacy: .public)): rejected chosen=\(url.path, privacy: .public)")
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

    /// Resolves the Claude grant into an EPHEMERAL security scope that is opened
    /// and closed entirely within `body`, without ever touching `activeScopes`.
    ///
    /// The runtime owns the long-lived scope via `resolveRoot`/`release`; a
    /// one-shot reader (e.g. session→PID focus routing) must not disturb that
    /// refcount, so this path starts its own scope on the resolved URL, runs
    /// `body`, then stops it in a `defer`. Returns `nil` (and skips `body`) when
    /// no grant is stored or the scope can't be opened.
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

    /// Resolves the stored grant, starts its security scope, and tracks it so
    /// `release()` can balance the access. Returns `nil` (source stays
    /// unauthorized) when no grant is stored or the scope can't be opened.
    private func resolveRoot(_ provider: Provider) -> URL? {
        let target = SecurityScopedBookmarkResolver.Target(label: "monitor.\(provider.defaultDirectoryName)") { [weak self] original, refreshed in
            // Compare-and-swap: only overwrite if the currently stored value is
            // still the one we resolved from, so a late refresh can't resurrect
            // a grant the user cleared or re-granted meanwhile.
            guard let self else { return }
            Task { @MainActor in
                if self.defaults.data(forKey: provider.defaultsKey) == original {
                    self.defaults.set(refreshed, forKey: provider.defaultsKey)
                }
            }
        }

        switch SecurityScopedBookmarkResolver.shared.resolve(defaults.data(forKey: provider.defaultsKey), target: target) {
        case .success(let resolved):
            // Replace any previous scope for this provider before starting a new one.
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
                monitorSourcesLog.warning("🛰️ resolve(\(provider.defaultDirectoryName, privacy: .public)): resolveFailed(\(reason, privacy: .public))")
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

    /// The grant must be the provider's own root (`~/.claude` / `~/.codex`), never
    /// a broader parent the user might pick by mistake — the scanners derive their
    /// fixed subpaths from this root, and a wider grant would hand the app a
    /// read-only sandbox extension over unrelated files for the whole pipeline.
    ///
    /// The check is STRUCTURAL and runs on the UNRESOLVED selection: the chosen
    /// folder must itself be named `.claude`/`.codex` and sit directly in the real
    /// home. Symlinks on the chosen path are deliberately NOT resolved — resolving
    /// would let a user whose `~/.claude` is a symlink to `~` (or `/`) satisfy the
    /// check by selecting the broad target, storing a home-wide bookmark. The
    /// expected root derives from the REAL home (`getpwuid`), because under
    /// app-sandbox `homeDirectoryForCurrentUser` is the container home and a
    /// container-derived comparison would reject every legitimate grant.
    private static func isExpectedRoot(_ url: URL, for provider: Provider) -> Bool {
        let chosen = url.standardizedFileURL
        // The selected folder's OWN name must match — this is what blocks picking
        // `~` or `/` (whose last component is never `.claude`/`.codex`).
        guard chosen.lastPathComponent == provider.defaultDirectoryName else { return false }
        let parent = chosen.deletingLastPathComponent().standardizedFileURL
        let home = realHomeDirectory().standardizedFileURL
        if parent.path == home.path { return true }
        // Accept a parent that only differs by symlink (a relocated/linked home),
        // now that the folder-name gate has already excluded a broad pick.
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

    /// The user's REAL home directory. Under app-sandbox both
    /// `homeDirectoryForCurrentUser` and `NSHomeDirectory()` return the
    /// container home, which would seed the grant panel at a nonexistent
    /// container `.claude` and make the expected-root check unsatisfiable.
    private static func realHomeDirectory() -> URL {
        if let dir = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
