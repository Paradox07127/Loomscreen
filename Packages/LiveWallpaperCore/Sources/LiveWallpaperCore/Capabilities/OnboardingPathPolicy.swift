import Foundation

/// The two first-class entry points the onboarding picker offers. `importFile`
/// opens a single file/folder picker and routes by type (video / web / — on
/// Pro — Wallpaper Engine scene). The second slot is SKU-derived: direct-
/// distribution Pro surfaces Steam Workshop, every other build surfaces Apple
/// Aerials.
public enum OnboardingSourceAction: Sendable, Equatable {
    case importFile
    case workshop
    case appleAerials
}

/// SKU-derived plan for the onboarding source-picker step.
public struct OnboardingPathPolicy: Sendable, Equatable {
    public let sku: ProductSKU
    public let galleryActions: [OnboardingSourceAction]
    /// Whether the flow includes the optional Steam Workshop setup step.
    /// True only when `.workshopOnline` is present (direct-distribution Pro).
    public let showsWorkshopSetup: Bool

    public init(capabilities: ProductCapabilities) {
        sku = capabilities.sku
        let hasWorkshop = capabilities.enabledFeatures.contains(.workshopOnline)
        galleryActions = [.importFile, hasWorkshop ? .workshop : .appleAerials]
        showsWorkshopSetup = hasWorkshop
    }
}
