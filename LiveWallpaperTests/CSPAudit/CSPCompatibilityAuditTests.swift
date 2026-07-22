import Testing
import Foundation
@testable import LiveWallpaper

/// Runs the opt-in CSP compatibility audit against a local web-wallpaper corpus.
/// Enable it with `LW_RUN_CSP_AUDIT=1`; the shipping policy must remain violation-free for at least 95% of projects.
@Suite("CSP compatibility audit (long-running)", .disabled(if: !CSPAuditEnvironment.isEnabled))
@MainActor
struct CSPCompatibilityAuditTests {

    static let dwellSeconds: TimeInterval = 30

    /// Caps corpus cost without affecting CSP violation collection.
    static let maxProjectBytes: Int64 = 200 * 1024 * 1024

    @Test("v2 (ship config) passes the ≥95 % zero-violation threshold")
    func assertV2PassRate() async throws {
        let corpus = try CSPAuditCorpus.discoverFromUserLibrary(maxBytes: Self.maxProjectBytes)
        try #require(corpus.count >= 10, "Need at least 10 WE web projects to make the audit meaningful; found \(corpus.count).")

        let result = try await runAudit(
            corpus: corpus,
            candidates: [.v2Current],
            dwell: Self.dwellSeconds
        )

        let row = result.rows.first { $0.candidate == .v2Current }!
        let passRate = Double(row.zeroViolationProjects) / Double(corpus.count)
        try? result.writeJSONReport()
        print(result.formatTable())

        #expect(passRate >= 0.95, "v2 pass rate \(String(format: "%.1f%%", passRate * 100)) is below the 95 % ship threshold; see report above for the violation breakdown.")
    }

    @Test("Full matrix: v1-strict / v2-current / v3-relaxed across corpus")
    func runFullMatrix() async throws {
        let corpus = try CSPAuditCorpus.discoverFromUserLibrary(maxBytes: Self.maxProjectBytes)
        let result = try await runAudit(
            corpus: corpus,
            candidates: CSPAuditCandidate.allCases,
            dwell: Self.dwellSeconds
        )
        try? result.writeJSONReport()
        print(result.formatTable())
        // This matrix is diagnostic; assertV2PassRate is the shipping gate.
    }

    private func runAudit(
        corpus: [CSPAuditProject],
        candidates: [CSPAuditCandidate],
        dwell: TimeInterval
    ) async throws -> CSPAuditReport {
        var matrix: [CSPAuditCandidate: [CSPAuditReport.PerProject]] = [:]
        for candidate in candidates {
            var perProject: [CSPAuditReport.PerProject] = []
            for (index, project) in corpus.enumerated() {
                print("[CSP audit] \(candidate.rawValue) — project \(index + 1)/\(corpus.count): \(project.workshopID) (\(project.title.prefix(50)))")
                let host = CSPAuditHost(project: project, candidate: candidate)
                do {
                    let observations = try await host.runOnce(dwellSeconds: dwell)
                    perProject.append(.init(project: project, observations: observations, didLoad: true, loadError: nil))
                } catch {
                    perProject.append(.init(project: project, observations: [], didLoad: false, loadError: String(describing: error)))
                }
            }
            matrix[candidate] = perProject
        }
        return CSPAuditReport(corpus: corpus, candidates: candidates, matrix: matrix)
    }
}

enum CSPAuditCorpus {
    /// Finds web projects in the user's Wallpaper Engine library, excluding bundles above `maxBytes`.
    static func discoverFromUserLibrary(maxBytes: Int64) throws -> [CSPAuditProject] {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let root = docs
            .appendingPathComponent("Live Wallpapers", isDirectory: true)
            .appendingPathComponent("431960", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw AuditCorpusError.libraryNotFound(root.path)
        }

        let subdirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var projects: [CSPAuditProject] = []
        for subdir in subdirs {
            let manifestURL = subdir.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            guard let type = (json["type"] as? String)?.lowercased(), type == "web" else { continue }
            let entry = (json["file"] as? String) ?? "index.html"
            let title = (json["title"] as? String) ?? subdir.lastPathComponent

            let size = (try? folderSize(subdir)) ?? 0
            if size > maxBytes { continue }

            projects.append(CSPAuditProject(
                workshopID: subdir.lastPathComponent,
                title: title,
                folderURL: subdir,
                entryFile: entry
            ))
        }
        return projects.sorted { $0.workshopID < $1.workshopID }
    }

    private static func folderSize(_ url: URL) throws -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true, let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

enum AuditCorpusError: Error {
    case libraryNotFound(String)
}

enum CSPAuditEnvironment {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LW_RUN_CSP_AUDIT"] == "1"
    }
}

