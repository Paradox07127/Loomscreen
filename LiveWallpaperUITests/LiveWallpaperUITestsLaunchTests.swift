import XCTest

final class LiveWallpaperUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launchArguments.append("--open-settings-for-ui-testing")
        app.launchEnvironment["LIVEWALLPAPER_UI_TESTING"] = "1"
        app.launchEnvironment["LIVEWALLPAPER_OPEN_SETTINGS"] = "1"
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }
}
