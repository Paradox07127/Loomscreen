import Foundation
import Metal

/// BC1/2/3/7 → RGBA8 transcode entry point. Phase 2.1 scaffolds the API
/// but does NOT ship a real GPU transcode: a `blitEncoder.copy(...)`
/// cannot transcode between pixel formats, so the original implementation
/// produced black/garbage output. A correct transcode requires a render
/// or compute pipeline that *samples* the BC source texture and writes
/// the result into an `.rgba8Unorm` target — that's Phase 2.2 work.
///
/// Until then `transcode(...)` returns `.metalUnavailable(format:)` so
/// the resolver maps the error to a precise `texUnsupportedFormat` UI
/// reason. Empirically, the user's 9 imported scenes are 100%
/// RGBA8888/RGBA1010102, so deferring BC has zero impact on coverage.
///
/// Modeled as an `enum` (no instance, no stored Metal state) so the
/// type is trivially `Sendable` under Swift 6 strict concurrency without
/// resorting to `@unchecked Sendable` on `MTLDevice` / `MTLCommandQueue`.
enum WPETexMetalTranscoder {

    /// Reports whether Phase 2.1 can transcode the given format. Always
    /// `false` for BC family right now; honest answer for the import
    /// service so it can mark the layer as unresolvable up front.
    static func isAvailable(for format: WPETexFormat) -> Bool {
        // Phase 2.2 will return `MTLCreateSystemDefaultDevice()?.supportsBCTextureCompression ?? false`
        // once the render-pass-backed transcoder lands.
        _ = format
        return false
    }

    static func transcode(
        _ bytes: Data,
        format: WPETexFormat,
        width: Int,
        height: Int,
        mipmap: Int
    ) throws -> DecodedRGBAImage {
        _ = (bytes, width, height, mipmap)
        throw WPETexDecodeError.metalUnavailable(format: format)
    }
}
