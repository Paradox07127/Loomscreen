import SwiftUI

struct FrameRateControlView: View {
    @ObservedObject var screen: Screen
    @EnvironmentObject private var screenManager: ScreenManager
    
    @State private var selectedLimit: FrameRateLimit
    @State private var screenRefreshRate: Int = 60
    
    init(screen: Screen) {
        self.screen = screen
        
        // Initialize with default value - will be updated in onAppear
        _selectedLimit = State(initialValue: .fps60)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            Label("Frame Rate Control", systemImage: "gauge.high")
                .font(.headline)
                .padding(.bottom, 8)
            
            // Information section
            if let videoPlayer = screen.videoPlayer, videoPlayer.videoFrameRate > 0 {
                HStack(spacing: 20) {
                    HStack {
                        Image(systemName: "film")
                        Text("Video: \(Int(videoPlayer.videoFrameRate)) FPS")
                    }
                    .foregroundColor(.secondary)
                    
                    HStack {
                        Image(systemName: "display")
                        Text("Screen: \(screenRefreshRate) Hz")
                    }
                    .foregroundColor(.secondary)
                }
                .padding(.bottom, 4)
                
                // Show effective frame rate after limiting
                if let effectiveRate = getEffectiveRate() {
                    HStack {
                        Image(systemName: "speedometer")
                            .foregroundColor(.blue)
                        Text("Effective rate: \(effectiveRate)")
                            .foregroundColor(.primary)
                    }
                    .padding(.bottom, 8)
                }
            }
            
            // Control options
            Text("Select frame rate limit:")
                .font(.subheadline)
            
            HStack(spacing: 12) {
                ForEach(FrameRateLimit.allCases) { option in
                    Button(action: {
                        selectedLimit = option
                        screenManager.updateFrameRateLimit(option, for: screen)
                    }) {
                        VStack(spacing: 6) {
                            Image(systemName: option.iconName)
                                .font(.system(size: 20))
                                .foregroundColor(selectedLimit == option ? .blue : .gray)
                                .frame(width: 36, height: 36)
                                .background(
                                    Circle()
                                        .fill(selectedLimit == option ? Color.blue.opacity(0.1) : Color.clear)
                                )
                            
                            Text(option.description)
                                .font(.callout)
                        }
                        .frame(width: 80, height: 80)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedLimit == option ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selectedLimit == option ? Color.blue : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.vertical, 4)
            
            // Simple explanation
            Text("Lower frame rates use less system resources but may appear less smooth.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
        .padding()
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
