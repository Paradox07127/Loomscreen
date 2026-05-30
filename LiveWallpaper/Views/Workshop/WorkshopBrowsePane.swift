#if !LITE_BUILD && DIRECT_DISTRIBUTION
import LiveWallpaperSharedUI
import SwiftUI

/// The "Browse Online" tab content, carved out of `WorkshopBrowseView` so it
/// can be embedded headerless inside `WorkshopPaneView`. Owns the filter
/// ribbon, the skeleton / populated / empty / error states, the load-more
/// footer, the rate-limit countdown banner, and the per-item detail sheet.
struct WorkshopBrowsePane: View {
    let viewModel: WorkshopBrowseViewModel
    let doctor: SteamCMDDoctorService
    let onRequestKeyEntry: () -> Void

    @Environment(WorkshopServices.self) private var services
    @State private var selectedItem: WorkshopQueryItem?
    @State private var rateLimitRemaining: TimeInterval = 0
    /// Workshop ids already in the local library, for the "In Library" badge.
    @State private var installedWorkshopIDs: Set<String> = []

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Square tiles sized to the ~192px source thumbnails — large enough to read
    // the preview crisply without upscaling into blur, so the window width alone
    // drives how many fit per row (no manual density control).
    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 184, maximum: 220), spacing: DesignTokens.Spacing.lg)]
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkshopBrowseFilterRibbon(
                viewModel: viewModel,
                hasWebAPIKey: services.hasWebAPIKey,
                onRequestKeyEntry: onRequestKeyEntry
            )
            .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
            .padding(.vertical, DesignTokens.Spacing.sm)

            Divider()

            content
                .overlay(alignment: .top) { rateLimitBanner }
        }
        .background(DesignTokens.Colors.pageBackground)
        .onAppear {
            rateLimitRemaining = currentRateLimitRemaining
            reloadInstalledIDs()
            Task {
                await services.refreshAPIKeyStatus()
                // Only hit Steam once a key is present — avoids a phantom
                // request count + a `missingAPIKey` error on the empty state.
                if services.hasWebAPIKey { viewModel.onAppear() }
            }
        }
        .onChange(of: services.hasWebAPIKey) { _, hasKey in
            guard hasKey, viewModel.items.isEmpty, !viewModel.isLoading else { return }
            Task { await viewModel.reload() }
        }
        .onReceive(ticker) { _ in
            rateLimitRemaining = currentRateLimitRemaining
        }
        .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
            reloadInstalledIDs()
        }
        .onChange(of: viewModel.isLoading) { _, loading in
            if loading { WorkshopRequestCounter.increment() }
        }
        .onChange(of: viewModel.isLoadingMore) { _, loading in
            if loading { WorkshopRequestCounter.increment() }
        }
        .inspector(isPresented: Binding(
            get: { selectedItem != nil },
            set: { presented in if !presented { selectedItem = nil } }
        )) {
            Group {
                if let selectedItem {
                    WorkshopInspectorContent(item: selectedItem, doctor: doctor)
                } else {
                    inspectorPlaceholder
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !services.hasWebAPIKey {
            apiKeyRequiredState
        } else if let error = viewModel.lastError, viewModel.items.isEmpty, !viewModel.isRateLimited {
            errorState(error)
        } else if viewModel.items.isEmpty, viewModel.isLoading {
            loadingSkeleton
        } else if viewModel.items.isEmpty {
            emptyState
        } else {
            populatedGrid
        }
    }

    private var populatedGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: DesignTokens.Spacing.lg) {
                ForEach(viewModel.items) { item in
                    WorkshopBrowseCard(
                        item: item,
                        isInLibrary: installedWorkshopIDs.contains(String(item.id))
                    ) { selectedItem = item }
                }
            }
            .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
            .padding(.vertical, DesignTokens.Settings.formVerticalMargin)

            if viewModel.nextCursor != nil, viewModel.nextCursor != "*" {
                Button {
                    Task { await viewModel.loadMore() }
                } label: {
                    if viewModel.isLoadingMore {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading…")
                        }
                    } else {
                        Text("Load more")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isLoadingMore || viewModel.isRateLimited)
                .padding(.bottom, DesignTokens.Spacing.xl)
            }
        }
    }

    private var loadingSkeleton: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: DesignTokens.Spacing.lg) {
                ForEach(0..<6, id: \.self) { _ in
                    WorkshopSkeletonCard()
                }
            }
            .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
            .padding(.vertical, DesignTokens.Settings.formVerticalMargin)
        }
        .accessibilityLabel(Text("Loading Workshop results"))
    }

    private var apiKeyRequiredState: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "key.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Set your Steam Web API key to browse online.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(verbatim: WorkshopAPIKeyOwnershipInfo.passwordReassurance)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button {
                onRequestKeyEntry()
            } label: {
                Label("Set Web API key", systemImage: "key")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignTokens.Spacing.xl)
    }

    private var inspectorPlaceholder: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "square.dashed")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Select a wallpaper to see details.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignTokens.Spacing.lg)
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if hasActiveFilters {
                Button("Clear filters") { clearFilters() }
                    .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ error: WorkshopQueryError) -> some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(message(for: error))
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button("Retry") { Task { await viewModel.reload() } }
                    .buttonStyle(.borderedProminent)
                if case .missingAPIKey = error {
                    Button("Set Web API key") { onRequestKeyEntry() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignTokens.Spacing.xl)
    }

    @ViewBuilder
    private var rateLimitBanner: some View {
        if viewModel.isRateLimited {
            HStack(spacing: DesignTokens.Spacing.sm) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("Steam is rate-limiting — retry in \(Self.countdown(rateLimitRemaining))")
                        .font(.callout.weight(.medium))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Steam is rate-limiting. Retry in \(Self.countdown(rateLimitRemaining))."))

                Button("Retry") { Task { await viewModel.reload() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(rateLimitRemaining > 0)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            // Opaque material backing keeps the copy legible over the grid;
            // the orange tint + stroke read as a warning without bleed-through.
            .background(.regularMaterial, in: Capsule())
            .background(Color.orange.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5))
            .padding(DesignTokens.Spacing.md)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Helpers

    private var hasActiveFilters: Bool {
        !viewModel.searchInput.isEmpty || viewModel.typeFilter != .all || viewModel.ageRating != .everyone
    }

    private var currentRateLimitRemaining: TimeInterval {
        max(0, viewModel.rateLimitUntil?.timeIntervalSinceNow ?? 0)
    }

    private var emptyMessage: String {
        if !viewModel.searchInput.isEmpty {
            return String(localized: "No results for \"\(viewModel.searchInput)\".", comment: "Empty Workshop search result. Placeholder is the query.")
        }
        if hasActiveFilters {
            return String(localized: "No results for these filters.", comment: "Empty Workshop result when type/age filters exclude everything.")
        }
        return String(localized: "No results yet.", comment: "Initial empty Workshop browse state.")
    }

    private func clearFilters() {
        viewModel.updateType(.all)
        viewModel.updateAgeRating(.everyone)
        if !viewModel.searchInput.isEmpty { viewModel.updateSearch("") }
    }

    private func reloadInstalledIDs() {
        installedWorkshopIDs = Set(
            SettingsManager.shared.loadGlobalSettings().recentWPEImports.map { $0.origin.workshopID }
        )
    }

    private static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(ceil(seconds)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func message(for error: WorkshopQueryError) -> String {
        switch error {
        case .missingAPIKey:
            return "Set your Steam Web API key in Settings to browse online."
        case .unauthorized:
            return "Steam rejected the API key. Update it in Settings."
        case .keyDisabled:
            return "Your Steam API key was disabled by Valve. Regenerate one."
        case .rateLimited:
            return "Steam is rate-limiting. Please retry in a moment."
        case .networkUnreachable:
            return "Couldn't reach Steam. Check your connection."
        case .timeout:
            return "Steam took too long to respond. Retry?"
        case .http(let status):
            return "Steam returned HTTP \(status)."
        case .responseParseFailure, .schemaMismatch:
            return "Steam returned an unexpected response."
        case .cancelled:
            return "Cancelled."
        }
    }
}

/// Shimmering placeholder card matching `WorkshopBrowseCard`'s footprint, shown
/// during the first page load (zero layout shift when results arrive).
private struct WorkshopSkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkshopShimmer()
                .aspectRatio(1, contentMode: .fit)

            // Mirror WorkshopBrowseCard's textInfo footprint (2-line title +
            // type / meta row) so there is no layout shift on load.
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                WorkshopShimmer().frame(height: 13).frame(maxWidth: .infinity)
                WorkshopShimmer().frame(width: 120, height: 13)
                HStack(spacing: 6) {
                    WorkshopShimmer().frame(width: 46, height: 14).clipShape(Capsule())
                    Spacer(minLength: 0)
                    WorkshopShimmer().frame(width: 72, height: 11)
                }
            }
            .padding(DesignTokens.Spacing.md)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                .strokeBorder(Color.primary.opacity(DesignTokens.Card.strokeOpacity), lineWidth: DesignTokens.Card.strokeWidth)
        }
        .accessibilityHidden(true)
    }
}

/// Pulsing skeleton fill. Opacity is `Animatable`, so this interpolates
/// smoothly (a moving `LinearGradient` would not — gradients don't animate).
/// Under Reduce Motion it freezes on a static mid-tone.
private struct WorkshopShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsed = false

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(opacity))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulsed = true
                }
            }
    }

    private var opacity: Double {
        if reduceMotion { return 0.08 }
        return pulsed ? 0.14 : 0.05
    }
}
#endif
