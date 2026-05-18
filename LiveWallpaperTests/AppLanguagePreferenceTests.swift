import Foundation
import Testing
@testable import LiveWallpaper

@Suite("App language preference", .serialized) @MainActor
struct AppLanguagePreferenceTests {
    @Test("Language choices include system, English, Chinese, and Japanese")
    func languageChoicesExposeSupportedLocales() {
        #expect(AppLanguagePreference.allCases == [.system, .english, .simplifiedChinese, .traditionalChinese, .japanese])
        #expect(AppLanguagePreference.system.localeIdentifier == nil)
        #expect(AppLanguagePreference.english.localeIdentifier == "en")
        #expect(AppLanguagePreference.simplifiedChinese.localeIdentifier == "zh-Hans")
        #expect(AppLanguagePreference.traditionalChinese.localeIdentifier == "zh-Hant")
        #expect(AppLanguagePreference.japanese.localeIdentifier == "ja")
    }

    @Test("Saved language preference persists and reset returns to system")
    func savedPreferencePersistsUntilSettingsReset() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppLanguagePreference.storageKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppLanguagePreference.storageKey)
            } else {
                defaults.removeObject(forKey: AppLanguagePreference.storageKey)
            }
            SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)
        }

        defaults.removeObject(forKey: AppLanguagePreference.storageKey)
        #expect(AppLanguagePreference.current == .system)

        AppLanguagePreference.save(.simplifiedChinese)
        #expect(AppLanguagePreference.current == .simplifiedChinese)

        SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)
        #expect(AppLanguagePreference.current == .system)
    }
}
