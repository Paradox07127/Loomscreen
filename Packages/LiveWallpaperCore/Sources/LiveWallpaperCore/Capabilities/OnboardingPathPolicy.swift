import Foundation

/// One actionable item the onboarding picker can render. Kept as an enum so
/// shader/WPE/Aerials paths can be re-added later as separate cases without
/// reshaping the picker view's switch — for now the product story is
/// deliberately scoped to Video + Web.
public enum OnboardingSourceAction: Sendable, Equatable {
    case video
    case html
}

/// SKU-derived plan for the onboarding source-picker step.
///
/// Both Pro and Lite currently surface the same two sources (Video / Web) —
/// shader is not promoted and WPE is held back until the importer pipeline
/// is more reliable. The `sku` field is kept as a hook for future
/// differentiation (e.g. SKU-aware Done-step tips) without rewriting callers.
public struct OnboardingPathPolicy: Sendable, Equatable {
    public let sku: ProductSKU
    public let galleryActions: [OnboardingSourceAction]

    public init(capabilities: ProductCapabilities) {
        sku = capabilities.sku
        galleryActions = [.video, .html]
    }
}
