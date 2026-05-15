import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPEBuiltinFrameworkAssets")
struct WPEBuiltinFrameworkAssetsTests {

    @Test(
        "All expected built-in files are present in the bundle",
        .enabled(if: WPEBuiltinFrameworkAssets.rootURL != nil)
    )
    func allExpectedBuiltInFilesArePresentInBundle() throws {
        let rootURL = try #require(WPEBuiltinFrameworkAssets.rootURL)
        let resolver = SceneResourceResolver(cacheRootURL: rootURL)

        for relativePath in WPEBuiltinFrameworkAssets.expectedFiles {
            let fileURL = try resolver.resolveExistingFileURL(relativePath: relativePath)
            let values = try fileURL.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey
            ])
            #expect(values.isRegularFile == true, "Expected regular file at \(relativePath)")
            #expect((values.fileSize ?? 0) > 0, "Expected non-empty file at \(relativePath)")
        }
    }

    @Test(
        "Built-in resolver returns canonical material wrappers",
        .enabled(if: WPEBuiltinFrameworkAssets.rootURL != nil)
    )
    func builtInResolverReturnsCanonicalMaterialWrappers() throws {
        let rootURL = try #require(WPEBuiltinFrameworkAssets.rootURL)
        let resolver = SceneResourceResolver(cacheRootURL: rootURL)

        let url = try resolver.resolveExistingFileURL(
            relativePath: "models/util/composelayer.json"
        )

        #expect(url.lastPathComponent == "composelayer.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "util")
    }
}
