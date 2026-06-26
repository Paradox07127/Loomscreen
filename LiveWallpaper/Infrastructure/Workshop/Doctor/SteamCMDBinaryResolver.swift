#if !LITE_BUILD && DIRECT_DISTRIBUTION
import Foundation

/// Resolves a user-selected SteamCMD path to the canonical Mach-O binary we
/// are willing to execute. `steamcmd.sh` wrappers are accepted only as a
/// discovery convenience — we parse them to extract `STEAMEXE` and refuse to
/// execute the wrapper itself (the wrapper is shell code that runs before
/// SteamCMD, so a tampered install could inject arbitrary commands).
enum SteamCMDBinaryResolver {

    static func resolveCanonicalBinary(at userPickedURL: URL) -> Result<URL, SteamCMDBinaryError> {
        let pickedURL = userPickedURL.resolvingSymlinksInPath().standardizedFileURL
        guard fileExists(pickedURL) else {
            return .failure(.fileNotFound)
        }
        // A Mach-O is the executable itself. Anything else — Valve's
        // `steamcmd.sh`, Homebrew's `steamcmd.wrapper.sh`, or a
        // `/opt/homebrew/bin/steamcmd` symlink that resolves to one — is a
        // shell wrapper we follow to the real binary.
        if isMachO(pickedURL) {
            return validateBinary(pickedURL).map { pickedURL }
        }
        return resolveWrapper(pickedURL)
    }

