import AppKit
import LiveWallpaperCore
import SwiftUI

enum OnboardingImportCopy {
    enum UnsupportedFileTypeVariant: Equatable {
        case videoAndWeb
        case videoWebAndScene
    }

    static func unsupportedFileTypeVariant(sceneCapable: Bool) -> UnsupportedFileTypeVariant {
        sceneCapable ? .videoWebAndScene : .videoAndWeb
    }

    /// Keep recovery copy and import routing on the same product capability.
    /// This small policy is intentionally testable without rendering the view.
    static func sceneCapable(in catalog: FeatureCatalog) -> Bool {
        catalog.isEnabled(.scene)
    }

    static func unsupportedFileTypeMessage(sceneCapable: Bool) -> LocalizedStringResource {
        switch unsupportedFileTypeVariant(sceneCapable: sceneCapable) {
        case .videoAndWeb:
            return "That file type isn't supported. Pick a video or web page."
        case .videoWebAndScene:
            return "That file type isn't supported. Pick a video, web page, or scene."
        }
    }
}

/// Onboarding source step. Two SKU-derived cards: a single "Import a file"
/// action that opens one picker and routes by type (video / web / — on Pro —
/// Wallpaper Engine scene), plus a second card that is either Steam Workshop
/// (direct Pro) or Apple Aerials. Files can also be dropped straight onto the
/// step. Applies to every display so the first wallpaper appears immediately.
struct OnboardingPickerView: View {
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog

    let galleryActions: [OnboardingSourceAction]
    let nextStep: () -> Void
    let skip: () -> Void
    let openAppleAerials: () -> Void

    @State private var inlineError: LocalizedStringResource?
    @State private var isDropTargeted = false

    private var sceneCapable: Bool {
        OnboardingImportCopy.sceneCapable(in: featureCatalog)
    }

    var body: some View {
        VStack(spacing: 18) {
            header

            VStack(spacing: 12) {
                ForEach(galleryActions.indices, id: \.self) { idx in
                    galleryRow(for: galleryActions[idx])
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                return handleImportedURL(url)
            } isTargeted: { isDropTargeted = $0 }

            Spacer(minLength: 0)

            if let inlineError {
                inlineErrorBanner(inlineError)
            }

            skipFooter
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 20)
        .overlay(dropHighlight)
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(spacing: 4) {
            Text("Pick Your First Wallpaper")
                .font(DesignTokens.Typography.pageTitle)
                .accessibilityAddTraits(.isHeader)
            Text("Choose how to bring your desktop to life.")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private func galleryRow(for action: OnboardingSourceAction) -> some View {
        switch action {
        case .importFile:
            ActionRowCard(
                icon: "square.and.arrow.down",
                tint: .blue,
                title: "Import a File",
                subtitle: sceneCapable
                    ? "Video, web page, or Wallpaper Engine scene"
                    : "Video or web page",
                action: openImportPanel
            )
        case .workshop:
            ActionRowCard(
                icon: "cube.transparent",
                tint: .purple,
                title: "Steam Workshop",
                subtitle: "Browse and download community scenes",
                action: nextStep
            )
        case .appleAerials:
            ActionRowCard(
                icon: "sparkles.tv",
                tint: .teal,
                title: "Apple Aerials",
                subtitle: "Apple TV's aerial screensavers",
                action: openAppleAerials
            )
        }
    }

    @ViewBuilder
    private var skipFooter: some View {
        Button(action: skip) {
            Text("Skip for Now", comment: "Secondary onboarding action that defers wallpaper setup.")
                .font(DesignTokens.Typography.body)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(isDropTargeted ? 0.6 : 0), lineWidth: 2)
            .padding(.horizontal, 24)
            .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
            .allowsHitTesting(false)
    }

    private func inlineErrorBanner(_ message: LocalizedStringResource) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(DesignTokens.Colors.Status.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(DesignTokens.Colors.Status.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }

    // MARK: - Import routing

    private func openImportPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = SettingsManager.shared.getLastUsedDirectory()
        panel.prompt = L10n.Panel.useAsWallpaper
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
        _ = handleImportedURL(url)
    }

    /// Routes one dropped/picked URL to the right wallpaper kind and applies it
    /// to all displays. Returns whether it was accepted.
    @discardableResult
    private func handleImportedURL(_ url: URL) -> Bool {
        clearError()

        if ResourceUtilities.isSupportedVideoURL(url) {
            guard let bookmark = ResourceUtilities.createVideoBookmark(for: url) else {
                return fail("Couldn't read that file. Try a different one.")
            }
            for screen in screenManager.screens {
                screenManager.setVideo(url: url, bookmarkData: bookmark, for: screen)
            }
            nextStep()
            return true
        }

        if isDirectoryURL(url) {
            if folderLooksLikeScene(url) {
                #if !LITE_BUILD
                if sceneCapable {
                    applyScene(url)
                    nextStep()
                    return true
                }
                #endif
                return fail("Wallpaper Engine scenes need the Pro edition.")
            }
            guard let bookmark = ResourceUtilities.createBookmark(for: url) else {
                return fail("Couldn't read that folder. Try a different one.")
            }
            let entries = scopedDirectoryEntries(url)
            let indexFileName = ResourceUtilities.inferHTMLIndexFileName(from: entries)
            applyHTML(.folder(bookmarkData: bookmark, indexFileName: indexFileName))
            nextStep()
            return true
        }

        if ResourceUtilities.isSupportedHTMLResourceURL(url),
           let source = ResourceUtilities.htmlSourceFromPickedFile(url) {
            applyHTML(source)
            nextStep()
            return true
        }

        return fail(OnboardingImportCopy.unsupportedFileTypeMessage(sceneCapable: sceneCapable))
    }

    private func applyHTML(_ source: HTMLSource) {
        for screen in screenManager.screens {
            screenManager.setHTMLWallpaperPreservingConfig(source: source, for: screen)
        }
    }

    #if !LITE_BUILD
    private func applyScene(_ folderURL: URL) {
        let targets = screenManager.screens
        let didStartScope = folderURL.startAccessingSecurityScopedResource()
        Task { @MainActor in
            defer { if didStartScope { folderURL.stopAccessingSecurityScopedResource() } }
            for screen in targets {
                await screenManager.importWallpaperEngineProject(at: folderURL, for: screen)
            }
        }
    }
    #endif

    // MARK: - Helpers

    private func isDirectoryURL(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// A folder with a `project.json` at its root is a Wallpaper Engine scene.
    private func folderLooksLikeScene(_ url: URL) -> Bool {
        scopedDirectoryEntries(url).contains { $0.lowercased() == "project.json" }
    }

    private func scopedDirectoryEntries(_ url: URL) -> [String] {
        let didStartScope = url.startAccessingSecurityScopedResource()
        defer { if didStartScope { url.stopAccessingSecurityScopedResource() } }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
    }

    @discardableResult
    private func fail(_ message: LocalizedStringResource) -> Bool {
        withAnimation(.easeOut(duration: 0.18)) { inlineError = message }
        return false
    }

    private func clearError() {
        if inlineError != nil { inlineError = nil }
    }
}

/// Row layout (not a grid) so the cards fill the onboarding window's width
/// with a bigger tap target.
private struct ActionRowCard: View {
    let icon: String
    let tint: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActive: Bool { isHovering || isFocused }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.16))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(tint)
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DesignTokens.Typography.sectionTitle)
                    Text(subtitle)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                    .fill(DesignTokens.Colors.surfaceRaised)
            )
            .galleryTileChrome(isHovering: isActive, reduceMotion: reduceMotion)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous))
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(subtitle))
    }
}
