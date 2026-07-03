import SwiftUI

struct SettingsDetailContent: View {
    @Binding var selection: SettingsNavigation?
    @Environment(\.featureCatalog) private var featureCatalog

    var body: some View {
        Group {
            switch selection ?? .general {
            case .general:
                GeneralSettingsView(page: .general)
            case .displayDefaults:
                DisplayDefaultsSettingsView()
            case .performancePower:
                GeneralSettingsView(page: .performancePower)
            case .audioResponse:
                GeneralSettingsView(page: .audioResponse)
            case .weather:
                GeneralSettingsView(page: .weather)
            case .shortcuts:
                ShortcutsSettingsView()
            case .storage:
                #if !LITE_BUILD
                if featureCatalog.isEnabled(.wpeImport) {
                    WPECacheManagementView()
                } else {
                    GeneralSettingsView(page: .general)
                }
                #else
                GeneralSettingsView(page: .general)
                #endif
            case .backupRestore:
                GeneralSettingsView(page: .backupRestore)
            case .workshopSetup:
                #if !LITE_BUILD && DIRECT_DISTRIBUTION
                if featureCatalog.isEnabled(.workshopOnline) {
                    WorkshopSettingsView()
                } else {
                    GeneralSettingsView(page: .general)
                }
                #else
                GeneralSettingsView(page: .general)
                #endif
            case .advanced:
                GeneralSettingsView(page: .advanced)
            case .about:
                GeneralSettingsView(page: .about)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Colors.pageBackground)
    }
}
