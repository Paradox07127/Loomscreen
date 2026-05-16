import CoreGraphics
import Foundation

/// Lightweight, Equatable snapshot of a video file's format characteristics.
/// Populated by `PlayableVideoLoader.detectFormat(at:)`. Drives UI badges
/// (ProRes / HDR / 4K) and unlocks the EDR rendering path for HDR sources.
public struct VideoFormatInfo: Equatable, Hashable, Sendable {
    public let codecFourCC: String?
    public let isHDR: Bool
    public let resolution: CGSize?
    public let frameRate: Double?

    public init(
        codecFourCC: String? = nil,
        isHDR: Bool = false,
        resolution: CGSize? = nil,
        frameRate: Double? = nil
    ) {
        self.codecFourCC = codecFourCC
        self.isHDR = isHDR
        self.resolution = resolution
        self.frameRate = frameRate
    }
}

extension VideoFormatInfo {
    public var isProRes: Bool {
        guard let codec = codecFourCC?.lowercased() else { return false }
        return ["apch", "apcn", "apcs", "apco", "ap4h", "ap4x"].contains(codec)
    }

    public var is4K: Bool {
        guard let size = resolution else { return false }
        return max(size.width, size.height) >= 3840
    }

    public var is8K: Bool {
        guard let size = resolution else { return false }
        return max(size.width, size.height) >= 7680
    }

    /// Ordered list of badges to display, longest-edge resolution first so
    /// "4K HDR ProRes" reads naturally.
    public var badges: [String] {
        var result: [String] = []
        if is8K {
            result.append("8K")
        } else if is4K {
            result.append("4K")
        }
        if isHDR { result.append("HDR") }
        if isProRes { result.append("ProRes") }
        return result
    }
}
