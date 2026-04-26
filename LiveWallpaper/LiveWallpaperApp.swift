import SwiftUI
import AppKit

/// 应用启动时的工作流：
/// 1. `applicationDidFinishLaunching` 在 NSApp 主循环就绪后构造 ScreenManager
///    （提早构造会触发 FullScreenDetector 中的 NSScreen/NSApp 调用断言崩溃）。
/// 2. `screenManager` 用 `@Observable` 暴露给 `LiveWallpaperApp.body`，从 nil
///    变为非 nil 时驱动 MenuBarExtra 内容重渲染。
/// 3. Settings 窗口由本类托管的 `NSWindowController` 直接打开，与旧实现一致，
///    避免 SwiftUI `Settings { ... }` scene 套用 macOS System Settings 风格。
@MainActor
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    var screenManager: ScreenManager?

    @ObservationIgnored private var settingsWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.notice("Application starting", category: .startup)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWakeNotification),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        let manager = ScreenManager()
        screenManager = manager
        manager.refreshScreens()

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            manager.reloadAllScreens()
        }

        NSApp.setActivationPolicy(.accessory)
        Logger.notice("Application startup complete", category: .startup)
    }

    @objc private func handleWakeNotification() {
        Logger.info("System wake detected", category: .lifecycle)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.screenManager?.refreshScreens()
            PowerMonitor.shared.refreshPowerStatus()
        }
    }

    nonisolated func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Settings Window

    /// 打开（或前置）Settings 窗口。`initialScreenID` 用于"从状态栏的某个
    /// 显示器子菜单点击后直接跳到该屏幕"。
    func showSettings(initialScreenID: CGDirectDisplayID? = nil) {
        guard let manager = screenManager else { return }

        if let controller = settingsWindowController {
            controller.showWindow(nil)
            if let id = initialScreenID {
                NotificationCenter.default.post(
                    name: .selectScreenInSettings,
                    object: nil,
                    userInfo: ["screenID": id]
                )
            }
            // 多屏 / 后台进程场景下仅 NSApp.activate() 不足以把窗口
            // 提到最前；显式 makeKey + orderFrontRegardless 才能保证
            // 用户能看到窗口。
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.window?.orderFrontRegardless()
            return
        }

        let initialNavigation: Navigation? = initialScreenID.map { .screen($0) }
        let contentView = ContentView(initialNavigation: initialNavigation)
            .environment(manager)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "LiveWallpaper Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
        window.center()
        window.contentView = NSHostingView(rootView: contentView)
        window.delegate = self
        window.setFrameAutosaveName("LiveWallpaperSettingsWindow")

        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        settingsWindowController = nil
    }
}

@main
struct LiveWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // MenuBarExtra 是 macOS 13+ 替代 NSStatusItem 的原生 SwiftUI 入口。
        // label 闭包负责状态栏图标，依赖 @Observable AppDelegate 自动刷新。
        MenuBarExtra {
            menuBarBody
        } label: {
            Image(systemName: menuBarIconName)
        }
        // .window 风格让我们在状态栏弹出自定义 SwiftUI panel：
        // 顶部 mini dashboard、每屏卡片、Quick Toggles、底部 Settings/Quit。
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var menuBarBody: some View {
        if let screenManager = appDelegate.screenManager {
            MenuBarContent(
                openSettings: { [appDelegate] in
                    appDelegate.showSettings()
                },
                openSettingsForScreen: { [appDelegate] id in
                    appDelegate.showSettings(initialScreenID: id)
                }
            )
            .environment(screenManager)
        } else {
            Text("Initializing…")
        }
    }

    /// 镜像旧版 `StatusBarController.determineStatusBarIcon` 的逻辑。
    private var menuBarIconName: String {
        guard let manager = appDelegate.screenManager else {
            return "photo.on.rectangle"
        }
        switch manager.wallpaperOverviewStatus {
        case .notConfigured:
            return "photo.on.rectangle"
        case .active:
            return manager.hasControllableWallpaperSessions
                ? "play.rectangle.fill"
                : "display.2"
        case .paused:
            return "pause.rectangle.fill"
        }
    }
}
