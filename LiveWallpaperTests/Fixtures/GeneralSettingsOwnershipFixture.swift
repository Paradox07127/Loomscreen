import LiveWallpaperCore

/// Test-only decomposition map for UI-08. It names candidate ownership
/// boundaries without introducing production abstractions before behavior is
/// locked. Moving a field between domains is an explicit fixture review.
enum OwnershipFixture {
    enum Domain: String, CaseIterable {
        case behavior
        case performance
        case audio
        case weather
        case backupRestore
        case diagnostics
    }

    enum Page: String, CaseIterable {
        case general
        case performancePower
        case audioResponse
        case weather
        case backupRestore
        case advanced
        case about
    }

    static let fieldsByDomain: [Domain: Set<String>] = [
        .behavior: [
            "appLanguageRawValue",
            "startOnLogin",
            "loginItemStatus",
            "loginItemStatusRefreshPending",
            "loginItemStatusRefreshGeneration",
            "preservePlaybackOnLock",
            "showInDock",
            "loginItemAlert",
        ],
        .performance: [
            "globalPauseOnBattery",
            "pauseOnFullScreen",
            "pauseInGameMode",
            "pauseOnWindowOcclusion",
            "applicationRules",
            "showAppExceptions",
            "videoCacheBudgetMB",
            "adaptiveFrameRateEnabled",
            "offMainRenderEnabled",
        ],
        .audio: [
            "audioResponseEnabled",
            "audioCaptureState",
            "audioStatusRefreshPending",
            "audioStatusRefreshGeneration",
        ],
        .weather: [
            "weatherLocation",
            "locationAuthorizationStatus",
            "weatherStatusRefreshPending",
            "weatherStatusRefreshGeneration",
        ],
        .backupRestore: [
            "pendingImportBundle",
            "pendingImportSource",
            "importFeedback",
            "importErrorMessage",
            "exportErrorMessage",
            "isPresentingExporter",
            "isPresentingImporter",
            "exportDocument",
        ],
        .diagnostics: [
            "developerModeEnabled",
            "pendingBugReport",
            "diagnosticsExportErrorMessage",
            "isPresentingDiagnosticsExporter",
            "diagnosticsDocument",
        ],
    ]

    static func mountCalls(for page: Page, sku: ProductSKU) -> MountCalls {
        let statusReads: MountCalls
        switch page {
        case .general:
            statusReads = MountCalls(settingsReads: 0, loginStatusReads: 2, audioStateReads: 0, locationStatusReads: 0)
        case .audioResponse:
            let audioStateReads: Int
            switch sku {
            case .pro:
                audioStateReads = 2
            case .lite, .unconfigured:
                audioStateReads = 0
            }
            statusReads = MountCalls(
                settingsReads: 0,
                loginStatusReads: 0,
                audioStateReads: audioStateReads,
                locationStatusReads: 0
            )
        case .weather:
            statusReads = MountCalls(settingsReads: 0, loginStatusReads: 0, audioStateReads: 0, locationStatusReads: 2)
        case .performancePower, .backupRestore, .advanced, .about:
            statusReads = MountCalls(settingsReads: 0, loginStatusReads: 0, audioStateReads: 0, locationStatusReads: 0)
        }

        return MountCalls(
            settingsReads: 1,
            loginStatusReads: statusReads.loginStatusReads,
            audioStateReads: statusReads.audioStateReads,
            locationStatusReads: statusReads.locationStatusReads
        )
    }
}

struct MountCalls: Equatable {
    let settingsReads: Int
    let loginStatusReads: Int
    let audioStateReads: Int
    let locationStatusReads: Int
}
