import SwiftUI
import AppKit

struct AppleAerialsLibraryView: View {
    private let library = AppleAerialsLibrary.shared
    @Environment(ScreenManager.self) private var screenManager

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            if library.isAuthorized {
                inlineHeader
            }

            Group {
                if !library.isAuthorized {
                    unauthorizedState
                } else if let err = library.lastScanError, !err.isEmpty, library.assets.isEmpty {
                    scanErrorView(message: err)
                } else if library.assets.isEmpty {
                    emptyState
                } else {
                    galleryGrid
                }
            }
        }
        .task {
            if library.isAuthorized && library.assets.isEmpty {
                await library.refresh()
            }
        }
    }

    private func scanErrorView(message: String) -> some View {
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

    private var inlineHeader: some View {
        HStack(spacing: 8) {
            Text("Apple Aerials")
                .font(.system(size: 14, weight: .semibold))
            if library.isScanning {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button {
                Task { await library.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(Text("Refresh"))
            .disabled(library.isScanning)

            Button {
                library.clearAccess()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .destructiveControlTint()
            .help(Text("Disconnect Aerials library"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var unauthorizedState: some View {
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

    private var emptyState: some View {
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

    private var galleryGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if library.isScanning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning library…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(library.assets) { asset in
                        AerialThumbnailCard(asset: asset) {
                            applyAsset(asset)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func applyAsset(_ asset: AerialAsset) {
        let displays = screenManager.screens
        guard !displays.isEmpty else { return }

        // Refresh releases the directory scope; use the file bookmark here.
        guard let scopedURL = resolveScopedURL(asset.bookmarkData) else {
            Logger.error("Failed to resolve aerial bookmark; user may need to reconnect", category: .fileAccess)
            return
        }

        if displays.count == 1, let screen = displays.first {
            screenManager.setVideo(url: scopedURL, bookmarkData: asset.bookmarkData, for: screen)
            return
        }

        let menu = NSMenu()
        ApplyMenuRouter.shared.screenManager = screenManager

        for screen in displays {
            let item = NSMenuItem(
                title: String(
                    localized: "menu.apply_to_screen",
                    defaultValue: "Apply to \(screen.name)",
                    comment: "Apply Aerial wallpaper menu item; %@ is the display name."
                ),
                action: #selector(ApplyMenuRouter.applyFromMenu(_:)),
                keyEquivalent: ""
            )
            item.representedObject = ApplyTarget(asset: asset, screen: screen, resolvedURL: scopedURL)
            item.target = ApplyMenuRouter.shared
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let allItem = NSMenuItem(
            title: String(
                localized: "menu.apply_to_all_displays",
                defaultValue: "Apply to All Displays",
                comment: "Apply Aerial wallpaper to all connected displays."
            ),
            action: #selector(ApplyMenuRouter.applyToAllFromMenu(_:)),
            keyEquivalent: ""
        )
        allItem.representedObject = ApplyAllTarget(asset: asset, screens: displays, resolvedURL: scopedURL)
        allItem.target = ApplyMenuRouter.shared
        menu.addItem(allItem)

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func resolveScopedURL(_ bookmarkData: Data) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private func openWallpaperSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Apply Menu Router

private struct ApplyTarget {
    let asset: AerialAsset
    let screen: Screen
    let resolvedURL: URL
}

private struct ApplyAllTarget {
    let asset: AerialAsset
    let screens: [Screen]
    let resolvedURL: URL
}

@MainActor
private final class ApplyMenuRouter: NSObject {
    static let shared = ApplyMenuRouter()
    weak var screenManager: ScreenManager?

    @objc fileprivate func applyFromMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ApplyTarget,
              let manager = screenManager else { return }
        manager.setVideo(url: target.resolvedURL, bookmarkData: target.asset.bookmarkData, for: target.screen)
    }

    @objc fileprivate func applyToAllFromMenu(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ApplyAllTarget,
              let manager = screenManager else { return }
        for screen in target.screens {
            manager.setVideo(url: target.resolvedURL, bookmarkData: target.asset.bookmarkData, for: screen)
        }
    }
}
