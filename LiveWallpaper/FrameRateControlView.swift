import SwiftUI

struct FrameRateControlView: View {
    @ObservedObject var screen: Screen
    @EnvironmentObject private var screenManager: ScreenManager
    
    @State private var selectedLimit: FrameRateLimit
    @State private var screenRefreshRate: Int = 60
    
    init(screen: Screen) {
        self.screen = screen
        _selectedLimit = State(initialValue: .fps60)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header with effective rate
            HStack {
                Label("Frame Rate", systemImage: "gauge.high")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                if let effectiveRate = getEffectiveRate() {
                    HStack(spacing: 4) {
                        Text("Effective:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(effectiveRate)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                    }
                }
            }
            
            // Frame rate selection with compact buttons
            HStack(spacing: 8) {
                ForEach(FrameRateLimit.allCases) { option in
                    Button(action: {
                        selectedLimit = option
                        screenManager.updateFrameRateLimit(option, for: screen)
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: option.iconName)
                                .font(.system(size: 14))
                                .foregroundStyle(selectedLimit == option ? Color.accentColor : Color.gray)
                            Text(option.description)
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(selectedLimit == option ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(selectedLimit == option ? Color.accentColor : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Source info
            if let videoPlayer = screen.videoPlayer, videoPlayer.videoFrameRate > 0 {
                HStack(spacing: 10) {
                    Text("Video: \(Int(videoPlayer.videoFrameRate)) FPS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text("Screen: \(screenRefreshRate) Hz")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            // Get screen refresh rate
            screenRefreshRate = screenManager.getScreenRefreshRate(for: screen.id)
            
            // Load current frame rate limit setting
            if let config = screenManager.getConfiguration(for: screen) {
                selectedLimit = config.frameRateLimit
            }
        }
    }
    
    // Get the effective frame rate after limiting
    private func getEffectiveRate() -> String? {
        guard let videoPlayer = screen.videoPlayer, videoPlayer.videoFrameRate > 0 else {
            return nil
        }
        
        let limit = selectedLimit.getEffectiveLimit(
            videoFrameRate: videoPlayer.videoFrameRate,
            screenRefreshRate: Double(screenRefreshRate)
        )
        
        if limit <= 0 {
            // For unlimited or when no limiting is needed
            let effectiveRate = min(videoPlayer.videoFrameRate, Double(screenRefreshRate))
            return "\(Int(effectiveRate)) FPS"
        } else {
            return "\(Int(limit)) FPS"
        }
    }
}
// Preview provider
struct FrameRateControlView_Previews: PreviewProvider {
    static var previews: some View {
        let mockScreen = Screen(nsScreen: NSScreen.main!)
        let mockManager = ScreenManager()
        
        return FrameRateControlView(screen: mockScreen)
            .environmentObject(mockManager)
            .frame(width: 400)
            .padding()
    }
}
