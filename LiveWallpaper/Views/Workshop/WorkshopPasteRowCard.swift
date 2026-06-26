#if !LITE_BUILD && DIRECT_DISTRIBUTION
import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

struct WorkshopPasteRowCard: View {
    let row: WorkshopPasteQueueModel.Row
    let onRetry: () -> Void
    let onRemove: () -> Void
    let onOpenInSteam: () -> Void
    let onCopyDiagnostic: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 8) {
                header
                if row.state == .ready, let metadata = row.metadata {
                    SteamWorkshopMetadataView(metadata: metadata)
                } else if row.state == .fetchingMetadata {
                    SkeletonLines()
                } else if let error = row.error {
                    WorkshopRowErrorStrip(error: error)
                }
                footerActions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                .strokeBorder(Color.primary.opacity(DesignTokens.Card.strokeOpacity), lineWidth: DesignTokens.Card.strokeWidth)
        }
        .shadow(
            color: .black.opacity(DesignTokens.Card.restShadowOpacity),
            radius: DesignTokens.Card.restShadowRadius,
            x: 0,
            y: DesignTokens.Card.restShadowYOffset
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
        ZStack {
            shape.fill(Color.secondary.opacity(0.12))
            if let url = row.metadata?.previewImageURL {
                WorkshopPreviewImage(url: url)
                    .accessibilityHidden(true)
            } else if row.state == .fetchingMetadata {
                ProgressView().controlSize(.small)
            } else if row.state == .invalidInput {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(DesignTokens.Colors.Status.caution)
            } else {
                Image(systemName: "cube.transparent")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 152, height: 86)
        .clipShape(shape)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: titleText)
                .font(DesignTokens.Typography.sectionTitle)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            statusBadge
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch row.state {
        case .ready:
            BadgeChip(text: "Ready", tint: DesignTokens.Colors.Status.active, systemImage: "checkmark.seal.fill")
        case .fetchingMetadata:
            BadgeChip(text: "Fetching", tint: .blue, systemImage: "hourglass")
        case .invalidInput:
            BadgeChip(text: "Invalid", tint: DesignTokens.Colors.Status.caution, systemImage: "exclamationmark.triangle.fill")
        case .failed:
            BadgeChip(text: errorBadgeLabel, tint: DesignTokens.Colors.Status.danger, systemImage: "xmark.octagon.fill")
        }
    }

    @ViewBuilder
    private var footerActions: some View {
        HStack(spacing: 8) {
            if row.steamURL != nil {
                Button(action: onOpenInSteam) {
                    Label("Open in Steam", systemImage: "arrow.up.forward.app")
                        .font(DesignTokens.Typography.body)
                }
                .buttonStyle(.borderless)
            }

            if row.state == .failed, !isInvalidInputState {
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(DesignTokens.Typography.body)
                }
                .buttonStyle(.borderless)
            }

            Spacer()

            if row.state == .failed || row.state == .invalidInput {
                Button(action: onCopyDiagnostic) {
                    Label("Copy diagnostic", systemImage: "doc.on.clipboard")
                        .font(DesignTokens.Typography.body)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            Button(role: .destructive, action: onRemove) {
                Label("Remove", systemImage: "xmark.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Remove from queue"))
        }
    }

    // MARK: - Derived strings

    private var titleText: String {
        if let metadata = row.metadata, !metadata.title.isEmpty {
            return metadata.title
        }
        if let id = row.publishedFileID {
            return "Workshop item \(id)"
        }
        return row.originalInput
    }

    private var errorBadgeLabel: String {
        switch row.error {
        case .itemPrivate: return "Private"
        case .itemBanned: return "Banned"
        case .itemNotFound: return "Not found"
        case .timeout, .networkUnreachable: return "Network"
        case .rateLimited: return "Rate limit"
        case .unauthorized: return "Locked"
        case .http(let status): return "HTTP \(status)"
        case .responseParseFailure, .schemaMismatch: return "Bad payload"
        case .invalidInput: return "Invalid"
        case .cancelled: return "Cancelled"
        case .unknown: return "Failed"
        case .none: return "Failed"
        }
    }

    private var isInvalidInputState: Bool {
        if case .invalidInput = row.error { return true }
        return row.state == .invalidInput
    }

    private var accessibilityLabel: Text {
        switch row.state {
        case .ready:
            return Text("\(titleText), ready", comment: "Workshop paste row accessibility label. %@ is the workshop item title.")
        case .fetchingMetadata:
            return Text("\(titleText), fetching details", comment: "Workshop paste row accessibility label. %@ is the workshop item title.")
        case .invalidInput:
            return Text("\(titleText), invalid", comment: "Workshop paste row accessibility label. %@ is the original pasted input.")
        case .failed:
            return Text("\(titleText), failed: \(errorBadgeLabel)", comment: "Workshop paste row accessibility label. Placeholders are the item title and a short error label.")
        }
    }
}

