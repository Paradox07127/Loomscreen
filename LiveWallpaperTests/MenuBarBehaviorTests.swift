import Foundation
import Testing
@testable import LiveWallpaper

/// Validates the recents-list behavior the menu-bar surface depends on:
/// WPE history mutation semantics, idempotent removal, and the absence of
/// NSOpenPanel coupling in `MenuBarContent.swift`. These guarantees keep the
/// menu bar a pure shortcut surface backed by `BookmarkStore` + WPE history,
/// rather than triggering Open dialogs from the system menu.
@Suite("MenuBar shortcut + recents behavior", .serialized)
@MainActor
struct MenuBarBehaviorTests {

    // MARK: - WPE history removal semantics

    @Test("Removing a known WPE import drops it from the recents list")
    func removingKnownImportDropsIt() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEImport(makeEntry("alpha"))
            manager.recordWPEImport(makeEntry("beta"))

            manager.removeWPEImport(workshopID: "alpha")

            let ids = manager.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID)
            #expect(ids == ["beta"])
        }
    }

    @Test("Removing an unknown WPE import is a no-op (no notification posted)")
    func removingUnknownImportIsNoOp() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEImport(makeEntry("alpha"))

            let observer = NotificationObserver(name: .wpeHistoryDidChange)
            defer { observer.detach() }

            manager.removeWPEImport(workshopID: "ghost-id")

            #expect(observer.callCount == 0)
            let ids = manager.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID)
            #expect(ids == ["alpha"])
        }
    }

    @Test("Removing every entry leaves the recents list empty")
    func removingAllEntriesEmptiesList() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEImport(makeEntry("one"))
            manager.recordWPEImport(makeEntry("two"))
            manager.removeWPEImport(workshopID: "one")
            manager.removeWPEImport(workshopID: "two")

            #expect(manager.loadGlobalSettings().recentWPEImports.isEmpty)
        }
    }

    @Test("Recording an import posts a wpeHistoryDidChange notification")
    func recordingImportPostsNotification() throws {
        withIsolatedGlobalSettings {
            let observer = NotificationObserver(name: .wpeHistoryDidChange)
            defer { observer.detach() }

            SettingsManager.shared.recordWPEImport(makeEntry("notify"))

            #expect(observer.callCount == 1)
        }
    }

    // MARK: - Structural guarantee: MenuBar surface stays panel-free

    @Test("MenuBarContent does not invoke NSOpenPanel directly")
    func menuBarContentHasNoOpenPanelCoupling() throws {
        // Every MenuBar* file, not just MenuBarContent.swift: splitting the view
        // out into siblings must not let NSOpenPanel back in unscanned.
        let sources = Self.menuBarSourceFiles()
        #expect(!sources.isEmpty, "No MenuBar sources found under LiveWallpaper/Views — the scan is misconfigured")

        for url in sources {
            let contents = try String(contentsOf: url, encoding: .utf8)
            #expect(!contents.contains("NSOpenPanel"),
                    "\(url.lastPathComponent) must stay free of NSOpenPanel — keep the menu bar a shortcut surface only")
        }
    }

    @Test("MenuBarContent exposes video volume without opening a panel")
    func menuBarContentExposesVideoVolumeControl() throws {
        let source = try readMenuBarSource()

        #expect(source.contains("Slider("))
        #expect(source.contains("updateVideoVolume"))
    }

    @Test("Performance values use the emphasized metric token and keep their combined accessibility label")
    func performanceValuesUseSemanticMetricContract() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/MenuBarContent.swift")
        guard let start = source.range(of: "private func performanceItem"),
              let end = source.range(of: "private var footer", range: start.upperBound..<source.endIndex) else {
            Issue.record("Could not isolate MenuBarContent.performanceItem source")
            return
        }
        let performanceItem = String(source[start.lowerBound..<end.lowerBound])

        #expect(performanceItem.contains(".font(DesignTokens.Typography.metricEmphasized)"))
        #expect(performanceItem.contains(".accessibilityElement(children: .ignore)"))
        #expect(performanceItem.contains(".accessibilityLabel(Text(\"\\(label) \\(value)\"))"))
        #expect(
            Self.performanceItemAccessibilityContractHolds(performanceItem),
            "Only the Circle status dot may be hidden; the HStack must expose its combined label"
        )

        let containerHiddenProbe = performanceItem
            .replacingOccurrences(of: ".accessibilityHidden(true)", with: "")
            .replacingOccurrences(
                of: ".lineLimit(1)",
                with: ".accessibilityHidden(\n    true\n)\n        .lineLimit(1)"
            )
        let normalizedContainerHiddenProbe = containerHiddenProbe.filter { !$0.isWhitespace }
        #expect(
            normalizedContainerHiddenProbe.components(separatedBy: ".accessibilityHidden(true)").count - 1 == 1
                && normalizedContainerHiddenProbe.contains("}.accessibilityHidden(true).lineLimit(1)"),
            "The negative probe must contain exactly one hidden modifier on the HStack"
        )
        #expect(
            !Self.performanceItemAccessibilityContractHolds(containerHiddenProbe),
            "The accessibility guard must reject whitespace-varied hiding on the whole HStack"
        )

        let boolContainerHiddenProbe = performanceItem.replacingOccurrences(
            of: ".lineLimit(1)",
            with: ".accessibilityHidden(Bool(true)).lineLimit(1)"
        )
        #expect(
            boolContainerHiddenProbe.contains(".accessibilityHidden(Bool(true))"),
            "The Bool(true) negative probe must hide the HStack"
        )
        #expect(
            !Self.performanceItemAccessibilityContractHolds(boolContainerHiddenProbe),
            "The accessibility guard must reject non-literal hiding on the whole HStack"
        )

        let tokens = try RepositoryRoot.source(
            "Packages/LiveWallpaperSharedUI/Sources/LiveWallpaperSharedUI/Tokens/DesignTokens.swift"
        )
        guard let tokenStart = tokens.range(of: "public static let metricEmphasized"),
              let tokenEnd = tokens.range(of: "public static let code", range: tokenStart.upperBound..<tokens.endIndex) else {
            Issue.record("Could not isolate DesignTokens.Typography.metricEmphasized")
            return
        }
        let token = String(tokens[tokenStart.lowerBound..<tokenEnd.lowerBound])
        let normalizedToken = token.filter { !$0.isWhitespace }
        #expect(
            normalizedToken
                == "publicstaticletmetricEmphasized=Font.system(.callout,design:.monospaced).weight(.semibold).monospacedDigit()"
        )
        let designContract = try RepositoryRoot.source("Packages/LiveWallpaperSharedUI/DESIGN.md")
        #expect(designContract.contains("+3 emphasized variants"))
        #expect(designContract.contains("`metricEmphasized` | `.callout.monospaced.semibold.monospacedDigit()`"))
    }

    private static func performanceItemAccessibilityContractHolds(_ source: String) -> Bool {
        let normalized = source.filter { !$0.isWhitespace }
        let hidden = ".accessibilityHidden(true)"
        guard normalized.components(separatedBy: hidden).count - 1 == 1,
              let hStack = normalized.range(of: "HStack(spacing:5){") else {
            return false
        }

        let openBrace = normalized.index(before: hStack.upperBound)
        guard let closeBrace = matchingClosingBrace(in: normalized, openingAt: openBrace) else {
            return false
        }

        let contentStart = normalized.index(after: openBrace)
        let content = String(normalized[contentStart..<closeBrace])
        let containerModifiers = String(normalized[normalized.index(after: closeBrace)...])
        let statusDot = "Circle().fill(tint).frame(width:6,height:6).animation(.easeInOut(duration:0.25),value:tint)\(hidden)"

        return content.contains(statusDot)
            && !containerModifiers.contains(".accessibilityHidden(")
            && containerModifiers.contains(".accessibilityElement(children:.ignore)")
            && containerModifiers.contains(".accessibilityLabel(Text(\"\\(label)\\(value)\"))")
    }

    private static func matchingClosingBrace(in source: String, openingAt openBrace: String.Index) -> String.Index? {
        var depth = 0
        var index = openBrace
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }
            index = source.index(after: index)
        }
        return nil
    }

    private func withIsolatedGlobalSettings(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = [
            "screenConfigurations",
            "globalSettings",
            "AerialsLibrary.DirectoryBookmark",
            "WallpaperBookmarks.v1",
            "TrustedHTMLHosts.v1",
        ]
        let previousValues = keys.reduce(into: [String: Any]()) { result, key in
            result[key] = defaults.object(forKey: key)
        }

        SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)
        defer {
            SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)
            for key in keys {
                if let value = previousValues[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        try body()
    }

    private func makeEntry(
        _ workshopID: String,
        title: String? = nil,
        lastUsedAt: Date? = nil
    ) -> WPEHistoryEntry {
        let origin = WPEOrigin(
            workshopID: workshopID,
            title: title ?? "Wallpaper \(workshopID)",
            originalType: .video,
            sourceFolderBookmark: Data(workshopID.utf8),
            cacheRelativePath: "wpe-cache/\(workshopID)",
            previewFileName: "preview.gif"
        )
        return WPEHistoryEntry(
            origin: origin,
            importedAt: Date(timeIntervalSince1970: 0),
            lastUsedAt: lastUsedAt
        )
    }

    static func menuBarSourceFiles() -> [URL] {
        RepositoryRoot.swiftFiles(under: "LiveWallpaper/Views")
            .filter { $0.lastPathComponent.hasPrefix("MenuBar") }
    }

    private func readMenuBarSource() throws -> String {
        let sources = Self.menuBarSourceFiles()
        guard !sources.isEmpty else {
            Issue.record("No MenuBar sources found under LiveWallpaper/Views; fix the test path resolver")
            return ""
        }
        return try sources.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }
}

/// Captures the number of times a notification fires. Synchronous observer
/// keeps the body race-free under Swift 6; the lock guards the count so we
/// can mark the type Sendable without main-actor isolation, which lets
/// `deinit` clean the observer up in any cleanup order the runtime picks.
private final class NotificationObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var token: NSObjectProtocol?

    init(name: Notification.Name) {
        token = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.bump()
        }
    }

    deinit {
        detach()
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    func detach() {
        if let token {
            NotificationCenter.default.removeObserver(token)
            self.token = nil
        }
    }

    private func bump() {
        lock.lock(); defer { lock.unlock() }
        _callCount += 1
    }
}
