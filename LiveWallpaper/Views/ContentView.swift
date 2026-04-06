import SwiftUI
import AppKit

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
                    Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(isRefreshing ? .degrees(360) : .degrees(0))
                        .animation(isRefreshing ? Animation.linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
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
                    }
                }
            }
            
            Section(header: VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text("Dashboard").font(.caption).bold().foregroundStyle(.secondary)
            }) {
                SystemMonitorView()
                    .padding(.vertical, 4)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
    }
    
    private func refreshDisplays() {
        withAnimation {
            isRefreshing = true
        }
        
        screenManager.refreshScreens()
        
        // Reset the animation after a delay
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation {
                isRefreshing = false
            }
        }
    }
}

// MARK: - Screen Row
struct ScreenRow: View {
    var screen: Screen
    @State private var isPlaying: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: screen.videoPlayer != nil ? "display.and.arrow.down" : "display")
                .foregroundStyle(screen.videoPlayer != nil ? Color.accentColor : Color.secondary)
                .frame(width: 32, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(screen.name)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("\(Int(screen.frame.width))×\(Int(screen.frame.height))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if screen.videoPlayer != nil {
                        HStack(spacing: 2) {
                            Circle()
                                .fill(isPlaying ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)

                            Text(isPlaying ? "Playing" : "Paused")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            updatePlaybackState()
        }
        .onReceive(NotificationCenter.default.publisher(for: WallpaperVideoPlayer.didChangePlaybackStateNotification)) { notification in
            guard let videoPlayer = notification.object as? WallpaperVideoPlayer,
                  videoPlayer === screen.videoPlayer else {
                return
            }
            if let playing = notification.userInfo?["isPlaying"] as? Bool {
                isPlaying = playing
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(screen.name), \(Int(screen.frame.width)) by \(Int(screen.frame.height)) pixels")
        .accessibilityValue(screen.videoPlayer != nil ? (isPlaying ? "Playing video" : "Video paused") : "No video configured")
        .accessibilityHint("Double-tap to configure this display")
    }

    private func updatePlaybackState() {
        isPlaying = screen.videoPlayer?.isPlaying ?? false
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
        .animation(.easeInOut, value: selection)
    }
}

// MARK: - Empty State View
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary.opacity(0.7))
                .frame(width: 80, height: 80)
                .glassEffect(.regular, in: .circle)

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
