import CoreGraphics
import Foundation
import LiveWallpaperCore

enum WeatherReactivePolicy {
    static func shouldMonitor(
        configurations: [ScreenConfiguration],
        activeScreenIDs: Set<CGDirectDisplayID>
    ) -> Bool {
        configurations.contains { configuration in
            activeScreenIDs.contains(configuration.screenID) && configuration.effectConfig.weatherReactive
        }
    }
}
