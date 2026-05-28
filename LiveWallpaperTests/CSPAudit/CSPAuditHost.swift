import Foundation
import WebKit
@testable import LiveWallpaper

/// Single-shot audit runner: load one wallpaper project under one CSP
/// candidate, dwell, collect violations, return them. Re-instantiate for
/// each (project, candidate) pair so leftover state from a previous run
/// can't contaminate the next.
@MainActor
final class CSPAuditHost {
    let project: CSPAuditProject
    let candidate: CSPAuditCandidate
    private let webView: WKWebView
    private let folderHandler: FolderURLSchemeHandler
    private let collector: CSPViolationCollector

    init(project: CSPAuditProject, candidate: CSPAuditCandidate) {
        self.project = project
        self.candidate = candidate

        let collector = CSPViolationCollector()
        self.collector = collector

        let config = WKWebViewConfiguration()
        // Mirror production preferences enough to make the wallpaper
        // believe it's in its normal WKWebView host.
        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = pagePrefs
        config.mediaTypesRequiringUserActionForPlayback = []
        // **Always ephemeral** — keeps audit runs independent.
        config.websiteDataStore = .nonPersistent()

        let userScript = WKUserScript(
            source: CSPViolationCollector.instrumentationSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(userScript)
        config.userContentController.add(collector, name: CSPViolationCollector.messageHandlerName)

        let handler = FolderURLSchemeHandler()
        handler.cspOverride = FolderURLSchemeHandler.ContentSecurityPolicyOverride(
            directives: candidate.directives,
            disposition: .reportOnly
        )
        self.folderHandler = handler
        config.setURLSchemeHandler(handler, forURLScheme: FolderURLSchemeHandler.scheme)

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        self.webView = webView
    }

    deinit {
        // No explicit teardown needed — ephemeral data store + the per-host
        // WKWebView are GC'd with the host. The userContentController is owned
        // by `config`, which is owned by the WKWebView.
    }

    /// Loads the project, waits `dwell` seconds, then returns the collected
    /// observations. Throws if the project bundle is malformed.
    func runOnce(dwellSeconds: TimeInterval) async throws -> [CSPViolationCollector.Observation] {
        folderHandler.folderURL = project.folderURL
        guard let nonce = folderHandler.currentSessionNonce else {
            throw AuditError.missingSessionNonce
        }

        let entry = project.entryFile.isEmpty ? "index.html" : project.entryFile
        guard let entryURL = URL(string: "\(FolderURLSchemeHandler.scheme)://\(FolderURLSchemeHandler.host)/\(entry)?n=\(nonce)") else {
            throw AuditError.malformedEntryURL
        }
        webView.load(URLRequest(url: entryURL))
        try await Task.sleep(nanoseconds: UInt64(dwellSeconds * 1_000_000_000))
        // Snapshot observations (avoid handing out the live mutable array).
        let snapshot = collector.observations
        return snapshot
    }

    enum AuditError: Error {
        case missingSessionNonce
        case malformedEntryURL
    }
}

/// A wallpaper sitting under `~/Documents/Live Wallpapers/431960/<id>/`.
/// We deliberately don't reuse `WallpaperEngineLibraryScanner` — it
/// rejects symlinks and runs file-resource queries we don't need. The
/// audit just wants `(id, folderURL, entryFile)`.
struct CSPAuditProject: Sendable, Equatable {
    let workshopID: String
    let title: String
    let folderURL: URL
    let entryFile: String
}
