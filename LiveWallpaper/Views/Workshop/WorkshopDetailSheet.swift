#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import LiveWallpaperSharedUI
import SwiftUI

/// macOS-native detail sheet for a single Workshop item. `HSplitView` with an
/// auto-playing hero preview + actions on the left and metadata + description
/// on the right. Download stays disabled (Phase 3) with an explanatory help
/// tooltip; "Open in Steam" and the copy actions are live.
struct WorkshopDetailSheet: View {
    let item: WorkshopQueryItem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                leftPane
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                rightPane
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            Divider()
            footerBar
        }
        .frame(width: 720, height: 480)
        .background(DesignTokens.Colors.pageBackground)
    }

    // MARK: - Left (hero + actions)

    private var leftPane: some View {
        VStack(spacing: 0) {
            AnimatedGIFThumbnail(url: item.previewImageURL, playbackMode: .autoPlay)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
                .padding(DesignTokens.Spacing.md)
                .frame(maxHeight: .infinity)

            Divider()
            actionsBar
        }
    }

    private var actionsBar: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button {
                    openURL(item.steamCommunityURL)
                } label: {
                    Label("Open in Steam", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(item.isBanned)
                .help(Text("Open this item on the Steam Community website"))

                Button {
                    // Disabled until Phase 3 wires the SteamCMD download executor.
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(true)
                .help(Text("Wire up SteamCMD in Settings to enable Workshop downloads."))
                .accessibilityHint(Text("Disabled. Wire up SteamCMD in Settings to enable Workshop downloads."))
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                Button {
                    copy(item.steamCommunityURL.absoluteString)
                } label: {
                    Label("Copy link", systemImage: "link").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    copy(String(item.id))
                } label: {
                    Label("Copy ID", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(DesignTokens.Spacing.md)
    }

    // MARK: - Right (metadata + description)

    private var rightPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                Text(item.title)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                metaRow
                statusBadge

                if !item.tags.isEmpty {
                    tagsFlow
                }

                Divider()

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text("Description")
                        .font(.headline)
                    Text(item.shortDescription.isEmpty
                         ? String(localized: "No description provided.", comment: "Placeholder when a Workshop item has no description.")
                         : item.shortDescription)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.lg)
        }
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            if let count = item.subscriptionCount, count > 0 {
                Text(formatSubs(count))
                Text(verbatim: "·").foregroundStyle(.tertiary)
            }
            if let updated = item.timeUpdated {
                Text("Updated \(Self.dateFormatter.string(from: updated))")
                if item.fileSizeBytes != nil {
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                }
            }
            if let size = item.fileSizeBytes {
                Text(verbatim: Self.byteFormatter.string(fromByteCount: Int64(size)))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if item.isBanned {
            Label("Unavailable — removed or hidden on Steam", systemImage: "xmark.octagon.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
        }
    }

    private var tagsFlow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(item.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
        }
    }

    private var footerBar: some View {
        HStack {
            Button {
                openURL(item.steamCommunityURL)
            } label: {
                Label("View on Steam Community", systemImage: "safari")
            }
            .buttonStyle(.link)

            Spacer()

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md)
    }

    // MARK: - Helpers

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(value, forType: .string)
    }

    private func formatSubs(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM subs", Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.1fK subs", Double(count) / 1_000.0)
        }
        return "\(count) subs"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
}
#endif
