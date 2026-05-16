import Testing
@testable import LiveWallpaperVideoWeb

/// Phase 2a smoke test — verifies the SPM package builds standalone and
/// can reach LiveWallpaperCore through its declared dependency.
@Suite("LiveWallpaperVideoWeb package scaffold")
struct PackageScaffoldTests {

    @Test("Package scaffold reports a stable version stamp")
    func packageVersionPresent() {
        #expect(LiveWallpaperVideoWeb.packageVersion.hasPrefix("0."))
    }
}
