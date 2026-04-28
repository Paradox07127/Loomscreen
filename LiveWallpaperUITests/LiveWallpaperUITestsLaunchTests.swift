//
//  LiveWallpaperUITestsLaunchTests.swift
//  LiveWallpaperUITests
//
//  Created by Taijia Liang on 2/21/25.
//

import XCTest
import AppKit

final class LiveWallpaperUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        terminateRunningTargetApplications()

        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launchEnvironment["LIVEWALLPAPER_UI_TESTING"] = "1"
        app.launch()

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func terminateRunningTargetApplications() {
        let bundleIdentifier = "Taijia.LiveWallpaper"
        let deadline = Date().addingTimeInterval(3)
        var runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)

        for app in runningApps {
            app.terminate()
        }

        while Date() < deadline {
            runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            if runningApps.isEmpty {
                return
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        for app in runningApps {
            app.forceTerminate()
        }
    }
}
