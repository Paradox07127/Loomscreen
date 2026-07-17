import LiveWallpaperSharedUI
import SwiftUI

private struct HighlightedSettingsSearchAnchorKey: EnvironmentKey {
    static let defaultValue: SettingsSearchAnchor? = nil
}

extension EnvironmentValues {
    var highlightedSettingsSearchAnchor: SettingsSearchAnchor? {
        get { self[HighlightedSettingsSearchAnchorKey.self] }
        set { self[HighlightedSettingsSearchAnchorKey.self] = newValue }
    }
}

extension View {
    func settingsSearchAnchorScroller(
        pendingSearchAnchor: Binding<SettingsSearchAnchor?>,
        anchors handledAnchors: Set<SettingsSearchAnchor>
    ) -> some View {
        modifier(SettingsSearchAnchorScrollModifier(
            pendingSearchAnchor: pendingSearchAnchor,
            handledAnchors: handledAnchors
        ))
    }

    func settingsSearchAnchorTarget(
        _ anchor: SettingsSearchAnchor,
        cornerRadius: CGFloat = 8
    ) -> some View {
        modifier(SettingsSearchAnchorTargetModifier(anchor: anchor, cornerRadius: cornerRadius))
    }
}

struct SettingsSearchSectionHeader: View {
    private enum Title {
        case localized(String)
        case verbatim(String)
    }

    private let title: Title
    private let anchor: SettingsSearchAnchor

    @Environment(\.highlightedSettingsSearchAnchor) private var highlightedAnchor

    init(_ titleKey: String, anchor: SettingsSearchAnchor) {
        self.title = .localized(titleKey)
        self.anchor = anchor
    }

    init(verbatim title: String, anchor: SettingsSearchAnchor) {
        self.title = .verbatim(title)
        self.anchor = anchor
    }

    var body: some View {
        header
            .id(anchor)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(DesignTokens.Colors.accent.opacity(0.14))
                        .padding(.horizontal, -6)
                        .padding(.vertical, -3)
                }
            }
            .overlay {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DesignTokens.Colors.accent.opacity(0.28), lineWidth: 0.5)
                        .padding(.horizontal, -6)
                        .padding(.vertical, -3)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: isHighlighted)
    }

    private var isHighlighted: Bool {
        highlightedAnchor == anchor
    }

    @ViewBuilder
    private var header: some View {
        switch title {
        case .localized(let titleKey):
            Text(LocalizedStringKey(titleKey))
        case .verbatim(let title):
            Text(verbatim: title)
        }
    }
}

private struct SettingsSearchAnchorScrollModifier: ViewModifier {
    @Binding var pendingSearchAnchor: SettingsSearchAnchor?
    let handledAnchors: Set<SettingsSearchAnchor>

    @State private var highlightedAnchor: SettingsSearchAnchor?
    @State private var scrollTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .environment(\.highlightedSettingsSearchAnchor, highlightedAnchor)
                .onAppear {
                    scheduleScrollIfNeeded(with: proxy)
                }
                .onChange(of: pendingSearchAnchor) { _, _ in
                    scheduleScrollIfNeeded(with: proxy)
                }
                .onDisappear {
                    scrollTask?.cancel()
                }
        }
    }

    private func scheduleScrollIfNeeded(with proxy: ScrollViewProxy) {
        guard let anchor = pendingSearchAnchor, handledAnchors.contains(anchor) else { return }
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            scrollIfNeeded(with: proxy, expectedAnchor: anchor)
        }
    }

    private func scrollIfNeeded(with proxy: ScrollViewProxy, expectedAnchor: SettingsSearchAnchor) {
        guard let anchor = pendingSearchAnchor,
              anchor == expectedAnchor,
              handledAnchors.contains(anchor) else { return }

        if reduceMotion {
            proxy.scrollTo(anchor, anchor: .top)
            highlightedAnchor = anchor
        } else {
            withAnimation(.easeInOut(duration: 0.22)) {
                proxy.scrollTo(anchor, anchor: .top)
                highlightedAnchor = anchor
            }
        }

        pendingSearchAnchor = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1600))
            guard highlightedAnchor == anchor else { return }
            if reduceMotion {
                highlightedAnchor = nil
            } else {
                withAnimation(.easeInOut(duration: 0.18)) {
                    highlightedAnchor = nil
                }
            }
        }
    }
}

private struct SettingsSearchAnchorTargetModifier: ViewModifier {
    let anchor: SettingsSearchAnchor
    let cornerRadius: CGFloat

    @Environment(\.highlightedSettingsSearchAnchor) private var highlightedAnchor

    func body(content: Content) -> some View {
        content
            .id(anchor)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(DesignTokens.Colors.accent.opacity(0.08))
                }
            }
            .overlay {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(DesignTokens.Colors.accent.opacity(0.32), lineWidth: 1)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: isHighlighted)
    }

    private var isHighlighted: Bool {
        highlightedAnchor == anchor
    }
}
