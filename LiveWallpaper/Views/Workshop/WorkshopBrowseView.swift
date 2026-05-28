#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import LiveWallpaperSharedUI
import SwiftUI

/// Online Workshop browse — modal sheet that paginates `QueryFiles`
/// results into a grid of `WorkshopBrowseCard`. The sheet does not
/// download wallpapers; it points users to Steam for now (Phase 3 wires
/// per-row Download once Doctor is green).
struct WorkshopBrowseView: View {
    let services: WorkshopServices
    let onRequestKeyEntry: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: WorkshopBrowseViewModel

    init(services: WorkshopServices, onRequestKeyEntry: @escaping () -> Void) {
        self.services = services
        self.onRequestKeyEntry = onRequestKeyEntry
        _viewModel = State(initialValue: WorkshopBrowseViewModel(services: services))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            content
        }
        .frame(minWidth: 880, idealWidth: 960, minHeight: 600, idealHeight: 700)
        .background(DesignTokens.Colors.pageBackground)
        .onAppear {
            viewModel.onAppear()
            Task { await services.refreshAPIKeyStatus() }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Steam Workshop · Browse")
                    .font(.system(size: 14, weight: .semibold))
                Text("Online metadata from Valve. Requires your own Steam Web API key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignTokens.Spacing.md)

            searchField

            Picker("Sort", selection: Binding(
                get: { viewModel.preferredSort },
                set: { viewModel.updateSort($0) }
            )) {
                ForEach(visibleSorts, id: \.self) { sort in
                    Text(sort.displayName).tag(sort)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 160)
            .disabled(!services.hasWebAPIKey)
            .help("Sort criteria")

            Button {
                Task { await viewModel.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .help("Refresh")
            .disabled(!services.hasWebAPIKey || viewModel.isLoading)

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
        .padding(.vertical, DesignTokens.Settings.formVerticalMargin)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search Workshop", text: Binding(
                get: { viewModel.searchInput },
                set: { viewModel.updateSearch($0) }
            ))
            .textFieldStyle(.plain)
            .disabled(!services.hasWebAPIKey)
            if !viewModel.searchInput.isEmpty {
                Button {
                    viewModel.updateSearch("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .frame(maxWidth: 320)
    }

    private var visibleSorts: [WorkshopSortMode] {
        [.topRated, .newest, .trending, .mostSubscribed]
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !services.hasWebAPIKey {
            apiKeyRequiredState
        } else if let error = viewModel.lastError, viewModel.items.isEmpty {
            errorState(error)
        } else if viewModel.items.isEmpty, viewModel.isLoading {
            loadingState
        } else if viewModel.items.isEmpty {
            emptyState
        } else {
            grid
                .overlay(alignment: .top) { transientErrorBanner }
        }
    }

    @ViewBuilder
    private var transientErrorBanner: some View {
        if let error = viewModel.lastError, !viewModel.items.isEmpty {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message(for: error))
                    .font(.callout)
                    .lineLimit(2)
                Spacer()
                Button("Retry") { Task { await viewModel.reload() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .padding(DesignTokens.Spacing.md)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel(Text("Browse error: \(message(for: error))"))
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: DesignTokens.Spacing.lg)],
                spacing: DesignTokens.Spacing.lg
            ) {
                ForEach(viewModel.items) { item in
                    WorkshopBrowseCard(item: item)
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
                .disabled(viewModel.isLoadingMore)
                .padding(.bottom, DesignTokens.Spacing.xl)
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            ProgressView()
            Text("Fetching from Steam…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(viewModel.searchInput.isEmpty ? "No results yet." : "No results for \"\(viewModel.searchInput)\".")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if !viewModel.searchInput.isEmpty {
                Button("Clear search") { viewModel.updateSearch("") }
                    .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var apiKeyRequiredState: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "key.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Set your Steam Web API key to browse online.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button {
                onRequestKeyEntry()
            } label: {
                Label("Set Web API key", systemImage: "key")
            }
            .buttonStyle(.borderedProminent)
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
                .foregroundStyle(.primary)
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
#endif