// MARK: - Helper Views

private struct BadgeChip: View {
    let text: String
    let tint: Color
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(DesignTokens.Typography.badge)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct SkeletonLines: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<2, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 10)
                    .frame(maxWidth: index == 0 ? .infinity : 220, alignment: .leading)
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}

private struct SteamWorkshopMetadataView: View {
    let metadata: SteamWorkshopMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !metadata.shortDescription.isEmpty {
                Text(verbatim: metadata.shortDescription)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if let size = metadata.fileSizeBytes {
                    Label(WorkshopByteFormatter.string(size), systemImage: "doc")
                }
                if let updated = metadata.timeUpdated {
                    Label(WorkshopRelativeDateFormatter.string(updated), systemImage: "clock")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
    }
}

private struct WorkshopRowErrorStrip: View {
    let error: SteamWorkshopMetadataError

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .imageScale(.small)
            Text(verbatim: copy)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous))
    }

    private var tint: Color {
        switch error {
        case .itemBanned, .itemNotFound, .responseParseFailure, .schemaMismatch:
            return DesignTokens.Colors.Status.danger
        case .rateLimited:
            // Orange signals "auto-retrying", distinct from yellow ("user action recommended").
            return DesignTokens.Colors.Status.warning
        case .invalidInput, .itemPrivate, .timeout, .networkUnreachable,
             .unauthorized, .http:
            return DesignTokens.Colors.Status.caution
        case .cancelled, .unknown:
            return .secondary
        }
    }

    private var icon: String {
        switch error {
        case .itemBanned, .itemNotFound, .responseParseFailure, .schemaMismatch:
            return "xmark.octagon.fill"
        case .invalidInput:
            return "exclamationmark.triangle.fill"
        case .itemPrivate:
            return "eye.slash"
        case .timeout, .networkUnreachable:
            return "wifi.exclamationmark"
        case .rateLimited:
            return "tortoise"
        case .unauthorized:
            return "lock.fill"
        case .http:
            return "network.slash"
        case .cancelled:
            return "slash.circle"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private var copy: String {
        switch error {
        case .invalidInput:
            return "Not a valid Steam Workshop URL."
        case .itemPrivate:
            return "This item is private or friends-only and can't be previewed here."
        case .itemBanned:
            return "Steam has flagged this item as unavailable."
        case .itemNotFound:
            return "Workshop item not found. It may have been removed."
        case .timeout, .networkUnreachable:
            return "Couldn't reach Steam. Check your connection."
        case .rateLimited(let retry):
            if let retry { return "Steam is rate-limiting. Retrying in \(Int(retry))s." }
            return "Steam is rate-limiting. Retrying shortly."
        case .unauthorized:
            return "Steam couldn't load this item's details. You can still open it in Steam."
        case .http(let status):
            return "Steam couldn't load this item (HTTP \(status))."
        case .responseParseFailure, .schemaMismatch:
            return "Steam returned an unexpected response."
        case .cancelled:
            return "Cancelled."
        case .unknown(let detail):
            return detail.isEmpty ? "Something went wrong." : detail
        }
    }
}

// MARK: - Formatters

/// Shows a fallback icon when `WorkshopPreviewImageLoader` rejects the URL
/// (allow-list miss, wrong content-type, oversize, etc.).
private struct WorkshopPreviewImage: View {
    let url: URL
    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if didFail {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url) {
            let loaded = await WorkshopPreviewImageLoader.shared.load(url)
            await MainActor.run {
                image = loaded
                didFail = (loaded == nil)
            }
        }
    }
}

enum WorkshopByteFormatter {
    static func string(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }
}

enum WorkshopRelativeDateFormatter {
    static func string(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
#endif
