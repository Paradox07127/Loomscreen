import Testing
@testable import LiveWallpaperProFeatures

@Suite("LiveWallpaperProFeatures package scaffold")
struct PackageScaffoldTests {
    @Test("Package scaffold reports a stable version stamp")
    func packageVersionPresent() {
        #expect(LiveWallpaperProFeatures.packageVersion.hasPrefix("0."))
    }
}
