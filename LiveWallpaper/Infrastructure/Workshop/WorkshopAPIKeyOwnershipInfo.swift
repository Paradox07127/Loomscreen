#if !LITE_BUILD && DIRECT_DISTRIBUTION
import Foundation

/// Single source of truth for the official Valve links + the user-facing copy
/// that explains the Steam Web API key belongs to the user's own Steam
/// account (not Loomscreen), and the eligibility gate Valve enforces. Shared
/// across `SteamWebAPIKeyEntrySheet`, `WorkshopSettingsView`, and
/// `WorkshopOnboardingSheet` so translations stay aligned.
enum WorkshopAPIKeyOwnershipInfo {
    /// Where the user registers / revokes their own key.
    static let registerURL = URL(string: "https://steamcommunity.com/dev/apikey")!
    /// Steam Web API Terms of Use (quota + acceptable use).
    static let touURL = URL(string: "https://steamcommunity.com/dev/apiterms")!
    /// Why some accounts are blocked from the key form.
    static let limitedAccountURL = URL(string: "https://help.steampowered.com/en/faqs/view/71D3-35C2-AD96-AA3A")!
    /// The required 2FA on the Steam account.
    static let steamGuardURL = URL(string: "https://help.steampowered.com/en/wizard/HelpWithSteamGuardCode")!

    static let prerequisitesLine = String(
        localized: "Prerequisites: a Steam account with Mobile Steam Guard and at least $5 of Steam Store spend (non-limited).",
        comment: "Reminder shown above the API-key entry field. Explains Valve's eligibility gate."
    )
    static let forgetTooltip = String(
        localized: "Removes the stored key from this Mac's Keychain. Your key remains active under your Steam account at steamcommunity.com/dev/apikey until you revoke it there.",
        comment: "Tooltip on the Forget button in WorkshopSettingsView."
    )
    static let passwordReassurance = String(
        localized: "Loomscreen never reads your Steam password — only this key, stored locally on this Mac.",
        comment: "Secondary reassurance under the API-key-required state and entry sheet."
    )
}
#endif
