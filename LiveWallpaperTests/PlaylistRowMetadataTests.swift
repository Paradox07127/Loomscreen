import Testing
import CoreGraphics
@testable import LiveWallpaper

@Suite("PlaylistRowMetadata subtitle formatting")
struct PlaylistRowMetadataTests {
    @Test("Subtitle composes resolution, duration, and folder with dot separators")
    func fullSubtitle() {
        let meta = PlaylistRowMetadata(
            resolution: CGSize(width: 1920, height: 1080),
            duration: 30,
            folder: "Wallpapers"
        )
        #expect(meta.subtitle == "1080p · 0:30 · Wallpapers")
    }

    @Test("Missing resolution drops only the resolution segment")
    func missingResolution() {
        let meta = PlaylistRowMetadata(
            resolution: nil,
            duration: 30,
            folder: "Wallpapers"
        )
        #expect(meta.subtitle == "0:30 · Wallpapers")
    }

    @Test("Missing duration drops only the duration segment")
    func missingDuration() {
        let meta = PlaylistRowMetadata(
            resolution: CGSize(width: 1920, height: 1080),
            duration: nil,
            folder: "Wallpapers"
        )
        #expect(meta.subtitle == "1080p · Wallpapers")
    }

    @Test("Empty metadata produces empty subtitle")
    func emptySubtitle() {
        let meta = PlaylistRowMetadata.empty
        #expect(meta.subtitle == "")
    }

    @Test("Resolution bucketing covers SD through 8K")
    func resolutionBuckets() {
        let cases: [(CGSize, String)] = [
            (CGSize(width: 640, height: 480), "480p"),
            (CGSize(width: 1280, height: 720), "720p"),
            (CGSize(width: 1920, height: 1080), "1080p"),
            (CGSize(width: 2560, height: 1440), "1440p"),
            (CGSize(width: 3840, height: 2160), "4K"),
            (CGSize(width: 7680, height: 4320), "8K"),
        ]
        for (size, expected) in cases {
            let meta = PlaylistRowMetadata(resolution: size, duration: nil, folder: nil)
            #expect(meta.subtitle == expected, "size=\(size) expected=\(expected)")
        }
    }

    @Test("Unusual resolutions fall back to raw WxH")
    func unusualResolution() {
        let meta = PlaylistRowMetadata(
            resolution: CGSize(width: 800, height: 100),
            duration: nil,
            folder: nil
        )
        #expect(meta.subtitle == "800×100")
    }

    @Test("Duration formats minutes/seconds without hours when under one hour")
    func durationUnderHour() {
        let meta = PlaylistRowMetadata(
            resolution: nil,
            duration: 65,
            folder: nil
        )
        #expect(meta.subtitle == "1:05")
    }

    @Test("Duration includes hours when at least one hour")
    func durationWithHours() {
        let meta = PlaylistRowMetadata(
            resolution: nil,
            duration: 3661,
            folder: nil
        )
        #expect(meta.subtitle == "1:01:01")
    }

    @Test("Non-positive duration is treated as missing")
    func nonPositiveDuration() {
        let meta = PlaylistRowMetadata(
            resolution: CGSize(width: 1920, height: 1080),
            duration: 0,
            folder: "Wallpapers"
        )
        #expect(meta.subtitle == "1080p · Wallpapers")
    }
}