struct CSPAuditReport: Sendable {
    struct PerProject: Sendable {
        let project: CSPAuditProject
        let observations: [CSPViolationCollector.Observation]
        let didLoad: Bool
        let loadError: String?

        var cspViolations: [CSPViolationCollector.Observation] {
            observations.filter { $0.kind == .cspViolation }
        }

        var jsErrors: [CSPViolationCollector.Observation] {
            observations.filter { $0.kind == .windowError || $0.kind == .unhandledRejection }
        }

        var storageProbes: [CSPViolationCollector.Observation] {
            observations.filter { $0.kind == .storageAccess }
        }
    }

    struct Row: Sendable {
        let candidate: CSPAuditCandidate
        let totalProjects: Int
        let zeroViolationProjects: Int
        let cspViolationProjects: Int
        let projectsTouchingStorage: Int
        let failedToLoad: Int
    }

    let corpus: [CSPAuditProject]
    let candidates: [CSPAuditCandidate]
    let matrix: [CSPAuditCandidate: [PerProject]]

    var rows: [Row] {
        candidates.map { candidate -> Row in
            let entries = matrix[candidate] ?? []
            let zeroViolation = entries.filter { $0.didLoad && $0.cspViolations.isEmpty }.count
            let withCspViolations = entries.filter { !$0.cspViolations.isEmpty }.count
            let touchingStorage = entries.filter { !$0.storageProbes.isEmpty }.count
            let failedToLoad = entries.filter { !$0.didLoad }.count
            return Row(
                candidate: candidate,
                totalProjects: entries.count,
                zeroViolationProjects: zeroViolation,
                cspViolationProjects: withCspViolations,
                projectsTouchingStorage: touchingStorage,
                failedToLoad: failedToLoad
            )
        }
    }

    func formatTable() -> String {
        var lines: [String] = []
        lines.append("CSP audit summary (corpus = \(corpus.count) projects)")
        lines.append(String(repeating: "—", count: 88))
        lines.append(String(format: "%-30s %8s %14s %14s %8s",
                            "Candidate", "Total", "Zero-Violation", "With-Violation", "Storage"))
        lines.append(String(repeating: "—", count: 88))
        for row in rows {
            let passRate = row.totalProjects == 0
                ? "—"
                : String(format: "%.1f%%",
                         Double(row.zeroViolationProjects) / Double(row.totalProjects) * 100)
            lines.append(String(format: "%-30s %8d %14d (%6s) %14d %8d",
                                row.candidate.displayName,
                                row.totalProjects,
                                row.zeroViolationProjects,
                                passRate,
                                row.cspViolationProjects,
                                row.projectsTouchingStorage))
        }
        lines.append("")
        for candidate in candidates {
            let offenders = (matrix[candidate] ?? []).filter { !$0.cspViolations.isEmpty }
            guard !offenders.isEmpty else { continue }
            lines.append("Violations under \(candidate.displayName):")
            for entry in offenders.prefix(20) {
                lines.append("  \(entry.project.workshopID) (\(entry.project.title.prefix(40)))")
                for v in entry.cspViolations.prefix(5) {
                    lines.append("    • [\(v.directive ?? "?")] blocked \(v.blockedURI ?? "?")")
                }
                if entry.cspViolations.count > 5 {
                    lines.append("    … +\(entry.cspViolations.count - 5) more")
                }
            }
            if offenders.count > 20 {
                lines.append("  … +\(offenders.count - 20) more violators truncated")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    func writeJSONReport() throws {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let logsDir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Loomscreen", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let url = logsDir.appendingPathComponent("csp-audit-\(timestamp).json")

        var json: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "corpusCount": corpus.count
        ]
        var byCandidate: [String: Any] = [:]
        for candidate in candidates {
            let entries = matrix[candidate] ?? []
            var projects: [[String: Any]] = []
            for entry in entries {
                projects.append([
                    "id": entry.project.workshopID,
                    "title": entry.project.title,
                    "didLoad": entry.didLoad,
                    "loadError": entry.loadError as Any,
                    "cspViolations": entry.cspViolations.map { ["directive": $0.directive ?? "", "blockedURI": $0.blockedURI ?? ""] },
                    "jsErrors": entry.jsErrors.map { ["message": $0.message, "source": $0.sourceFile ?? ""] },
                    "storage": entry.storageProbes.map { $0.message }
                ])
            }
            byCandidate[candidate.rawValue] = ["projects": projects]
        }
        json["matrix"] = byCandidate
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
        print("[CSP audit] report written to \(url.path)")
    }
}
