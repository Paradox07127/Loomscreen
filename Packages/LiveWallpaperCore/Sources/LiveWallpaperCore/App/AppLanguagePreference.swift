import Foundation
import SwiftUI

public enum AppLanguagePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"

    public static let storageKey = "AppLanguage.Preference"

    public var id: String { rawValue }

    public var localeIdentifier: String? {
        switch self {
        case .system:
            return nil
        case .english, .simplifiedChinese, .traditionalChinese, .japanese:
            return rawValue
        }
    }

    public var locale: Locale {
        localeIdentifier.map(Locale.init(identifier:)) ?? .autoupdatingCurrent
    }

    public var titleKey: LocalizedStringKey {
        switch self {
        case .system:
            return "Follow System"
        case .english:
            return "English"
        case .simplifiedChinese:
            return "Simplified Chinese"
        case .traditionalChinese:
            return "Traditional Chinese"
        case .japanese:
            return "Japanese"
        }
    }

    public static var current: AppLanguagePreference {
        guard let rawValue = UserDefaults.standard.string(forKey: storageKey) else {
            return .system
        }
        return AppLanguagePreference(rawValue: rawValue) ?? .system
    }

    public static func save(_ preference: AppLanguagePreference) {
        if preference == .system {
            UserDefaults.standard.removeObject(forKey: storageKey)
        } else {
            UserDefaults.standard.set(preference.rawValue, forKey: storageKey)
        }
    }
}

public struct AppLanguageScope<Content: View>: View {
    @AppStorage(AppLanguagePreference.storageKey) private var rawPreference = AppLanguagePreference.system.rawValue

    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content.environment(\.locale, preference.locale)
    }

    private var preference: AppLanguagePreference {
        AppLanguagePreference(rawValue: rawPreference) ?? .system
    }
}

extension View {
    public func appLanguageScoped() -> some View {
        AppLanguageScope {
            self
        }
    }
}
