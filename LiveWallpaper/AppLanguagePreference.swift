import Foundation
import SwiftUI

enum AppLanguagePreference: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let storageKey = "AppLanguage.Preference"

    var id: String { rawValue }

    var localeIdentifier: String? {
        switch self {
        case .system:
            return nil
        case .english, .simplifiedChinese:
            return rawValue
        }
    }

    var locale: Locale {
        localeIdentifier.map(Locale.init(identifier:)) ?? .autoupdatingCurrent
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .system:
            return "Follow System"
        case .english:
            return "English"
        case .simplifiedChinese:
            return "Simplified Chinese"
        }
    }

    static var current: AppLanguagePreference {
        guard let rawValue = UserDefaults.standard.string(forKey: storageKey) else {
            return .system
        }
        return AppLanguagePreference(rawValue: rawValue) ?? .system
    }

    static func save(_ preference: AppLanguagePreference) {
        if preference == .system {
            UserDefaults.standard.removeObject(forKey: storageKey)
        } else {
            UserDefaults.standard.set(preference.rawValue, forKey: storageKey)
        }
    }
}

struct AppLanguageScope<Content: View>: View {
    @AppStorage(AppLanguagePreference.storageKey) private var rawPreference = AppLanguagePreference.system.rawValue

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content.environment(\.locale, preference.locale)
    }

    private var preference: AppLanguagePreference {
        AppLanguagePreference(rawValue: rawPreference) ?? .system
    }
}

extension View {
    func appLanguageScoped() -> some View {
        AppLanguageScope {
            self
        }
    }
}
