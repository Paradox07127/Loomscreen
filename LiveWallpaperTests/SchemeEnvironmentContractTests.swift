import Foundation
import Testing

@Suite("Shared scheme environment contracts")
struct SchemeEnvironmentContractTests {
    private let schemes = [
        "LiveWallpaper.xcodeproj/xcshareddata/xcschemes/LiveWallpaper.xcscheme",
        "LiveWallpaper.xcodeproj/xcshareddata/xcschemes/LiveWallpaperLite.xcscheme",
    ]

    @Test("Profile uses a neutral Release environment", arguments: [
        "LiveWallpaper.xcodeproj/xcshareddata/xcschemes/LiveWallpaper.xcscheme",
        "LiveWallpaper.xcodeproj/xcshareddata/xcschemes/LiveWallpaperLite.xcscheme",
    ])
    func profileDoesNotInheritLaunchEnvironment(relativePath: String) throws {
        let document = try XMLDocument(
            contentsOf: RepositoryRoot.url(relativePath),
            options: []
        )
        let root = try #require(document.rootElement())
        let profile = try #require(root.elements(forName: "ProfileAction").first)

        #expect(profile.attribute(forName: "buildConfiguration")?.stringValue == "Release")
        #expect(profile.attribute(forName: "shouldUseLaunchSchemeArgsEnv")?.stringValue == "NO")
        #expect(profile.elements(forName: "EnvironmentVariables").isEmpty)
        #expect(profile.elements(forName: "CommandLineArguments").isEmpty)
    }

    // LaunchAction 的 buildConfiguration 和 MTL_HUD_ENABLED 是本机调试偏好,开发者随时会翻;
    // 断言它们只会让别人改自己的 scheme 时无故变红。出货路径(Profile/Archive)才值得设防。
    @Test("Metal HUD never reaches the Profile or Archive actions")
    func metalHUDStaysOutOfShippingActions() throws {
        for relativePath in schemes {
            let document = try XMLDocument(
                contentsOf: RepositoryRoot.url(relativePath),
                options: []
            )
            let root = try #require(document.rootElement())
            let profile = try #require(root.elements(forName: "ProfileAction").first)
            let archive = try #require(root.elements(forName: "ArchiveAction").first)

            #expect(profile.attribute(forName: "buildConfiguration")?.stringValue == "Release")
            #expect(archive.attribute(forName: "buildConfiguration")?.stringValue == "Release")

            let nonLaunchVariables = [profile, archive]
                .flatMap { $0.elements(forName: "EnvironmentVariables") }
                .flatMap { $0.elements(forName: "EnvironmentVariable") }

            #expect(nonLaunchVariables.allSatisfy {
                $0.attribute(forName: "key")?.stringValue != "MTL_HUD_ENABLED"
            })
        }
    }

    @Test("Developer Tools stay outside every shipping capability catalog")
    func developerToolsAreLocalProDebugOnly() throws {
        let app = try RepositoryRoot.source("LiveWallpaper/App/LiveWallpaperApp.swift")
        let capabilities = try RepositoryRoot.source(
            "Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift"
        )
        let developerToolsView = try RepositoryRoot.source(
            "LiveWallpaper/Views/Settings/DeveloperToolsView.swift"
        )
        let htmlWallpaper = try RepositoryRoot.source(
            "LiveWallpaper/VideoPlayback/HTMLWallpaperView.swift"
        )

        let proStart = try #require(capabilities.range(of: "public static let pro"))
        let fromPro = capabilities[proStart.lowerBound...]
        let proEnd = try #require(fromPro.range(of: "public func withWorkshopOnline"))
        let shippingProDeclaration = fromPro[..<proEnd.lowerBound]
        let appCapabilitiesStart = try #require(app.range(of: "let shippingProCapabilities = ProductCapabilities.pro.withWorkshopOnline()"))
        let fromAppCapabilities = app[appCapabilitiesStart.lowerBound...]
        let appCapabilitiesEnd = try #require(fromAppCapabilities.range(of: "screenManagerOptions = ScreenManagerStartupOptions("))
        let appCapabilitiesDeclaration = fromAppCapabilities[..<appCapabilitiesEnd.lowerBound]
        let appCapabilityLines = appCapabilitiesDeclaration
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let developerModeStart = try #require(htmlWallpaper.range(of: "func applyDeveloperMode(_ enabled: Bool)"))
        let fromDeveloperMode = htmlWallpaper[developerModeStart.lowerBound...]
        let developerModeEnd = try #require(fromDeveloperMode.range(of: "private func installBaselineUserScripts"))
        let developerModeDeclaration = fromDeveloperMode[..<developerModeEnd.lowerBound]

        #expect(!shippingProDeclaration.contains(".developerTools"))
        #expect(appCapabilityLines == [
            "let shippingProCapabilities = ProductCapabilities.pro.withWorkshopOnline()",
            "#if DEBUG",
            "let proCapabilities = shippingProCapabilities.withLocalDeveloperTools()",
            "#else",
            "let proCapabilities = shippingProCapabilities",
            "#endif",
        ])
        #expect(developerToolsView.hasPrefix("#if DEBUG && !LITE_BUILD\n"))
        #expect(developerModeDeclaration.contains("#if DEBUG && !LITE_BUILD"))
        #expect(developerModeDeclaration.contains("webView.isInspectable = enabled"))
        #expect(developerModeDeclaration.contains("#else"))
        #expect(developerModeDeclaration.contains("webView.isInspectable = false"))
        #expect(developerModeDeclaration.contains("#endif"))
    }

    @Test("AppIntents stays out of the target graph until a product integration exists")
    func appIntentsRequiresAnExplicitIntegration() throws {
        let project = try RepositoryRoot.source("LiveWallpaper.xcodeproj/project.pbxproj")
        let reviewedFiles = ["LiveWallpaper", "LiveWallpaperTests", "Packages"]
            .flatMap { RepositoryRoot.swiftFiles(under: $0) }
        let importNeedle = ["import", "AppIntents"].joined(separator: " ")

        #expect(!reviewedFiles.isEmpty)
        #expect(!project.contains("AppIntents.framework"))
        for file in reviewedFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !source.contains(importNeedle),
                Comment(rawValue: "\(file.path) imports AppIntents without a reviewed product integration")
            )
        }
    }
}
