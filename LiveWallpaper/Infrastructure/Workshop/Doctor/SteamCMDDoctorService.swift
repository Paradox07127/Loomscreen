#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import CryptoKit
import Foundation
import LiveWallpaperCore
import Observation
import os

enum DoctorProbeKind: String, Sendable, CaseIterable, Identifiable {
    case binaryIdentity
    case codeSignature
    case rosetta
    case gatekeeperQuarantine
    case workingDirectory
    case cachedLogin
    case wallpaperEngineOwnership

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .binaryIdentity: return "SteamCMD binary identity"
        case .codeSignature: return "Code signature"
        case .rosetta: return "Rosetta 2"
        case .gatekeeperQuarantine: return "Gatekeeper / quarantine"
        case .workingDirectory: return "Working directory"
        case .cachedLogin: return "Steam sign-in"
        case .wallpaperEngineOwnership: return "Wallpaper Engine ownership"
        }
    }

    /// Non-blocking probes can be `.red` without blocking the Workshop UI as
    /// a whole — they surface as red rows but do not contribute to
    /// `DoctorState.done(allGreen:blockingFailures:).blockingFailures`.
    var isAdvisory: Bool {
        switch self {
        case .wallpaperEngineOwnership, .codeSignature: return true
        default: return false
        }
    }
}

enum DoctorProbeStatus: Equatable, Sendable {
    case notRun
    case running
    case green(detail: String?)
    case yellow(message: String, command: String?)
    case red(message: String, command: String?)
}

struct DoctorProbeReport: Identifiable, Sendable {
    let id: DoctorProbeKind
    let status: DoctorProbeStatus
    let lastRun: Date
}

enum DoctorState: Sendable, Equatable {
    case idle
    case probing
    case done(allGreen: Bool, blockingFailures: Int)
}

struct CodesignResult: Sendable {
    let teamIdentifier: String?
    let isHardenedRuntime: Bool
    let signatureValid: Bool
}

enum SteamCMDDoctorError: Error, Equatable, Sendable, LocalizedError {
    case binaryResolution(SteamCMDBinaryError)
    case bookmarkCreation(String)
    case missingBinaryBinding
    case missingWorkdirBinding
    case bookmarkResolution(String)
    case invalidUsername
    case workdirNotDirectory(URL)
    case steamLibraryMissingConfig(URL)

    var errorDescription: String? {
        switch self {
        case .binaryResolution(let error):
            return "SteamCMD binary could not be resolved: \(error)"
        case .bookmarkCreation(let reason):
            return "Could not create a security-scoped bookmark: \(reason)"
        case .missingBinaryBinding:
            return "No SteamCMD binary is selected."
        case .missingWorkdirBinding:
            return "No SteamCMD working directory is selected."
        case .bookmarkResolution(let reason):
            return "Stored security-scoped bookmark could not be resolved: \(reason)"
        case .invalidUsername:
            return "Steam username must match ^[A-Za-z0-9_]{1,32}$."
        case .workdirNotDirectory(let url):
            return "SteamCMD working directory is not a folder: \(url.path(percentEncoded: false))"
        case .steamLibraryMissingConfig(let url):
            return "Shared Steam library must contain config/config.vdf: \(url.path(percentEncoded: false))"
        }
    }
}

@MainActor
@Observable
final class SteamCMDDoctorService {

    private enum Keys {
        static let binaryBookmark = "loomscreen.workshop.doctor.binaryBookmark"
        static let workdirBookmark = "loomscreen.workshop.doctor.workdirBookmark"
        static let binarySHA256 = "loomscreen.workshop.doctor.binarySHA256"
        static let username = "loomscreen.workshop.doctor.username"
    }