    /// The picker remains the source of truth — Valve's tarball install has no
    /// canonical location, so these are only best-effort discovery candidates.
    static func autoDetectCandidates() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Package-manager symlinks (Homebrew on Apple Silicon / Intel, MacPorts).
        var candidates: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/bin/steamcmd"),
            URL(fileURLWithPath: "/usr/local/bin/steamcmd"),
            URL(fileURLWithPath: "/opt/local/bin/steamcmd")
        ]
        // Valve's docs use ~/steamcmd or ~/Steam. Deliberately limited to
        // non-TCC-protected spots — never probe ~/Desktop, ~/Documents, or
        // ~/Downloads, so auto-detect can't trip a "wants to access your …
        // folder" prompt. Both the wrapper and the bootstrapped Mach-O are
        // probed (the resolver follows either to the real binary).
        for dir in ["steamcmd", "Steam", "Applications/steamcmd"] {
            let base = home.appendingPathComponent(dir, isDirectory: true)
            candidates.append(base.appendingPathComponent("steamcmd.sh", isDirectory: false))
            candidates.append(base.appendingPathComponent("steamcmd", isDirectory: false))
        }
        candidates.append(contentsOf: caskroomCandidates(at: URL(fileURLWithPath: "/opt/homebrew/Caskroom/steamcmd")))
        candidates.append(contentsOf: caskroomCandidates(at: URL(fileURLWithPath: "/usr/local/Caskroom/steamcmd")))

        var seen: Set<String> = []
        return candidates.compactMap { candidate in
            let standardized = candidate.standardizedFileURL
            guard fileExists(standardized) else { return nil }
            let path = standardized.path(percentEncoded: false)
            guard seen.insert(path).inserted else { return nil }
            return standardized
        }
    }

    private static func resolveWrapper(_ wrapperURL: URL) -> Result<URL, SteamCMDBinaryError> {
        let wrapperDir = wrapperURL.deletingLastPathComponent()

        // 1) An explicit `STEAMEXE=<path>` line (Valve's tarball `steamcmd.sh`).
        if let value = try? steamExecutableValue(in: wrapperURL) {
            let target = resolveShellPath(value, relativeTo: wrapperDir)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            if fileExists(target), isMachO(target), case .success = validateBinary(target) {
                return .success(target)
            }
        }

        // 2) Otherwise locate the `steamcmd` Mach-O next to the wrapper. Covers
        //    Homebrew's `steamcmd.wrapper.sh` (binary under `MacOS/`) and
        //    Valve's tarball layout (alongside, or under `osx32/`).
        for relative in ["steamcmd", "MacOS/steamcmd", "osx32/steamcmd"] {
            let candidate = wrapperDir.appendingPathComponent(relative, isDirectory: false).standardizedFileURL
            if fileExists(candidate), isMachO(candidate), case .success = validateBinary(candidate) {
                return .success(candidate)
            }
        }

        return .failure(.wrapperParseFailed(reason: "Couldn't find the SteamCMD Mach-O binary near \(wrapperURL.lastPathComponent)."))
    }

    private static func steamExecutableValue(in wrapperURL: URL) throws -> String {
        let data = try Data(contentsOf: wrapperURL, options: .mappedIfSafe)
        guard let script = String(data: data.prefix(64 * 1024), encoding: .utf8) else {
            throw SteamCMDBinaryError.wrapperParseFailed(reason: "steamcmd.sh is not valid UTF-8")
        }

        for rawLine in script.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line.removeFirst("export ".count)
                line = line.trimmingCharacters(in: .whitespaces)
            }
            guard line.hasPrefix("STEAMEXE=") else { continue }
            let stripped = stripShellQuoting(String(line.dropFirst("STEAMEXE=".count)).trimmingCharacters(in: .whitespaces))
            guard !stripped.isEmpty else {
                throw SteamCMDBinaryError.wrapperParseFailed(reason: "STEAMEXE is empty")
            }
            return stripped
        }
        throw SteamCMDBinaryError.wrapperParseFailed(reason: "STEAMEXE assignment not found")
    }

    private static func stripShellQuoting(_ value: String) -> String {
        var output = value
        if let commentRange = output.range(of: #"\s+#"#, options: .regularExpression) {
            output = String(output[..<commentRange.lowerBound])
        }
        if output.count >= 2,
           let first = output.first,
           let last = output.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            output.removeFirst()
            output.removeLast()
        }
        return output
    }

    private static func resolveShellPath(_ value: String, relativeTo wrapperDirectory: URL) -> URL {
        let wrapperPath = wrapperDirectory.path(percentEncoded: false)
        var expanded = value
            .replacingOccurrences(of: "${STEAMROOT}", with: wrapperPath)
            .replacingOccurrences(of: "$STEAMROOT", with: wrapperPath)

        if expanded.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(expanded.dropFirst(2)))
                .path(percentEncoded: false)
        }
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        let direct = wrapperDirectory.appendingPathComponent(expanded, isDirectory: false)
        if fileExists(direct) { return direct }

        for child in ["MacOS", "osx32"] {
            let candidate = wrapperDirectory
                .appendingPathComponent(child, isDirectory: true)
                .appendingPathComponent((expanded as NSString).lastPathComponent, isDirectory: false)
            if fileExists(candidate) { return candidate }
        }
        return direct
    }

    private static func validateBinary(_ url: URL) -> Result<Void, SteamCMDBinaryError> {
        guard isMachO(url) else { return .failure(.notMachO) }
        guard FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) else {
            return .failure(.notExecutable)
        }
        return .success(())
    }

    private static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        let bytes = Array(data)
        return bytes == [0xfe, 0xed, 0xfa, 0xce]
            || bytes == [0xce, 0xfa, 0xed, 0xfe]
            || bytes == [0xfe, 0xed, 0xfa, 0xcf]
            || bytes == [0xcf, 0xfa, 0xed, 0xfe]
            || bytes == [0xca, 0xfe, 0xba, 0xbe]
            || bytes == [0xbe, 0xba, 0xfe, 0xca]
            || bytes == [0xca, 0xfe, 0xba, 0xbf]
            || bytes == [0xbf, 0xba, 0xfe, 0xca]
    }

    private static func fileExists(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private static func caskroomCandidates(at root: URL) -> [URL] {
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return versions
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .map { $0.appendingPathComponent("MacOS/steamcmd", isDirectory: false) }
    }
}

enum SteamCMDBinaryError: Error, Equatable, Sendable {
    case fileNotFound
    case notMachO
    case wrapperParseFailed(reason: String)
    case notExecutable
}
#endif
