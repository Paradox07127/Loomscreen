import Foundation

public enum LoginItemFailure: Sendable {
    case registrationFailed(Error)
    case requiresApproval
    case registrationSilentlyFailed

    public var userFacingMessage: String {
        switch self {
        case .requiresApproval:
            return String(localized: "Open System Settings → General → Login Items and turn on Loomscreen.")
        case .registrationSilentlyFailed:
            return String(localized: "Couldn't add to Login Items. Move Loomscreen to the /Applications folder, then try again.")
        case .registrationFailed(let error):
            return String(localized: "Login Items registration failed: \(error.localizedDescription)")
        }
    }
}