    private static let valveTeamIdentifier = "MXGJJ98X76"
    private static let wallpaperEngineAppID: UInt32 = 431960
    /// Empirically validated public free WE community item used as the primary
    /// ownership probe (Phase 0 empirical pass, 2026-05-28).
    private static let primaryOwnershipProbeID: UInt64 = 3725117707
    /// Fallback ids in case the primary item is delisted. The plan calls for
    /// ≥3 candidates; refresh the list on each release.
    private static let fallbackOwnershipProbeIDs: [UInt64] = [
        2932849316, // TODO(post-v2): replace with empirically verified free WE community items
        2906898907
    ]
    private static var ownershipProbeCandidateIDs: [UInt64] {
        [primaryOwnershipProbeID] + fallbackOwnershipProbeIDs
    }

    @ObservationIgnored private let runner: SteamCMDProcessRunner
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let logger = os.Logger(subsystem: "com.loomscreen.livewallpaper", category: "WorkshopDoctor")

    var probes: [DoctorProbeKind: DoctorProbeReport]
    var state: DoctorState = .idle
    var binaryDisplayPath: String?
    var workdirDisplayPath: String?

    var binaryBookmarkData: Data? {
        get { defaults.data(forKey: Keys.binaryBookmark) }
        set {
            setOptional(newValue, forKey: Keys.binaryBookmark)
            refreshDisplayPaths()
        }
    }

    var workdirBookmarkData: Data? {
        get { defaults.data(forKey: Keys.workdirBookmark) }
        set {
            setOptional(newValue, forKey: Keys.workdirBookmark)
            refreshDisplayPaths()
        }
    }

    var lastBinarySHA256: String? {
        get { defaults.string(forKey: Keys.binarySHA256) }
        set { setOptional(newValue, forKey: Keys.binarySHA256) }
    }

    var username: String? {
        get { defaults.string(forKey: Keys.username) }
        set {
            setOptional(newValue, forKey: Keys.username)
            _ = state  // re-trigger observation chain
        }
    }

    init(
        runner: SteamCMDProcessRunner = SteamCMDProcessRunner(),
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.defaults = defaults
        self.fileManager = fileManager
        self.probes = Dictionary(uniqueKeysWithValues: DoctorProbeKind.allCases.map { kind in
            (kind, DoctorProbeReport(id: kind, status: .notRun, lastRun: .distantPast))
        })
        refreshDisplayPaths()
    }

    // MARK: - Binding

    func bindBinary(_ userPickedURL: URL) async throws {
        let canonicalURL: URL = try SecurityScopedBookmarkResolver.withScopedAccess(userPickedURL) { _ in
            switch SteamCMDBinaryResolver.resolveCanonicalBinary(at: userPickedURL) {
            case .success(let url):
                return url.resolvingSymlinksInPath().standardizedFileURL
            case .failure(let error):
                throw SteamCMDDoctorError.binaryResolution(error)
            }
        }

        let sha256 = try Self.streamingSHA256Hex(of: canonicalURL)
        let bookmark = try Self.makeBookmark(for: canonicalURL, readOnly: true)
        binaryBookmarkData = bookmark
        lastBinarySHA256 = sha256
        binaryDisplayPath = canonicalURL.path(percentEncoded: false)
        // Invalidate every probe whose green-ness depends on which binary
        // we run — re-binding to a different SteamCMD must force a re-run.
        for kind in DoctorProbeKind.allCases where kind != .workingDirectory {
            setProbe(kind, status: .notRun)
        }
        logger.info("Bound SteamCMD binary")
        await runProbe(.binaryIdentity)
    }

