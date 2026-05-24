import Testing
import CoreGraphics
@testable import LiveWallpaperCore

@Suite("VideoFormatInfo.badges")
struct VideoFormatInfoTests {

    @Test("Empty info yields no badges")
    func emptyInfoYieldsNoBadges() {
        let info = VideoFormatInfo()
        #expect(info.badges == [])
    }

    @Test("4K resolution surfaces .resolution4K")
    func fourKResolutionSurfaces() {
        let info = VideoFormatInfo(resolution: CGSize(width: 3840, height: 2160))
        #expect(info.badges == [.resolution4K])
    }

    @Test("8K resolution supersedes 4K and surfaces once")
    func eightKResolutionSupersedes() {
        let info = VideoFormatInfo(resolution: CGSize(width: 7680, height: 4320))
        #expect(info.badges == [.resolution8K])
    }

    @Test("HDR and ProRes flags compose with resolution in display order")
    func hdrAndProResComposeInOrder() {
        let info = VideoFormatInfo(
            codecFourCC: "apch",
            isHDR: true,
            resolution: CGSize(width: 3840, height: 2160)
        )
        #expect(info.badges == [.resolution4K, .hdr, .proRes])
    }

    @Test("displayLabel maps each case to its verbatim glyph")
    func displayLabelMapsToGlyph() {
        #expect(VideoFormatBadge.resolution4K.displayLabel == "4K")
        #expect(VideoFormatBadge.resolution8K.displayLabel == "8K")
        #expect(VideoFormatBadge.hdr.displayLabel == "HDR")
        #expect(VideoFormatBadge.proRes.displayLabel == "ProRes")
    }
}
