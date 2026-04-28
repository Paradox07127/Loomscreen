import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct OnboardingStepFirstWallpaper: View {
    let nextStep: () -> Void
    let skip: () -> Void

    @Environment(ScreenManager.self) private var screenManager
    @State private var isRequestingAerials = false
    @State private var showHTMLSheet = false
    @State private var htmlURLInput = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 32)

            VStack(spacing: 8) {
                Text("Pick Your First Wallpaper")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)

                Text("You can always add more later from the menu bar.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer().frame(height: 22)

            VStack(spacing: 10) {
                OnboardingOptionCard(
                    icon: "film",
                    iconTint: Color.accentColor,
                    title: "Choose Your Video",
                    subtitle: "Pick an MP4 or MOV from your Mac.",
                    isFeatured: true,
                    isLoading: false,
                    action: chooseVideoFile
                )
                .keyboardShortcut("1", modifiers: [])

                OnboardingOptionCard(
                    icon: "sparkles.tv",
                    iconTint: .secondary,
                    title: "Use Apple Aerials",
                    subtitle: "Browse Apple's downloaded aerial wallpapers.",
                    isFeatured: false,
                    isLoading: isRequestingAerials,
                    action: chooseAerials
                )
                .keyboardShortcut("2", modifiers: [])

                OnboardingOptionCard(
                    icon: "globe",
                    iconTint: .secondary,
                    title: "Add a Web Page",
                    subtitle: "Use a website or local HTML as a live wallpaper.",
                    isFeatured: false,
                    isLoading: false,
                    action: { showHTMLSheet = true }
                )
                .keyboardShortcut("3", modifiers: [])

                OnboardingOptionCard(
                    icon: "arrow.right.circle",
                    iconTint: .secondary,
                    title: "Skip for Now",
                    subtitle: "I'll set this up later from the settings.",
                    isFeatured: false,
                    isLoading: false,
                    action: skip
                )
                .keyboardShortcut("4", modifiers: [])
            }
            .padding(.horizontal, 36)

            Spacer()
        }
        .sheet(isPresented: $showHTMLSheet) {
            HTMLURLSheet(
                urlInput: $htmlURLInput,
                onCancel: { showHTMLSheet = false },
                onConfirm: { applyHTML($0) }
            )
        }
    }

    private func chooseAerials() {
        guard !isRequestingAerials else { return }
        isRequestingAerials = true
        Task {
            let granted = await AppleAerialsLibrary.shared.requestAccess()
            isRequestingAerials = false
            if granted {
                NotificationCenter.default.post(name: .openAppleAerials, object: nil)
            }
            nextStep()
        }
    }

    private func chooseVideoFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie, .avi]
        panel.prompt = "Use Wallpaper"

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        if let screen = screenManager.screens.first,
           let bookmark = ResourceUtilities.createBookmark(for: url) {
            screenManager.setVideo(url: url, bookmarkData: bookmark, for: screen)
            SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
        }
        nextStep()
    }

    private func applyHTML(_ rawInput: String) {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let normalized: String = {
            let lower = trimmed.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://") {
                return trimmed
            }
            return "https://" + trimmed
        }()

        if let screen = screenManager.screens.first {
            screenManager.setHTMLWallpaper(url: normalized, for: screen)
        }
        showHTMLSheet = false
        nextStep()
    }
}

private struct HTMLURLSheet: View {
    @Binding var urlInput: String
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Web Page Wallpaper")
                    .font(.system(size: 16, weight: .semibold))
                Text("Enter a URL — defaults to https:// when no scheme is given.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            TextField("example.com", text: $urlInput)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onSubmit { onConfirm(urlInput) }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Use as Wallpaper") { onConfirm(urlInput) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { isFieldFocused = true }
    }
}

private struct OnboardingOptionCard: View {
    let icon: String
    let iconTint: Color
    let title: String
    let subtitle: String
    let isFeatured: Bool
    let isLoading: Bool
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(iconTint)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if isFeatured {
                    Text("Recommended")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.regularMaterial)
            )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isHovering || isFocused ? 1.01 : 1.0)
        .shadow(color: .black.opacity(isHovering || isFocused ? 0.18 : (isFeatured ? 0.06 : 0)), radius: 8, y: 3)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isHovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isFocused)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}

extension Notification.Name {
    static let openAppleAerials = Notification.Name("OpenAppleAerials")
}
