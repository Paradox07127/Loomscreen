#if !LITE_BUILD
    import CryptoKit
    import Foundation

    struct SteamCMDBinaryExecutionAuthorization: Equatable, Sendable {
        let canonicalPath: String
        let sha256: String
    }

    protocol SteamCMDProcessRunning: Sendable {
        func run(
            binary: URL,
            args: [String],
            stdin: String?,
            timeout: TimeInterval,
            workingDirectory: URL?,
            onProgress: SteamCMDProgressHandler?
        ) async -> SteamCMDRunResult

        func runVerified(
            binary: URL,
            authorization: SteamCMDBinaryExecutionAuthorization,
            args: [String],
            stdin: String?,
            timeout: TimeInterval,
            workingDirectory: URL?,
            onProgress: SteamCMDProgressHandler?
        ) async -> SteamCMDRunResult
    }

    extension SteamCMDProcessRunning {
        func runVerified(
            binary _: URL,
            authorization _: SteamCMDBinaryExecutionAuthorization,
            args _: [String],
            stdin _: String?,
            timeout _: TimeInterval,
            workingDirectory _: URL?,
            onProgress _: SteamCMDProgressHandler?
        ) async -> SteamCMDRunResult {
            SteamCMDRunResult(
                exitCode: nil,
                stdout: "",
                stderr: "Runner does not support verified execution.",
                timedOut: false,
                killed: false
            )
        }

        func run(
            binary: URL,
            args: [String],
            stdin: String?,
            timeout: TimeInterval,
            workingDirectory: URL?
        ) async -> SteamCMDRunResult {
            await run(
                binary: binary,
                args: args,
                stdin: stdin,
                timeout: timeout,
                workingDirectory: workingDirectory,
                onProgress: nil
            )
        }
    }

    extension SteamCMDProcessRunner: SteamCMDProcessRunning {}

    protocol SteamCMDBinaryTrustChecking: Sendable {
        func identity(of binary: URL) async throws -> String
        func codesignResult(for binary: URL) async -> CodesignResult
    }

    struct SteamCMDProductionBinaryTrustChecker: SteamCMDBinaryTrustChecking {
        private let runner: any SteamCMDProcessRunning

        init(runner: any SteamCMDProcessRunning = SteamCMDProcessRunner()) {
            self.runner = runner
        }

        func identity(of binary: URL) async throws -> String {
            let handle = try FileHandle(forReadingFrom: binary)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        func codesignResult(for binary: URL) async -> CodesignResult {
            let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
            let verify = await runner.run(
                binary: codesign,
                args: ["--verify", "--strict", binary.path(percentEncoded: false)],
                stdin: nil,
                timeout: 30,
                workingDirectory: nil,
                onProgress: nil
            )
            let display = await runner.run(
                binary: codesign,
                args: ["-dv", "--verbose=4", binary.path(percentEncoded: false)],
                stdin: nil,
                timeout: 30,
                workingDirectory: nil,
                onProgress: nil
            )
            return SteamCMDCodeSignatureParser.result(verify: verify, display: display)
        }
    }

    enum SteamCMDCodeSignatureParser {
        static func result(verify: SteamCMDRunResult, display: SteamCMDRunResult) -> CodesignResult {
            let combined = "\(display.stdout)\n\(display.stderr)"
            let teamIdentifier = firstCapture(
                in: combined,
                pattern: #"TeamIdentifier=([A-Z0-9]+)"#
            )
            let hardenedRuntime = combined.range(
                of: #"flags=0x[0-9a-fA-F]+\([^)]*runtime"#,
                options: .regularExpression
            ) != nil || combined.contains("runtime")
            return CodesignResult(
                teamIdentifier: teamIdentifier,
                isHardenedRuntime: hardenedRuntime,
                signatureValid: verify.exitCode == 0 && !verify.timedOut && !verify.killed
            )
        }

        private static func firstCapture(in text: String, pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(text.startIndex ..< text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captureRange])
        }
    }
#endif
