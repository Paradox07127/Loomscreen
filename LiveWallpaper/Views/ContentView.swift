import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ScreenManager.self) private var screenManager
    @State private var selectedNavigation: Navigation?

    init(initialNavigation: Navigation? = nil) {
        _selectedNavigation = State(initialValue: initialNavigation)
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selectedNavigation)
                .onReceive(NotificationCenter.default.publisher(for: .selectScreenInSettings)) { notification in
                    guard let screenID = notification.userInfo?["screenID"] as? CGDirectDisplayID else { return }
                    selectedNavigation = .screen(screenID)
                }
        } detail: {
            DetailContent(selection: $selectedNavigation)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button(action: {
                            selectedNavigation = .general
                        }) {
                            Image(systemName: "gearshape")
                        }
                        .help("Preferences")
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1000, minHeight: 650)
    }
}

// MARK: - Navigation

enum Navigation: Hashable {
    case general
    case screen(CGDirectDisplayID)
}

// MARK: - Sidebar View
struct Sidebar: View {
    @Binding var selection: Navigation?
    @Environment(ScreenManager.self) private var screenManager
    @State private var isRefreshing = false
    
    var body: some View {
        List(selection: $selection) {
            Section(header: HStack(spacing: 4) {
                Text("Displays").font(.caption).bold().foregroundStyle(.secondary)
                Button(action: refreshDisplays) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isRefreshing)
                }
                .buttonStyle(.plain)
                .help("Refresh display list")
            }) {
                if screenManager.screens.isEmpty {
                    HStack {
                        Image(systemName: "display.slash")
                            .foregroundStyle(.secondary)
                        Text("No displays detected")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                } else {
                    ForEach(screenManager.screens, id: \.id) { screen in
                        NavigationLink(value: Navigation.screen(screen.id)) {
                            ScreenRow(screen: screen)
                        }
                        .dropDestination(for: URL.self) { urls, _ in
                            return handleVideoDrop(urls: urls, for: screen)
                        }
                    }
                }
            }
            
            Section(header: VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text("Dashboard").font(.caption).bold().foregroundStyle(.secondary)
            }) {
                SystemMonitorView()
                    .padding(.vertical, 2)
                    // 显式 listRowInsets 让仪表盘 row 的左右内边距与 sidebar
                    // 视觉边界对齐；不依赖 List 默认 inset（macOS 26 下会随
                    // sidebar 宽度动态变化，导致拉伸时内容相对漂移）。
                    // 收紧到 4pt 横向，让 dashboard 卡片更贴近 sidebar 边缘。
                    .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        // 默认与最小宽度同步为 200pt，sidebar 打开就是最紧凑形态；用户仍可拖宽到 280。
        .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 280)
    }
    
    private func refreshDisplays() {
        withAnimation(.snappy(duration: 0.2)) {
            isRefreshing = true
        }

        // 用 hardRefresh：重读 NSScreen + 释放并按配置重建所有 runtime session。
        // 解决"改分辨率后 sidebar 显示器变灰、视频消失"的恢复路径。
        screenManager.hardRefresh()

        Task {
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(.snappy(duration: 0.2)) {
                isRefreshing = false
            }
        }
    }

    private func handleVideoDrop(urls: [URL], for screen: Screen) -> Bool {
        guard let videoURL = urls.first else { return false }
        guard let bookmarkData = ResourceUtilities.createBookmark(for: videoURL) else {
            return false
        }
        screenManager.setVideo(url: videoURL, bookmarkData: bookmarkData, for: screen)
        return true
    }
}

// MARK: - Screen Row
struct ScreenRow: View {
    var screen: Screen
    @Environment(ScreenManager.self) private var screenManager

    /// 缓存 effect badge 状态。直接在 body 里读 config 不会响应
    /// `.wallpaperConfigurationDidChange` 通知（@Observable screens
    /// 数组本身没变），需要自管 state 订阅通知。
    @State private var hasEffectBadge: Bool = false

