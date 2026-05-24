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
    public var badges: [VideoFormatBadge] {
        var result: [VideoFormatBadge] = []
        if is8K {
            result.append(.resolution8K)
        } else if is4K {
            result.append(.resolution4K)
        }
        if isHDR { result.append(.hdr) }
        if isProRes { result.append(.proRes) }
        return result
    }
}

/// Type-safe representation of the badge taxonomy surfaced by
/// `VideoFormatInfo.badges`. Each case maps to a short, verbatim glyph
/// label ("4K", "HDR", "ProRes") that — per Apple HIG — is not translated,
/// but having an enum unlocks exhaustive switching, Equatable comparison
/// in tests, and a single rename surface if the visual representation
/// changes later.
public enum VideoFormatBadge: Equatable, Hashable, Sendable {
    case resolution4K
    case resolution8K
    case hdr
    case proRes

    /// Verbatim glyph shown in the inspector capsule and aerial card.
    public var displayLabel: String {
        switch self {
        case .resolution4K: return "4K"
        case .resolution8K: return "8K"
        case .hdr:          return "HDR"
        case .proRes:       return "ProRes"
        }
    }
}
