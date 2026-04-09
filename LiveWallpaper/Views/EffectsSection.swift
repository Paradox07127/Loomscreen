import SwiftUI

struct EffectsSection: View {
    var screen: Screen
    @Binding var effectConfig: VideoEffectConfig
    @Binding var selectedParticleEffect: ParticleEffect
    @Binding var setAsLockScreen: Bool
    @Environment(ScreenManager.self) private var screenManager
    
    @State private var isAdvancedColorEnabled = false

    var body: some View {
        VStack(spacing: 16) {
            // Core Effects
            GroupBox {
                VStack(spacing: 8) {
                    SettingRow(icon: "sparkles", iconColor: .purple, title: "Particle Overlay") {
                        Picker("", selection: $selectedParticleEffect) {
                            ForEach(ParticleEffect.allCases) { effect in
                                Text(effect.rawValue).tag(effect)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        .onChange(of: selectedParticleEffect) { _, newValue in
                            screenManager.updateParticleEffect(newValue, for: screen)
                        }
                    }
                    
                    Divider()
                    
                    SettingRow(icon: "lock.display", iconColor: .blue, title: "Lock Screen Wallpaper") {
                        Toggle("", isOn: $setAsLockScreen)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: setAsLockScreen) { _, newValue in
                                if newValue { screenManager.extractLockScreenFrame(for: screen) }
                            }
                    }
                }
                .padding(8)
            }
            
            // Advanced Color
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    SettingRow(icon: "slider.horizontal.3", iconColor: .orange, title: "Advanced Color Grading") {
                        Toggle("", isOn: $isAdvancedColorEnabled.animation(.spring(response: 0.3, dampingFraction: 0.8)))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    
                    if isAdvancedColorEnabled {
                        Divider().padding(.vertical, 4)
                        
                        VStack(spacing: 16) {
                            effectSlider(title: "Blur", value: $effectConfig.blurRadius, in: 0...30, format: "%.0f")
                            effectSlider(title: "Brightness", value: $effectConfig.brightness, in: -0.5...0.5, format: "%.2f")
                            effectSlider(title: "Saturation", value: $effectConfig.saturation, in: 0...2, format: "%.1f")
                            effectSlider(title: "Warmth", value: $effectConfig.warmth, in: 2500...8000, format: "%.0f")
                            effectSlider(title: "Vignette", value: $effectConfig.vignetteIntensity, in: 0...5, format: "%.1f")
                            
                            HStack {
                                Text("Auto warm tint by time of day")
                                    .font(.system(size: 12))
                                Spacer()
                                Toggle("", isOn: $effectConfig.autoTimeTint)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }
                            
                            HStack {
                                Text("Glass rain drops (Heavy GPU)")
                                    .font(.system(size: 12))
                                Spacer()
                                Toggle("", isOn: $effectConfig.glassRainEffect)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }
                        }
                        .padding(.bottom, 4)
                        .onChange(of: effectConfig) { _, _ in
                            screenManager.updateEffectConfig(effectConfig, for: screen)
                        }
                    }
                }
                .padding(8)
            }
        }
    }
    
    private func effectSlider(title: String, value: Binding<Double>, in range: ClosedRange<Double>, format: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .frame(width: 70, alignment: .leading)
            
            Slider(value: value, in: range)
                .controlSize(.small)
            
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 35, alignment: .trailing)
        }
    }
}
