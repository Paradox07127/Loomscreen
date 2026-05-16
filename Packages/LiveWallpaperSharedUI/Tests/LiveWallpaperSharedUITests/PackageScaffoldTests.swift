import Testing
@testable import LiveWallpaperSharedUI

@Suite("LiveWallpaperSharedUI package scaffold")
struct PackageScaffoldTests {
    @Test("Package scaffold reports a stable version stamp")
    func packageVersionPresent() {
        #expect(LiveWallpaperSharedUI.packageVersion.hasPrefix("0."))
    }
}
