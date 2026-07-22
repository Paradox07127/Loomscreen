import Foundation
import Testing
import WebKit
@testable import LiveWallpaper

/// Runs one project-policy pair in an isolated web view and returns its audit observations.
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
        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = pagePrefs
        config.mediaTypesRequiringUserActionForPlayback = []
        // A nonpersistent store prevents state from contaminating later audit cases.
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

    /// Loads the project and collects observations for the requested dwell interval.
    func runOnce(dwellSeconds: TimeInterval) async throws -> [CSPViolationCollector.Observation] {
        folderHandler.folderURL = project.folderURL
        // Set package backing after folderURL because assigning the folder clears existing backing.
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
        let snapshot = collector.observations
        return snapshot
    }

    /// Returns package backing when the project contains a valid in-place `scene.pkg`.
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

/// Describes a web wallpaper discovered in the user's Wallpaper Engine library.
struct CSPAuditProject: Sendable, Equatable {
    let workshopID: String
    let title: String
    let folderURL: URL
    let entryFile: String
}

/// Verifies that package-backed web assets share the document origin and remain CSP-clean.
/// Synthetic packages keep this regression coverage hermetic and independent of the opt-in corpus audit.
@Suite("CSP audit — package-backed (wpe scene.pkg) source coverage")
@MainActor
struct CSPAuditPackageBackingTests {

    @Test("Package-backed source loads its packaged entries with zero CSP violations")
    func packageBackedSourceIsCSPClean() async throws {
        let folder = Self.makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // Loading a sibling script detects an incorrect package asset origin.
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

    private static func makeTemporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LWCSPPkgAudit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes the minimal `PKGV0022` layout accepted by the streaming parser.
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
