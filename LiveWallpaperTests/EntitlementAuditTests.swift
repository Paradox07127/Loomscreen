import Foundation
import Security
import Testing

@Suite("Entitlement audit — per-SKU App Sandbox invariants")
struct EntitlementAuditTests {
    private enum EntitlementValue: Equatable {
        case boolean(Bool)
        case strings([String])

        init?(_ rawValue: Any) {
            if let strings = rawValue as? [String] {
                self = .strings(strings)
            } else if let boolean = rawValue as? Bool {
                self = .boolean(boolean)
            } else {
                return nil
            }
        }
    }

    private struct Profile {
        let name: String
        let sourcePath: String
        let values: [String: EntitlementValue]
        let forbiddenKeys: Set<String>
    }

    private enum AuditError: Error {
        case invalidPropertyList(String)
        case unsupportedValue(key: String)
        case missingProjectConfiguration(String)
    }

    private static let sharedValues: [String: EntitlementValue] = [
        "com.apple.security.app-sandbox": .boolean(true),
        "com.apple.security.automation.startup-items": .boolean(true),
        "com.apple.security.device.power": .boolean(true),
        "com.apple.security.exception.mach-lookup.global-name": .strings(["com.apple.audioanalyticsd"]),
        "com.apple.security.files.bookmarks.app-scope": .boolean(true),
        "com.apple.security.files.user-selected.read-write": .boolean(true),
        "com.apple.security.network.client": .boolean(true),
        "com.apple.security.personal-information.location": .boolean(true),
        "com.apple.security.temporary-exception.iokit-user-client-class": .strings(["AppleSMCClient"]),
        "com.apple.security.temporary-exception.sbpl": .strings([
            "(allow process-info-listpids)",
            "(allow process-info-pidinfo)",
            "(allow process-info-rusage)",
        ]),
    ]

    private static let proOnlyValues: [String: EntitlementValue] = [
        "com.apple.security.device.audio-input": .boolean(true),
        "com.apple.security.network.server": .boolean(true),
        "com.apple.security.temporary-exception.files.absolute-path.read-only": .strings([
            "/opt/homebrew/",
            "/usr/local/",
            "/opt/local/",
        ]),
    ]

    private static let weakeningKeys: Set<String> = [
        "com.apple.security.cs.allow-dyld-environment-variables",
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.temporary-exception.files.absolute-path.read-write",
        "com.apple.security.temporary-exception.files.home-relative-path.read-write",
    ]

    private static let pro = Profile(
        name: "Pro",
        sourcePath: "LiveWallpaper/LiveWallpaper.entitlements",
        values: sharedValues.merging(proOnlyValues) { _, proOnly in proOnly },
        forbiddenKeys: weakeningKeys
    )

    private static let lite = Profile(
        name: "Lite",
        sourcePath: "LiveWallpaper/LiveWallpaperLite.entitlements",
        values: sharedValues,
        forbiddenKeys: weakeningKeys.union(proOnlyValues.keys)
    )

    private static var compiledProfile: Profile {
        #if LITE_BUILD
            lite
        #else
            pro
        #endif
    }

