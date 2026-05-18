#if !LITE_BUILD
import Foundation
import Metal

/// Legacy BC1/2/3/7 → RGBA8 transcode entry point for callers that still
/// require a CPU-side `CGImage`. Phase 2A does not extend this path:
/// Apple Silicon Metal renderers sample supported BC textures natively via
/// `WPEMetalTextureFormatMapper`, while SpriteKit/CGImage decode remains
/// fail-closed for compressed formats.
///
/// Until then `transcode(...)` returns `.metalUnavailable(format:)` so
/// the resolver maps the error to a precise `texUnsupportedFormat` UI
/// reason. The 431960 sample set includes BC-family textures, so those
/// layers stay degraded until the Phase 2.2 transcoder lands.
///
/// Modeled as an `enum` (no instance, no stored Metal state) so the
/// type is trivially `Sendable` under Swift 6 strict concurrency without
/// resorting to `@unchecked Sendable` on `MTLDevice` / `MTLCommandQueue`.
enum WPETexMetalTranscoder {

    /// Reports whether the legacy CGImage path can transcode the given format.
    static func isAvailable(for format: WPETexFormat) -> Bool {
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
#endif
