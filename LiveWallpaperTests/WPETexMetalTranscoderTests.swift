import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPETexMetalTranscoder — BC compatibility gate")
struct WPETexMetalTranscoderTests {

    @Test("Phase 2.1 transcoder always reports BC formats as unavailable")
    func bcFormatsReportUnavailable() {
        // The Metal blit-based transcode in Day 2 was incorrect (a blit
        // copy cannot transcode between pixel formats), so Phase 2.1
        // ships with BC explicitly marked unavailable until the
        // shader/compute pipeline arrives in Phase 2.2. The capability
        // tier classifier reads `isAvailable(for:)`, so this test pins
        // the contract that all four BC variants stay non-decodable.
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