    private var sessionSummary: WallpaperSessionSummary {
        screen.wallpaperSessionSummary
    }

    var body: some View {
        let summary = sessionSummary

        HStack(spacing: 4) {
            Image(systemName: iconName(for: summary))
                .foregroundStyle(iconColor(for: summary))
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(screen.name)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("\(Int(screen.frame.width))×\(Int(screen.frame.height))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if summary.isConfigured {
                        HStack(spacing: 2) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(statusColor(for: summary))
                                .symbolEffect(.pulse, options: .repeat(.continuous), isActive: summary.activity == .active)

                            Text(statusText(for: summary))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if hasEffectBadge {
                            Image(systemName: "sparkles")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .onAppear { refreshEffectBadge() }
        .onChange(of: screen.id) { refreshEffectBadge() }
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperConfigurationDidChange)) { notification in
            if let changedID = notification.userInfo?["screenID"] as? CGDirectDisplayID,
               changedID == screen.id {
                withAnimation(.snappy(duration: 0.2)) { refreshEffectBadge() }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(screen.name), \(Int(screen.frame.width)) by \(Int(screen.frame.height)) pixels")
        .accessibilityValue(accessibilityValue(for: summary))
        .accessibilityHint("Double-tap to configure this display")
    }

    private func refreshEffectBadge() {
        guard let config = screenManager.getConfiguration(for: screen) else {
            hasEffectBadge = false
            return
        }
        hasEffectBadge = config.effectConfig.hasActiveEffect || config.particleEffect != .none
    }

    private func iconName(for summary: WallpaperSessionSummary) -> String {
        switch summary.wallpaperType {
        case .video:
            return summary.isConfigured ? "display.and.arrow.down" : "display"
        case .html:
            return "globe"
        case .metalShader:
            return "sparkles.rectangle.stack"
        case nil:
            return "display"
        }
    }

    private func iconColor(for summary: WallpaperSessionSummary) -> Color {
        summary.isConfigured ? Color.accentColor : Color.secondary
    }

    private func statusColor(for summary: WallpaperSessionSummary) -> Color {
        switch summary.activity {
        case .active:
            return .green
        case .paused:
            return .orange
        case .inactive:
            return .secondary
        }
    }

    private func statusText(for summary: WallpaperSessionSummary) -> String {
        switch summary.wallpaperType {
        case .html:
            return "HTML"
        case .metalShader:
            return "Shader"
        case .video:
            return summary.activity == .active ? "Playing" : "Paused"
        case nil:
            return "Not configured"
        }
    }

    private func accessibilityValue(for summary: WallpaperSessionSummary) -> String {
        switch summary.wallpaperType {
        case .html:
            return "HTML wallpaper active"
        case .metalShader:
            return "Shader wallpaper active"
        case .video:
            return summary.activity == .active ? "Playing video" : "Video paused"
        case nil:
            return "No wallpaper configured"
        }
    }
}

// MARK: - Detail Content
struct DetailContent: View {
    @Binding var selection: Navigation?
    @Environment(ScreenManager.self) private var screenManager

    var body: some View {
        Group {
            switch selection {
            case .general:
                GeneralSettingsView()
                    .transition(.opacity)
                
            case .screen(let screenId):
                if let screen = screenManager.screens.first(where: { $0.id == screenId }) {
                    ScreenDetailView(screen: screen)
                        .transition(.opacity)
                } else {
                    EmptyStateView(
                        icon: "display.trianglebadge.exclamationmark",
                        title: "Display Not Found",
                        message: "The selected display is no longer available."
                    )
                }
                
            case .none:
                EmptyStateView(
                    icon: "arrow.left.circle",
                    title: "Select a Display",
                    message: "Choose a display from the sidebar to configure your live wallpaper."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.underPageBackgroundColor))
        .animation(.snappy(duration: 0.3), value: selection)
    }
}

// MARK: - Empty State View
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .frame(width: 80, height: 80)
                    .glassEffect(.regular, in: .circle)
                    .contentTransition(.symbolEffect(.replace))

                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            .padding(32)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
