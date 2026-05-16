import Testing
@testable import LiveWallpaperProWPE

@Suite("LiveWallpaperProWPE package scaffold")
struct PackageScaffoldTests {
    @Test("Package scaffold reports a stable version stamp")
    func packageVersionPresent() {
        #expect(LiveWallpaperProWPE.packageVersion.hasPrefix("0."))
    }
}