    @Test("Source plists exactly match the Pro and Lite allowlists")
    func sourcePlistsExactlyMatchAllowlist() throws {
        for profile in [Self.pro, Self.lite] {
            let actual = try Self.sourceValues(at: profile.sourcePath)
            #expect(
                actual == profile.values,
                Comment(rawValue: "\(profile.name) source entitlements drifted from its reviewed key/value allowlist")
            )
        }
    }

    @Test("Lite removes exactly the three Pro-only grant families")
    func liteDeltaIsExact() throws {
        let proValues = try Self.sourceValues(at: Self.pro.sourcePath)
        let liteValues = try Self.sourceValues(at: Self.lite.sourcePath)
        let removedKeys = Set(proValues.keys).subtracting(liteValues.keys)

        #expect(removedKeys == Set(Self.proOnlyValues.keys))
        #expect(Set(liteValues.keys).subtracting(proValues.keys).isEmpty)
        for key in Self.sharedValues.keys {
            #expect(liteValues[key] == proValues[key], Comment(rawValue: "Shared grant drifted for \(key)"))
        }
    }

    @Test("Xcode maps both configurations of each SKU to its own plist")
    func projectMapsEachSKUToItsOwnPlist() throws {
        let project = try RepositoryRoot.source("LiveWallpaper.xcodeproj/project.pbxproj")
        for objectID in ["0C322C152D6950490033C48B", "0C322C162D6950490033C48B"] {
            let configuration = try Self.projectConfiguration(objectID, in: project)
            #expect(configuration.contains("CODE_SIGN_ENTITLEMENTS = LiveWallpaper/LiveWallpaper.entitlements;"))
            #expect(!configuration.contains("LiveWallpaperLite.entitlements"))
        }
        for objectID in ["0CA00000000000000000B006", "0CA00000000000000000B007"] {
            let configuration = try Self.projectConfiguration(objectID, in: project)
            #expect(configuration.contains("CODE_SIGN_ENTITLEMENTS = LiveWallpaper/LiveWallpaperLite.entitlements;"))
            #expect(configuration.contains("LITE_BUILD"))
        }
    }

    @Test("Signed host exposes its compile-time SKU grants and no forbidden grants")
    func signedHostMatchesCompiledProfile() {
        let profile = Self.compiledProfile
        for (key, expected) in profile.values.sorted(by: { $0.key < $1.key }) {
            let actual = Self.runtimeValue(for: key)
            #expect(
                actual == Self.expectedHostValue(expected, for: key),
                Comment(rawValue: "Signed \(profile.name) host has the wrong value for \(key)")
            )
        }
        for key in profile.forbiddenKeys.sorted() {
            #expect(Self.runtimeValue(for: key) == nil, Comment(rawValue: "Signed \(profile.name) host unexpectedly grants \(key)"))
        }
    }

    @Test("Lite signed audit remains an explicit release-artifact gate")
    func liteSignedAuditIsNotPretendedByProTestHost() throws {
        let project = try RepositoryRoot.source("LiveWallpaper.xcodeproj/project.pbxproj")
        let testConfiguration = try Self.projectConfiguration("0C322C182D6950490033C48B", in: project)
        let releaseScript = try RepositoryRoot.source("scripts/release-app.sh")

        #expect(testConfiguration.contains("TEST_HOST = \"$(BUILT_PRODUCTS_DIR)/LiveWallpaper.app/"))
        #expect(releaseScript.contains("scripts/check_entitlements.sh --sku \"$SKU\" --app \"$APP_PATH\""))
    }

    @Test("Release gate structurally parses entitlements and runs its adversarial fixtures")
    func releaseGateUsesStructuralParserAndSelfTest() throws {
        let gate = try RepositoryRoot.source("scripts/check_entitlements.sh")
        let contract = try RepositoryRoot.source("scripts/release_contract_check.sh")

        #expect(gate.contains("scripts/entitlement_fingerprint.py"))
        #expect(!gate.contains("| awk"))
        #expect(gate.contains("EXPECTED_BUNDLE_ID=\"Taijia.LiveWallpaper\""))
        #expect(gate.contains("EXPECTED_BUNDLE_ID=\"com.loomscreen\""))
        #expect(gate.contains("EXPECTED_TEAM_ID=\"FWJP4B62U7\""))
        #expect(contract.contains("bash scripts/check_entitlements_self_test.sh"))
    }

    @Test("Monitor SBPL grants stay read-only")
    func monitorSBPLGrantsStayReadOnly() {
        guard case let .strings(rules)? = Self.sharedValues["com.apple.security.temporary-exception.sbpl"] else {
            Issue.record("Missing SBPL allowlist")
            return
        }
        #expect(rules.allSatisfy { $0.hasPrefix("(allow process-info-") })
        let joined = rules.joined(separator: " ")
        for forbidden in ["setcontrol", "dirtycontrol", "process-info-argv", "process-info-codesignature"] {
            #expect(!joined.contains(forbidden))
        }
    }

    private static func sourceValues(at relativePath: String) throws -> [String: EntitlementValue] {
        let data = try RepositoryRoot.data(relativePath)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AuditError.invalidPropertyList(relativePath)
        }
        return try Dictionary(uniqueKeysWithValues: plist.map { key, value in
            guard let decoded = EntitlementValue(value) else {
                throw AuditError.unsupportedValue(key: key)
            }
            return (key, decoded)
        })
    }

    private static func runtimeValue(for key: String) -> EntitlementValue? {
        guard let task = SecTaskCreateFromSelf(nil),
              let rawValue = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else {
            return nil
        }
        return EntitlementValue(rawValue)
    }

    private static func expectedHostValue(
        _ sourceValue: EntitlementValue,
        for key: String
    ) -> EntitlementValue {
        #if DEBUG
            // Xcode's signed test host adds the repository root ("/") to this
            // existing entitlement so XCTest can load sources outside the app
            // container. Release artifacts are still checked against the exact
            // source fingerprint by scripts/check_entitlements.sh --app.
            if key == "com.apple.security.temporary-exception.files.absolute-path.read-only",
               case let .strings(paths) = sourceValue {
                return .strings(paths + ["/"])
            }
        #endif
        return sourceValue
    }

    private static func projectConfiguration(_ objectID: String, in source: String) throws -> Substring {
        guard let start = source.range(of: "\t\t\(objectID) /*"),
              let end = source[start.lowerBound...].range(of: "\n\t\t};") else {
            throw AuditError.missingProjectConfiguration(objectID)
        }
        return source[start.lowerBound ..< end.upperBound]
    }
}