    func bindWorkdir(_ url: URL, isSharedSteamLibrary: Bool) async throws {
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory = ObjCBool(false)
        let exists = fileManager.fileExists(atPath: canonicalURL.path(percentEncoded: false), isDirectory: &isDirectory)

        if isSharedSteamLibrary {
            let configURL = canonicalURL
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent("config.vdf", isDirectory: false)
            guard exists, isDirectory.boolValue, fileManager.fileExists(atPath: configURL.path(percentEncoded: false)) else {
                throw SteamCMDDoctorError.steamLibraryMissingConfig(configURL)
            }
        } else if !exists {
            try fileManager.createDirectory(
                at: canonicalURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            isDirectory = ObjCBool(true)
        } else if !isDirectory.boolValue {
            throw SteamCMDDoctorError.workdirNotDirectory(canonicalURL)
        }

        let bookmark = try Self.makeBookmark(for: canonicalURL, readOnly: false)
        workdirBookmarkData = bookmark
        workdirDisplayPath = canonicalURL.path(percentEncoded: false)
        // The workdir holds the cached-login session and the workshop
        // license cache, so any change invalidates both downstream probes.
        setProbe(.cachedLogin, status: .notRun)
        setProbe(.wallpaperEngineOwnership, status: .notRun)
        logger.info("Bound SteamCMD workdir (shared=\(isSharedSteamLibrary, privacy: .public))")
        await runProbe(.workingDirectory)
    }

    func setUsername(_ name: String) throws {
        guard SteamCMDScriptWriter.validateUsername(name) else {
            throw SteamCMDDoctorError.invalidUsername
        }
        let changed = username != name
        username = name
        // A different account name means the cached-login and ownership
        // probes' previous green state is no longer about *this* user.
        if changed {
            setProbe(.cachedLogin, status: .notRun)
            setProbe(.wallpaperEngineOwnership, status: .notRun)
        }
    }

    func clearBinaryBinding() {
        binaryBookmarkData = nil
        lastBinarySHA256 = nil
        binaryDisplayPath = nil
        setProbe(.binaryIdentity, status: .notRun)
        setProbe(.codeSignature, status: .notRun)
        setProbe(.gatekeeperQuarantine, status: .notRun)
    }

    func clearWorkdirBinding() {
        workdirBookmarkData = nil
        workdirDisplayPath = nil
        setProbe(.workingDirectory, status: .notRun)
        setProbe(.cachedLogin, status: .notRun)
        setProbe(.wallpaperEngineOwnership, status: .notRun)
    }

    /// Surface the Rosetta-install command to the user. Spawning
    /// `softwareupdate --install-rosetta` directly requires the privileged
    /// helper entitlement we don't ship yet, so this method writes the exact
    /// command to the clipboard + opens Terminal.app and lets the user run it
    /// under explicit consent.
    func installRosetta() async {
        let command = "/usr/sbin/softwareupdate --install-rosetta --agree-to-license"
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(command, forType: .string)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    // MARK: - Probes

    func runAll() async {
        state = .probing
        for kind in DoctorProbeKind.allCases {
            await performProbe(kind)
        }
        finishProbeRun()
    }

    func runProbe(_ kind: DoctorProbeKind) async {
        state = .probing
        await performProbe(kind)
        finishProbeRun()
    }

    private func performProbe(_ kind: DoctorProbeKind) async {
        setProbe(kind, status: .running)
        switch kind {
        case .binaryIdentity: await runBinaryIdentityProbe()
        case .codeSignature: await runCodeSignatureProbe()
        case .rosetta: runRosettaProbe()
        case .gatekeeperQuarantine: await runGatekeeperProbe()
        case .workingDirectory: runWorkingDirectoryProbe()
        case .cachedLogin: await runCachedLoginProbe()
        case .wallpaperEngineOwnership: await runWallpaperEngineOwnershipProbe()
        }
    }

    private func runBinaryIdentityProbe() async {
        do {
            let binary = try resolveBinaryURL()
            let didStart = binary.startAccessingSecurityScopedResource()
            defer { if didStart { binary.stopAccessingSecurityScopedResource() } }

            let result = await runner.run(
                binary: binary, args: ["+quit"], stdin: nil,
                timeout: 30, workingDirectory: nil
            )
            if result.timedOut {
                setProbe(.binaryIdentity, status: .red(
                    message: redacted("SteamCMD identity probe timed out after 30 seconds."),
                    command: redacted(command(binary: binary, args: ["+quit"]))
                ))
                return
            }
            guard result.stdout.range(
                of: #"Steam Console Client \(c\) Valve Corporation - version \d+"#,
                options: .regularExpression
            ) != nil else {
                setProbe(.binaryIdentity, status: .red(
                    message: "SteamCMD did not print the expected Valve identity banner. Use Export diagnostics for the raw output.",
                    command: redacted(command(binary: binary, args: ["+quit"]))
                ))
                return
            }

            var detail = "SteamCMD identity verified."
            if let currentSHA = try? Self.streamingSHA256Hex(of: binary) {
                if let previous = lastBinarySHA256, previous != currentSHA {
                    detail = "SteamCMD updated itself (SHA-256 changed) — that's normal."
                }
                lastBinarySHA256 = currentSHA
            }
            setProbe(.binaryIdentity, status: .green(detail: redacted(detail)))
        } catch {
            setProbe(.binaryIdentity, status: .red(message: redacted(error.localizedDescription), command: nil))
        }
    }

    private func runCodeSignatureProbe() async {
        do {
            let binary = try resolveBinaryURL()
            let result = await Self.runCodesignCheck(binary: binary)
            if result.teamIdentifier == Self.valveTeamIdentifier {
                let detail = result.isHardenedRuntime
                    ? "Verified Valve build (TeamIdentifier=MXGJJ98X76, Hardened Runtime)."
                    : "Verified Valve build (TeamIdentifier=MXGJJ98X76)."
                setProbe(.codeSignature, status: .green(detail: redacted(detail)))
            } else {
                let team = result.teamIdentifier ?? "none"
                let reason = result.signatureValid
                    ? "SteamCMD is signed by an unverified team (TeamIdentifier=\(team))."
                    : "SteamCMD signature is missing or could not be verified."
                setProbe(.codeSignature, status: .yellow(
                    message: redacted("Unverified build. \(reason)"),
                    command: redacted(command(
                        binary: URL(fileURLWithPath: "/usr/bin/codesign"),
                        args: ["-dv", "--verbose=4", binary.path(percentEncoded: false)]
                    ))
                ))
            }
        } catch {
            setProbe(.codeSignature, status: .yellow(message: redacted(error.localizedDescription), command: nil))
        }
    }

    private func runRosettaProbe() {
        #if arch(arm64)
        let marker = URL(fileURLWithPath: "/Library/Apple/usr/share/rosetta/rosetta")
        if fileManager.fileExists(atPath: marker.path(percentEncoded: false)) {
            setProbe(.rosetta, status: .green(detail: "Rosetta is installed."))
        } else {
            setProbe(.rosetta, status: .yellow(
                message: "Rosetta is required for the SteamCMD bootstrap on Apple Silicon. Homebrew's cask ships a universal binary; the Valve tarball bootstrap is x86_64-only.",
                command: "/usr/sbin/softwareupdate --install-rosetta --agree-to-license"
            ))
        }
        #else
        setProbe(.rosetta, status: .green(detail: "Rosetta is not required on this Mac."))
        #endif
    }

    private func runGatekeeperProbe() async {
        do {
            let binary = try resolveBinaryURL()
            if isQuarantined(binary) {
                setProbe(.gatekeeperQuarantine, status: .red(
                    message: redacted("SteamCMD has the Gatekeeper quarantine attribute. macOS may block it on launch."),
                    command: redacted(xattrCommand(for: binary))
                ))
                return
            }

            let didStart = binary.startAccessingSecurityScopedResource()
            defer { if didStart { binary.stopAccessingSecurityScopedResource() } }
            let result = await runner.run(
                binary: binary,
                args: ["+login", "anonymous", "+quit"],
                stdin: nil, timeout: 30, workingDirectory: nil
            )
            let combined = "\(result.stdout)\n\(result.stderr)"
            if !result.timedOut,
               !result.killed,
               combined.contains("Steam Console Client") || result.exitCode == 0 {
                setProbe(.gatekeeperQuarantine, status: .green(detail: "SteamCMD launches without Gatekeeper interference."))
            } else {
                setProbe(.gatekeeperQuarantine, status: .red(
                    message: "SteamCMD failed the launch sanity check. If macOS blocked it, clear the quarantine attribute.",
                    command: redacted(xattrCommand(for: binary))
                ))
            }
        } catch {
            setProbe(.gatekeeperQuarantine, status: .red(message: redacted(error.localizedDescription), command: nil))
        }
    }

    private func runWorkingDirectoryProbe() {
        do {
            let workdir = try resolveWorkdirURL()
            let didStart = workdir.startAccessingSecurityScopedResource()
            defer { if didStart { workdir.stopAccessingSecurityScopedResource() } }

            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: workdir.path(percentEncoded: false), isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                setProbe(.workingDirectory, status: .red(
                    message: redacted("SteamCMD working directory is missing."),
                    command: nil
                ))
                return
            }
            let testURL = workdir.appendingPathComponent(".lw-doctor-write-test-\(UUID().uuidString)", isDirectory: false)
            try Data("ok".utf8).write(to: testURL, options: [.withoutOverwriting])
            try? fileManager.removeItem(at: testURL)
            setProbe(.workingDirectory, status: .green(detail: redacted("Working directory is writable.")))
        } catch {
            setProbe(.workingDirectory, status: .red(message: redacted(error.localizedDescription), command: nil))
        }
    }

    private func runCachedLoginProbe() async {
        do {
            let binary = try resolveBinaryURL()
            let workdir = try resolveWorkdirURL()
            guard let username else {
                setProbe(.cachedLogin, status: .yellow(
                    message: "Enter your Steam username before checking cached login.",
                    command: nil
                ))
                return
            }
            let script = try SteamCMDScriptWriter.cachedLoginProbeScript(username: username)
            let result = try await runSteamCMDScript(script, binary: binary, workdir: workdir, timeout: 30)
            let failure = "FAILED (No cached credentials and @NoPromptForPassword is set)"
            if result.stdout.contains("Logging in using cached credentials."),
               result.stdout.range(of: #"Logging in user '[^']+' \[U:1:\d+\] to Steam Public\.\.\.OK"#, options: .regularExpression) != nil {
                setProbe(.cachedLogin, status: .green(detail: redacted("Cached Steam login is available.")))
            } else if result.stdout.contains("Cached credentials not found."), result.stdout.contains(failure) {
                setProbe(.cachedLogin, status: .yellow(
                    message: "Sign in once in Terminal so SteamCMD can cache your session.",
                    command: signInCommand(binary: binary, username: username)
                ))
            } else if result.stdout.contains(failure) {
                setProbe(.cachedLogin, status: .yellow(
                    message: "Your Steam session expired. Sign in again in Terminal.",
                    command: signInCommand(binary: binary, username: username)
                ))
            } else if result.timedOut {
                setProbe(.cachedLogin, status: .red(
                    message: "Cached-login probe timed out after 30 seconds.",
                    command: nil
                ))
            } else {
                setProbe(.cachedLogin, status: .red(
                    message: "Cached-login probe returned an unrecognized response. Use Export diagnostics for the raw output.",
                    command: nil
                ))
            }
        } catch SteamCMDScriptError.invalidUsername {
            setProbe(.cachedLogin, status: .red(
                message: "Steam username must match ^[A-Za-z0-9_]{1,32}$.",
                command: nil
            ))
        } catch {
            setProbe(.cachedLogin, status: .red(message: redacted(error.localizedDescription), command: nil))
        }
    }

    private func runWallpaperEngineOwnershipProbe() async {
        guard isGreen(.cachedLogin) else {
            setProbe(.wallpaperEngineOwnership, status: .yellow(
                message: "Cached Steam login must pass before ownership can be checked.",
                command: nil
            ))
            return
        }

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

            var removedIDs: [UInt64] = []
            for itemID in Self.ownershipProbeCandidateIDs {
                let script = try SteamCMDScriptWriter.ownershipProbeScript(username: username, itemID: itemID)
                let result = try await runSteamCMDScript(script, binary: binary, workdir: workdir, timeout: 90)
                if result.stdout.range(of: #"Success\. Downloaded item \#(itemID) to "#, options: .regularExpression) != nil {
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
            setProbe(.wallpaperEngineOwnership, status: .red(message: redacted(error.localizedDescription), command: nil))
        }
    }

    // MARK: - Helpers

    nonisolated static func runCodesignCheck(binary: URL) async -> CodesignResult {
        let runner = SteamCMDProcessRunner()
        // `codesign -dv --verbose=4` is the canonical inspection invocation;
        // it emits `TeamIdentifier=<id>` + the CodeDirectory `flags` line
        // that carries `runtime` when Hardened Runtime is enabled. The earlier
        // `--team-identifier` flag is a `csreq`-only switch and would print
        // "TeamIdentifier must be ..." here, blocking the Doctor's green path.
        let result = await runner.run(
            binary: URL(fileURLWithPath: "/usr/bin/codesign"),
            args: ["-dv", "--verbose=4", binary.path(percentEncoded: false)],
            stdin: nil, timeout: 30, workingDirectory: nil
        )
        let combined = "\(result.stdout)\n\(result.stderr)"
        let teamIdentifier = firstCapture(in: combined, pattern: #"TeamIdentifier=([A-Z0-9]+)"#)
        // CodeDirectory line carries `flags=0xN(runtime,...)` when Hardened
        // Runtime is on. Plain `runtime` substring match also covers macOS
        // output where the flag name is interleaved with other tokens.
        let hardenedRuntime = combined.range(
            of: #"flags=0x[0-9a-fA-F]+\([^)]*runtime"#,
            options: .regularExpression
        ) != nil || combined.contains("runtime")
        return CodesignResult(
            teamIdentifier: teamIdentifier,
            isHardenedRuntime: hardenedRuntime,
            signatureValid: result.exitCode == 0 && !result.timedOut && !result.killed
        )
    }

    private func runSteamCMDScript(
        _ script: String,
        binary: URL,
        workdir: URL,
        timeout: TimeInterval
    ) async throws -> SteamCMDRunResult {
        let binaryAccess = binary.startAccessingSecurityScopedResource()
        let workdirAccess = workdir.startAccessingSecurityScopedResource()
        defer {
            if binaryAccess { binary.stopAccessingSecurityScopedResource() }
            if workdirAccess { workdir.stopAccessingSecurityScopedResource() }
        }

        let scriptURL = try SteamCMDScriptWriter.writeScript(script, in: workdir)
        defer { SteamCMDScriptWriter.deleteScript(scriptURL) }
        return await runner.run(
            binary: binary,
            args: ["+runscript", scriptURL.path(percentEncoded: false)],
            stdin: nil, timeout: timeout, workingDirectory: workdir
        )
    }

    private func resolveBinaryURL() throws -> URL {
        guard let data = binaryBookmarkData else { throw SteamCMDDoctorError.missingBinaryBinding }
        switch SecurityScopedBookmarkResolver.shared.resolve(data, target: .transient) {
        case .success(let resolved):
            if resolved.didRefresh {
                binaryBookmarkData = resolved.bookmarkData
            }
            let url = resolved.url.resolvingSymlinksInPath().standardizedFileURL
            binaryDisplayPath = url.path(percentEncoded: false)
            return url
        case .failure(let failure):
            throw SteamCMDDoctorError.bookmarkResolution(failure.localizedDescription)
        }
    }

    private func resolveWorkdirURL() throws -> URL {
        guard let data = workdirBookmarkData else { throw SteamCMDDoctorError.missingWorkdirBinding }
        switch SecurityScopedBookmarkResolver.shared.resolve(data, target: .transient) {
        case .success(let resolved):
            let url = resolved.url.resolvingSymlinksInPath().standardizedFileURL
            if resolved.didRefresh {
                // The shared resolver refreshes with read-only scope, but
                // workdir needs write access for SteamCMD scripts + downloads
                // — recreate the bookmark with write scope and persist.
                if let refreshed = try? Self.makeBookmark(for: url, readOnly: false) {
                    workdirBookmarkData = refreshed
                }
            }
            workdirDisplayPath = url.path(percentEncoded: false)
            return url
        case .failure(let failure):
            throw SteamCMDDoctorError.bookmarkResolution(failure.localizedDescription)
        }
    }

    private func refreshDisplayPaths() {
        binaryDisplayPath = Self.displayPath(for: defaults.data(forKey: Keys.binaryBookmark))
        workdirDisplayPath = Self.displayPath(for: defaults.data(forKey: Keys.workdirBookmark))
    }

    private static func displayPath(for bookmarkData: Data?) -> String? {
        guard let bookmarkData,
              case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(bookmarkData, target: .transient)
        else { return nil }
        return resolved.url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
    }

    private static func makeBookmark(for url: URL, readOnly: Bool) throws -> Data {
        do {
            let options: URL.BookmarkCreationOptions = readOnly
                ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
                : [.withSecurityScope]
            return try SecurityScopedBookmarkResolver.withScopedAccess(url) { _ in
                try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
            }
        } catch {
            throw SteamCMDDoctorError.bookmarkCreation(error.localizedDescription)
        }
    }

    private func setOptional(_ value: Data?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private func setOptional(_ value: String?, forKey key: String) {
        if let value, !value.isEmpty { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private func setProbe(_ kind: DoctorProbeKind, status: DoctorProbeStatus) {
        probes[kind] = DoctorProbeReport(id: kind, status: status, lastRun: Date())
    }

    private func finishProbeRun() {
        let blockingFailures = probes.values.reduce(0) { partial, report in
            guard case .red = report.status, !report.id.isAdvisory else { return partial }
            return partial + 1
        }
        let allGreen = DoctorProbeKind.allCases.allSatisfy { kind in
            guard let report = probes[kind], case .green = report.status else { return false }
            return true
        }
        state = .done(allGreen: allGreen, blockingFailures: blockingFailures)
    }

    private func isGreen(_ kind: DoctorProbeKind) -> Bool {
        guard let report = probes[kind], case .green = report.status else { return false }
        return true
    }

    private func isQuarantined(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.quarantinePropertiesKey]) else { return false }
        return values.quarantineProperties != nil
    }

    private func redacted(_ raw: String) -> String {
        var prepared = raw
        if let workdirDisplayPath, !workdirDisplayPath.isEmpty {
            prepared = prepared.replacingOccurrences(of: workdirDisplayPath, with: "<workdir>")
        }
        var output = WorkshopDiagnosticRedactor.redact(prepared)
        if let username, !username.isEmpty {
            output = output.replacingOccurrences(of: username, with: "<steam_username>")
        }
        return output
    }

    private func command(binary: URL, args: [String]) -> String {
        ([binary.path(percentEncoded: false)] + args).map(Self.shellEscaped).joined(separator: " ")
    }

    private func signInCommand(binary: URL, username: String) -> String {
        command(binary: binary, args: ["+login", username])
    }

    private func xattrCommand(for binary: URL) -> String {
        "xattr -dr com.apple.quarantine \(Self.shellEscaped(binary.path(percentEncoded: false)))"
    }

    private static func shellEscaped(_ value: String) -> String {
        if value.range(of: #"[^A-Za-z0-9_@%+=:,./-]"#, options: .regularExpression) == nil {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func streamingSHA256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }
}
#endif
