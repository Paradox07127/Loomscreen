import CoreGraphics
import Testing
import LiveWallpaperSharedUI

@Suite("Settings sticky section headers")
struct SettingsStickySectionHeaderTests {
    @Test("Uses first upcoming header before any section reaches sticky edge")
    func usesFirstUpcomingHeaderBeforeStickyEdge() {
        let measurements = [
            SettingsStickySectionHeaderMeasurement(id: "video", title: .localizedKey("Video"), minY: 32),
            SettingsStickySectionHeaderMeasurement(id: "web", title: .localizedKey("Web"), minY: 220),
        ]

        let active = SettingsStickySectionHeaderResolver.activeHeader(in: measurements, stickyTopY: 16)

        #expect(active?.id == "video")
    }

    @Test("Uses latest header that has reached the sticky edge")
    func usesLatestHeaderThatReachedStickyEdge() {
        let measurements = [
            SettingsStickySectionHeaderMeasurement(id: "video", title: .localizedKey("Video"), minY: -120),
            SettingsStickySectionHeaderMeasurement(id: "web", title: .localizedKey("Web"), minY: 8),
            SettingsStickySectionHeaderMeasurement(id: "scene", title: .localizedKey("Scene"), minY: 180),
        ]

        let active = SettingsStickySectionHeaderResolver.activeHeader(in: measurements, stickyTopY: 16)

        #expect(active?.id == "web")
    }
}
