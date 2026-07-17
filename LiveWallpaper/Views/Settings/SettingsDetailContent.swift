import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

struct SettingsDetailContent: View {
    @Binding var selection: SettingsNavigation?
    @Binding var pendingSearchAnchor: SettingsSearchAnchor?
    @Environment(\.featureCatalog) private var featureCatalog

    var body: some View {
        Group {
            switch selection ?? .general {
            case .general:
                GeneralSettingsView(page: .general)
            case .displayDefaults:
                DisplayDefaultsSettingsView(pendingSearchAnchor: $pendingSearchAnchor)
            case .performancePower:
                GeneralSettingsView(page: .performancePower)
            case .audioResponse:
                GeneralSettingsView(page: .audioResponse)
            case .weather:
                GeneralSettingsView(page: .weather)
            case .shortcuts:
                ShortcutsSettingsView(pendingSearchAnchor: $pendingSearchAnchor)
            case .storage:
                #if !LITE_BUILD
                if featureCatalog.isEnabled(.wpeImport) {
                    WPECacheManagementView(pendingSearchAnchor: $pendingSearchAnchor)
                } else {
                    GeneralSettingsView(page: .general)
                }
                #else
                GeneralSettingsView(page: .general)
                #endif
            case .backupRestore:
                GeneralSettingsView(page: .backupRestore)
            case .workshopSetup:
                #if !LITE_BUILD
                if featureCatalog.isEnabled(.workshopOnline) {
                    WorkshopSettingsView(pendingSearchAnchor: $pendingSearchAnchor)
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
