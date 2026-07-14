import SwiftUI
import AppKit

struct AppleAerialsLibraryView: View {
    private let library = AppleAerialsLibrary.shared
    @Environment(ScreenManager.self) private var screenManager
    @State private var searchText: String = ""
    @State private var pendingDestructive: PendingDestructive?

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 14)]

    var body: some View {
        DetailPageScaffold(
            showsHeader: library.isAuthorized,
            header: { inlineHeader },
            content: {
                if !library.isAuthorized {
                    unauthorizedState
                } else if let err = library.lastScanError, !err.isEmpty, library.assets.isEmpty {
                    scanErrorView(message: err)
                } else if library.assets.isEmpty {
                    emptyState
                } else {
                    galleryWithFilter
                }
            }
        )
        .confirmDestructive($pendingDestructive)
        .task {
            if library.isAuthorized && library.assets.isEmpty {
                await library.refresh()
            }
        }
    }

    private func scanErrorView(message: String) -> some View {
        GuidedLibrarySurface {
            LibraryGuideCard(
                icon: "exclamationmark.triangle",
                title: "Couldn't scan Aerials",
                message: "We hit a problem while scanning the Apple Aerials library.",
                features: [
                    LibraryGuideFeature(icon: "folder.badge.gearshape", text: "Reconnect the Apple Aerials library location"),
                    LibraryGuideFeature(icon: "arrow.triangle.2.circlepath", text: "Retry after macOS finishes updating the folder"),
                    LibraryGuideFeature(icon: "checkmark.shield", text: "Read-only access; no files are modified")
                ],
                actionTitle: "Reconnect",
                actionSystemImage: "folder.badge.gearshape",
                secondaryTitle: "Retry",
                secondarySystemImage: "arrow.clockwise",
                errorMessage: message,
                action: {
                    library.clearAccess()
                },
                secondaryAction: {
                    Task { await library.refresh() }
                }
            )
        }
    }

    private var inlineHeader: some View {
        DetailHeaderBar(
            systemImage: "sparkles.tv",
            title: { Text("Apple Aerials") },
            metadata: {
                HStack(spacing: DesignTokens.DetailHeader.metadataSpacing) {
                    Text("\(library.assets.count) downloaded videos")
                    if library.isScanning {
                        ProgressView().controlSize(.small)
                    }
                }
            },
            actions: {
                HStack(spacing: 8) {
                    Button {
                        Task { await library.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .adaptiveGlassButton(.regular)
                    .controlSize(.regular)
                    .help(Text("Refresh — rescan the Aerials library for new content"))
                    .accessibilityLabel(Text("Refresh Aerials library"))
                    .disabled(library.isScanning)

                    overflowMenu
                }
            }
        )
    }

    private var overflowMenu: some View {
        Menu {
            Button(role: .destructive) {
                pendingDestructive = PendingDestructive(.disconnectAerialsLibrary) {
                    library.clearAccess()
                }
            } label: {
                Label("Disconnect Aerials Library", systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .adaptiveGlassButton(.regular)
        .controlSize(.regular)
        .help(Text("More Aerials actions"))
        .accessibilityLabel(Text("More Aerials actions"))
    }

    private var galleryWithFilter: some View {
        VStack(spacing: 0) {
            LibraryFilterBar(
                searchText: $searchText,
                searchPrompt: "Search aerials",
                resultCount: filteredAssets.count,
                totalCount: library.assets.count
            )
            galleryGrid
        }
    }

    private var filteredAssets: [AerialAsset] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return library.assets }
        return library.assets.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed) ||
            ($0.category?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    private var unauthorizedState: some View {
        GuidedLibrarySurface {
            LibraryGuideCard(
                icon: "sparkles.tv",
                title: "Connect Apple Aerials",
                message: "Connect the local Apple Aerials library that contains downloaded aerial videos.",
                features: [
                    LibraryGuideFeature(icon: "folder.badge.gearshape", text: "Open the local Aerials folder automatically"),
                    LibraryGuideFeature(icon: "arrow.triangle.2.circlepath", text: "Refresh after macOS downloads or removes aerial videos"),
                    LibraryGuideFeature(icon: "checkmark.shield", text: "Read-only access; applied videos stay managed by LiveWallpaper")
                ],
                actionTitle: library.isScanning ? "Connecting..." : "Connect Library",
                actionSystemImage: "folder.badge.plus",
                isActionInProgress: library.isScanning,
                errorMessage: library.lastScanError,
                action: {
                    Task { _ = await library.requestAccess() }
                }
            )
        }
    }

    private var emptyState: some View {
        GuidedLibrarySurface {
            LibraryGuideCard(
                icon: "sparkles.tv",
                title: "No aerials downloaded yet",
                message: "Apple downloads aerial wallpapers on demand. Pick one from System Settings → Wallpaper, then refresh.",
                features: [
                    LibraryGuideFeature(icon: "gearshape", text: "Open Wallpaper settings and select an Apple aerial"),
                    LibraryGuideFeature(icon: "arrow.triangle.2.circlepath", text: "Refresh after macOS finishes downloading the video"),
                    LibraryGuideFeature(icon: "checkmark.shield", text: "Only downloaded .mov aerials are listed here")
                ],
                actionTitle: "Open System Settings",
                actionSystemImage: "gearshape",
                secondaryTitle: "Refresh",
                secondarySystemImage: "arrow.clockwise",
                action: openWallpaperSettings,
                secondaryAction: {
                    Task { await library.refresh() }
                }
            )
        }
    }

    @ViewBuilder
    private var galleryGrid: some View {
        if filteredAssets.isEmpty {
            IllustratedEmptyState(
                symbol: "magnifyingglass",
                title: "No aerials match your search",
                message: "Try a different keyword, or clear the search field to see every downloaded aerial."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if library.isScanning {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Scanning library…")
                                .font(DesignTokens.Typography.body)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                    }

                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(filteredAssets) { asset in
                            AerialThumbnailCard(
                                asset: asset,
                                screens: screenManager.screens,
                                onApply: { screen in apply(asset, to: screen) },
                                onApplyToAll: { applyToAll(asset) }
                            )
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    // MARK: - Apply

    private func apply(_ asset: AerialAsset, to screen: Screen) {
        guard let url = resolveScopedURL(asset.bookmarkData) else {
            Logger.error("Failed to resolve aerial bookmark; user may need to reconnect", category: .fileAccess)
            return
        }
        screenManager.setVideo(url: url, bookmarkData: asset.bookmarkData, for: screen)
    }

    private func applyToAll(_ asset: AerialAsset) {
        for screen in screenManager.screens {
            apply(asset, to: screen)
        }
    }

    private func resolveScopedURL(_ bookmarkData: Data) -> URL? {
        try? SecurityScopedBookmarkResolver.shared
            .resolve(bookmarkData, target: .transient).get().url
    }

    private func openWallpaperSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
