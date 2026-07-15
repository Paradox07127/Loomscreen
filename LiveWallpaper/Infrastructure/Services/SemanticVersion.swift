import Foundation

/// Minimal three-part semantic version (`major.minor.patch`) with `Comparable`.
/// Accepts the tag forms we publish on GitHub Releases (e.g. `loomscreen-v1.0.1`,
/// `v1.0.1`, `1.0.1`) plus optional `-pre` / `+build` metadata that gets stripped
/// from the patch component. Pre-release ordering (`1.0.0-beta < 1.0.0`) is NOT
/// modeled — Loomscreen ships final tags only, and the update prompt should
/// always treat any newer `major.minor.patch` as the upgrade target.
struct SemanticVersion: Comparable, Equatable, Hashable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(parsing raw: String) {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["loomscreen-v", "lwp-v", "v"] where input.hasPrefix(prefix) {
            input = String(input.dropFirst(prefix.count))
            break
        }

        let parts = input.split(separator: ".", maxSplits: 2)
        guard parts.count >= 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1])
        else { return nil }

        let patch: Int
        if parts.count == 3 {
            let head = parts[2].split(whereSeparator: { $0 == "-" || $0 == "+" }).first
                .map(String.init) ?? String(parts[2])
            guard let value = Int(head) else { return nil }
            patch = value
        } else {
            patch = 0
        }

        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    var description: String { "\(major).\(minor).\(patch)" }
}
