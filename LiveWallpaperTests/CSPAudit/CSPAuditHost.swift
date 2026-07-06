import Foundation
import Testing
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
        // Match production: a WPE web wallpaper served in-place from `scene.pkg`
        // resolves its assets through the package, not loose files. Without this
        // the audit only ever exercises the loose-folder path and its ≥95 %
        // zero-violation gate can't observe a package-backed source. Must run
        // after `folderURL` (which clears any prior backing).
        folderHandler.setPackageBacking(Self.packageBacking(forFolder: project.folderURL))
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

    /// Parses an in-place `scene.pkg` in the project folder so the audit serves
    /// packaged web assets exactly as production does. Returns `nil` for an
    /// unpacked folder or an unreadable/invalid package (loose-folder fallback).
    private static func packageBacking(forFolder folderURL: URL) -> FolderURLSchemeHandler.PackageBacking? {
        let pkgURL = folderURL.appendingPathComponent("scene.pkg")
        guard FileManager.default.fileExists(atPath: pkgURL.path) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: pkgURL) else { return nil }
        defer { try? handle.close() }
        guard let package = try? WallpaperEnginePackage.parseIndex(streamingFrom: handle) else { return nil }
        return FolderURLSchemeHandler.PackageBacking(url: pkgURL, package: package)
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

/// Deterministic coverage for the in-place `scene.pkg` path through the CSP
/// audit host. The long-running corpus suite discovers real user wallpapers and
/// only ever set `folderURL` (loose folder) before this was added, so a
/// package-backed WPE web wallpaper — the majority of published web items — was
/// never exercised by the ≥95 % zero-violation gate. These run on synthetic
/// packages so they stay fast and hermetic (no `LW_RUN_CSP_AUDIT` gate).
@Suite("CSP audit — package-backed (wpe scene.pkg) source coverage")
@MainActor
struct CSPAuditPackageBackingTests {

    @Test("Package-backed source loads its packaged entries with zero CSP violations")
    func packageBackedSourceIsCSPClean() async throws {
        let folder = Self.makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // index.html pulls a sibling module from the SAME package: this is the
        // path that would trip a `default-src 'self'` CSP if the packaged asset
        // were served from a different origin than the document.
        let indexHTML = """
        <!doctype html><html><head><meta charset="utf-8"></head>
        <body><script src="app.js"></script></body></html>
        """
        let appJS = "window.__lwPkgLoaded__ = true;"
        try Self.writePackage(
            to: folder.appendingPathComponent("scene.pkg"),
            entries: [
                ("index.html", Data(indexHTML.utf8)),
                ("app.js", Data(appJS.utf8))
            ]
        )

        let host = CSPAuditHost(
            project: CSPAuditProject(
                workshopID: "pkg-synthetic",
                title: "packaged web wallpaper",
                folderURL: folder,
                entryFile: "index.html"
            ),
            candidate: .v2Current
        )
        let observations = try await host.runOnce(dwellSeconds: 0.5)
        let violations = observations.filter { $0.kind == .cspViolation }
        #expect(
            violations.isEmpty,
            "package-backed source reported CSP violations: \(violations.map { "\($0.directive ?? "?") → \($0.blockedURI ?? "?")" })"
        )
    }

    // MARK: - helpers

    private static func makeTemporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LWCSPPkgAudit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a minimal `PKGV0022` blob in the layout the streaming parser reads:
    /// `[magicLen|magic][count]({nameLen|name|off|size})*[payload]`.
    private static func writePackage(to pkgURL: URL, entries: [(name: String, bytes: Data)]) throws {
        var payload = Data()
        var resolved: [(name: String, offset: UInt32, size: UInt32)] = []
        for entry in entries {
            resolved.append((entry.name, UInt32(payload.count), UInt32(entry.bytes.count)))
            payload.append(entry.bytes)
        }

        var data = Data()
        func appendU32(_ value: UInt32) {
            data.append(UInt8(value & 0xff))
            data.append(UInt8((value >> 8) & 0xff))
            data.append(UInt8((value >> 16) & 0xff))
            data.append(UInt8((value >> 24) & 0xff))
        }
        let magic = Array("PKGV0022".utf8)
        appendU32(UInt32(magic.count))
        data.append(contentsOf: magic)
        appendU32(UInt32(resolved.count))
        for entry in resolved {
            let nameBytes = Array(entry.name.utf8)
            appendU32(UInt32(nameBytes.count))
            data.append(contentsOf: nameBytes)
            appendU32(entry.offset)
            appendU32(entry.size)
        }
        data.append(payload)
        try data.write(to: pkgURL)
    }
}
