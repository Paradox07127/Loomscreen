import CoreGraphics
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("Video span layout")
struct VideoSpanLayoutTests {

    @Test("Side-by-side displays share one union canvas with per-screen offsets")
    func sideBySideDisplaysProduceExpectedOffsets() throws {
        let layouts = VideoSpanLayout.renderConfigurations(for: [
            .init(screenID: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            .init(screenID: 2, frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        ])

        let left = try #require(layouts[1])
        let right = try #require(layouts[2])

        #expect(left.canvasFrame == CGRect(x: 0, y: 0, width: 3840, height: 1080))
        #expect(left.canvasFrameInScreenCoordinates == CGRect(x: 0, y: 0, width: 3840, height: 1080))
        #expect(right.canvasFrameInScreenCoordinates == CGRect(x: -1920, y: 0, width: 3840, height: 1080))
    }

    @Test("Vertically arranged displays preserve global y offsets")
    func verticalDisplaysProduceExpectedOffsets() throws {
        let layouts = VideoSpanLayout.renderConfigurations(for: [
            .init(screenID: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
            .init(screenID: 2, frame: CGRect(x: 0, y: 900, width: 1440, height: 900))
        ])

        let lower = try #require(layouts[1])
        let upper = try #require(layouts[2])

        #expect(lower.canvasFrameInScreenCoordinates == CGRect(x: 0, y: 0, width: 1440, height: 1800))
        #expect(upper.canvasFrameInScreenCoordinates == CGRect(x: 0, y: -900, width: 1440, height: 1800))
    }
}
