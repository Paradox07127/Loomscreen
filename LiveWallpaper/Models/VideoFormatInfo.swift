import CoreGraphics
import Foundation

/// Lightweight, Equatable snapshot of a video file's format characteristics.
/// Populated by `PlayableVideoLoader.detectFormat(at:)`. Drives UI badges
/// (ProRes / HDR / 4K) and unlocks the EDR rendering path for HDR sources.
struct VideoFormatInfo: Equatable, Hashable, Sendable {
    let codecFourCC: String?
    let isHDR: Bool
    let resolution: CGSize?
    let frameRate: Double?

    init(
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
    var isProRes: Bool {
        guard let codec = codecFourCC?.lowercased() else { return false }
        return ["apch", "apcn", "apcs", "apco", "ap4h", "ap4x"].contains(codec)
    }

    var is4K: Bool {
        guard let size = resolution else { return false }
        return max(size.width, size.height) >= 3840
    }

    var is8K: Bool {
        guard let size = resolution else { return false }
        return max(size.width, size.height) >= 7680
    }

    /// Short codec label suitable for a small badge ("ProRes", "HEVC", "H.264").
    var codecLabel: String? {
        guard let codec = codecFourCC?.lowercased() else { return nil }
        switch codec {
        case "apch", "apcn", "apcs", "apco":
            return "ProRes"
        case "ap4h", "ap4x":
            return "ProRes 4444"
        case "hvc1", "hev1":
            return "HEVC"
        case "avc1":
            return "H.264"
        default:
            return nil
        }
    }

    /// Ordered list of badges to display, longest-edge resolution first so
    /// "4K HDR ProRes" reads naturally.
    var badges: [String] {
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
