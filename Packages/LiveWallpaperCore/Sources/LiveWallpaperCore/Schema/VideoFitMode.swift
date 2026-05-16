import AVFoundation
import SwiftUI

public enum VideoFitMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case aspectFill = "Fill"
    case aspectFit = "Fit"
    case stretch = "Stretch"

    public var id: String { rawValue }

    public var titleKey: LocalizedStringKey {
        switch self {
        case .aspectFill: return "Fill"
        case .aspectFit: return "Fit"
        case .stretch: return "Stretch"
        }
    }

    public var descriptionKey: LocalizedStringKey {
        switch self {
        case .aspectFill: return "Fill screen (may crop video)"
        case .aspectFit: return "Fit entire video (may show borders)"
        case .stretch: return "Stretch to fill screen (may distort)"
        }
    }

    public var tooltipKey: LocalizedStringKey {
        switch self {
        case .aspectFill: return "Fill: crop to fill screen"
        case .aspectFit: return "Fit: show entire video"
        case .stretch: return "Stretch: distort to fill"
        }
    }

    public var iconName: String {
        switch self {
        case .aspectFill: return "rectangle.fill"
        case .aspectFit: return "rectangle"
        case .stretch: return "arrow.up.left.and.arrow.down.right"
        }
    }

    public var avLayerVideoGravity: AVLayerVideoGravity {
        switch self {
        case .aspectFill: return .resizeAspectFill
        case .aspectFit: return .resizeAspect
        case .stretch: return .resize
        }
    }
}
