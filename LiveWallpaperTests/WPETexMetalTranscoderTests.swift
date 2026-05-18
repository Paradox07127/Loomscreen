import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPETexMetalTranscoder — BC compatibility gate")
struct WPETexMetalTranscoderTests {

    @Test("Legacy transcoder remains unavailable; Phase 2A uses native texture mapping")
    func legacyTranscoderRemainsUnavailable() {
        #expect(!WPETexMetalTranscoder.isAvailable(for: .dxt1))
        #expect(!WPETexMetalTranscoder.isAvailable(for: .dxt3))
        #expect(!WPETexMetalTranscoder.isAvailable(for: .dxt5))
        #expect(!WPETexMetalTranscoder.isAvailable(for: .bc7))
    }

    @Test("Calling transcode for a BC format throws metalUnavailable with the requested format")
    func transcodeBCThrowsMetalUnavailable() throws {
        for format in [WPETexFormat.dxt1, .dxt3, .dxt5, .bc7] {
            do {
                _ = try WPETexMetalTranscoder.transcode(
                    Data(count: 16),
                    format: format,
                    width: 4,
                    height: 4,
                    mipmap: 0
                )
                Issue.record("Expected metalUnavailable for \(format.debugLabel)")
            } catch WPETexDecodeError.metalUnavailable(let surfacedFormat) {
                #expect(surfacedFormat == format)
            } catch {
                Issue.record("Expected metalUnavailable, got \(error)")
            }
        }
    }
}
