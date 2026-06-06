import AppKit
import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI
import UniformTypeIdentifiers

/// Onboarding Step 2 — source chooser. Surfaces the two main wallpaper
/// sources (Video + Web/HTML). Shader and Wallpaper Engine are deliberately
/// not surfaced here: shader isn't the product's main story and WPE is held
/// back until the importer is more reliable. The picker is SKU-agnostic
/// today; SKU-conditional UI can be re-introduced via `OnboardingPathPolicy`
/// when those features are ready to promote.
struct OnboardingPickerView: View {
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var selectedScreenIDs: Set<CGDirectDisplayID>

    let galleryActions: [OnboardingSourceAction]
    let nextStep: () -> Void
    let skip: () -> Void

    @State private var stage: Stage = .gallery
    @State private var showHTMLSheet = false
    @State private var inlineError: LocalizedStringKey?

    private enum Stage: Equatable {
        case gallery
        case confirm(SourceDraft)
    }

    enum SourceDraft: Equatable {
        case video(URL, Data)
        case html(HTMLSource)
    }

    var body: some View {
        VStack(spacing: 18) {
            header

            Group {
                switch stage {
                case .gallery:
                    galleryContent
                case .confirm(let draft):
                    confirmContent(for: draft)
                }
            }
            .transition(stageTransition)

            Spacer(minLength: 0)

            if let inlineError {
                inlineErrorBanner(inlineError)
            }

            skipFooter
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 20)
        .onAppear(perform: seedSelectionIfNeeded)
        .sheet(isPresented: $showHTMLSheet) {
            HTMLPickerSheet(
                onCancel: { showHTMLSheet = false },
                onConfirm: { source in
                    showHTMLSheet = false
                    enterConfirm(.html(source))
                }
            )
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(spacing: 4) {
            Text(headerTitle)
                .font(DesignTokens.Typography.pageTitle)
                .accessibilityAddTraits(.isHeader)

            Text(headerSubtitle)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }

    private var headerTitle: LocalizedStringKey {
        switch stage {
        case .gallery: return "Pick Your First Wallpaper"
        case .confirm: return "Confirm and Apply"
        }
    }

    private var headerSubtitle: LocalizedStringKey {
        switch stage {
        case .gallery: return "Choose how to bring your desktop to life."
        case .confirm: return "Apply this wallpaper to your selected displays."
        }
    }

    private var galleryContent: some View {
        VStack(spacing: 12) {
            ForEach(galleryActions.indices, id: \.self) { idx in
                galleryRow(for: galleryActions[idx])
            }
        }
    }

    @ViewBuilder
    private func galleryRow(for action: OnboardingSourceAction) -> some View {
        switch action {
        case .video:
            ActionRowCard(
                icon: "film",
                tint: .blue,
                title: "Use a Video",
                subtitle: "MP4 or MOV from your Mac",
                action: pickVideoFile
            )
        case .html:
            ActionRowCard(
                icon: "globe",
                tint: .green,
                title: "Use Web or HTML",
                subtitle: "Website, .html file, or folder of assets",
                action: { showHTMLSheet = true }
            )
        }
    }

    private func confirmContent(for draft: SourceDraft) -> some View {
        VStack(spacing: 14) {
            sourceSummary(for: draft)
            OnboardingDisplayPillRow(
                screens: screenManager.screens,
                selectedScreenIDs: $selectedScreenIDs
            )
            VStack(spacing: 8) {
                Button {
                    apply(draft)
                } label: {
                    Text("Apply as Wallpaper", comment: "Primary CTA in the onboarding picker.")
                        .frame(minWidth: 160)
                }
                .adaptiveGlassButton(.prominent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)

                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        stage = .gallery
                    }
                } label: {
                    Text("Pick Different Source", comment: "Secondary onboarding action that returns to the gallery.")
                        .font(DesignTokens.Typography.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func sourceSummary(for draft: SourceDraft) -> some View {
        HStack(spacing: 12) {
            Image(systemName: draft.symbolName)
                .font(.system(size: 24))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(draft.headlineKey)
                    .font(DesignTokens.Typography.sectionTitle)
                Text(verbatim: draft.detail)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .adaptiveGlassSurface(.roundedRectangle(12))
        .frame(maxWidth: 440)
    }

    @ViewBuilder
    private var skipFooter: some View {
        if case .gallery = stage {
            Button(action: skip) {
                Text("Skip for Now", comment: "Secondary onboarding action that defers wallpaper setup.")
                    .font(DesignTokens.Typography.body)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func inlineErrorBanner(_ message: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }

    private var stageTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    // MARK: - Actions

    private func seedSelectionIfNeeded() {
        if selectedScreenIDs.isEmpty {
            selectedScreenIDs = Set(screenManager.screens.map(\.id))
        }
    }

    private func enterConfirm(_ draft: SourceDraft) {
        inlineError = nil
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            stage = .confirm(draft)
        }
    }

    private func pickVideoFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ResourceUtilities.supportedVideoContentTypes
        panel.prompt = L10n.Panel.preview

        let response = panel.runModal()
        guard response == .OK, let url = panel.url,
              let bookmark = ResourceUtilities.createVideoBookmark(for: url) else { return }
        SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
        enterConfirm(.video(url, bookmark))
    }

    private func apply(_ draft: SourceDraft) {
        let targets = screenManager.screens.filter { selectedScreenIDs.contains($0.id) }
        guard !targets.isEmpty else {
            withAnimation(.easeOut(duration: 0.18)) {
                inlineError = "Choose at least one display."
            }
            return
        }
        inlineError = nil
        switch draft {
        case .video(let url, let bookmark):
            for screen in targets {
                screenManager.setVideo(url: url, bookmarkData: bookmark, for: screen)
            }
        case .html(let source):
            for screen in targets {
                screenManager.setHTMLWallpaperPreservingConfig(source: source, for: screen)
            }
        }
        nextStep()
    }
}

private extension OnboardingPickerView.SourceDraft {
    var symbolName: String {
        switch self {
        case .video: return "film"
        case .html: return "globe"
        }
    }

    var headlineKey: LocalizedStringKey {
        switch self {
        case .video: return "Video selected"
        case .html: return "Web page selected"
        }
    }

    var detail: String {
        switch self {
        case .video(let url, _):
            return url.lastPathComponent
        case .html(let source):
            return source.summaryDescription
        }
    }
}

private extension HTMLSource {
    /// Best-effort one-liner for the confirm summary card.
    var summaryDescription: String {
        switch self {
        case .url(let url):
            return url.host ?? url.absoluteString
        case .folder(_, let indexFileName):
            return indexFileName
        case .file, .inline:
            return String(
                localized: "Local HTML file",
                defaultValue: "Local HTML file",
                comment: "Onboarding confirm-stage description fallback for an HTML file source."
            )
        }
    }
}

/// Horizontal row card — icon left, text right. Bigger tap target than a
/// grid cell because there are only 2 of these and we want to fill the
/// onboarding window's width naturally.
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
                    .fill(.regularMaterial)
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
