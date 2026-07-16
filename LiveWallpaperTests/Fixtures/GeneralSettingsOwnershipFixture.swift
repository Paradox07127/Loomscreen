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

    static let pages = Page.allCases

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

    static let currentProMountCalls = MountCalls(
        settingsReads: 1,
        loginStatusReads: 2,
        audioStateReads: 2,
        locationStatusReads: 2
    )

    static func currentMountCalls(for _: Page, sku: ProductSKU) -> MountCalls {
        switch sku {
        case .pro:
            currentProMountCalls
        case .lite, .unconfigured:
            MountCalls(settingsReads: 1, loginStatusReads: 2, audioStateReads: 0, locationStatusReads: 2)
        }
    }
}

struct MountCalls: Equatable {
    let settingsReads: Int
    let loginStatusReads: Int
    let audioStateReads: Int
    let locationStatusReads: Int
}
