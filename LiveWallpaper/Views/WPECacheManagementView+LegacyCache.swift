#if !LITE_BUILD
import SwiftUI

extension WPECacheManagementView {
    @ViewBuilder
    var legacyCacheSection: some View {
        if let stats, !stats.entries.isEmpty {
            Section {
                HStack(alignment: .center) {
                    summaryRow
                    StorageInfoButton {
                        infoNote("New scenes read their assets in place from the source, so this cache only holds older imports. Unreferenced leftovers are reclaimed automatically at startup.")
                    }
                }
            } header: {
                Text("Imported Project Cache")
            } footer: {
                if let last = lastFreedBytes, last > 0 {
                    Text("Freed \(Int64(last), format: .byteCount(style: .file)).", comment: "WPE cache management footer shown after a purge. Placeholder is the freed byte total, rendered through SwiftUI's byteCount format style.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(stats.entries) { entry in
                    cacheRow(for: entry)
                }
            } header: {
                Text(verbatim: "Cached Projects (\(stats.entries.count))")
            }

            Section {
                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        confirmClearAll()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .storageDestructiveIconStyle()
                    .controlSize(.regular)
                    .help(Text("Clear All"))
                    .accessibilityLabel(Text("Clear All"))

                    Button(role: .destructive) {
                        confirmPurgeOlderThan(days: 30)
                    } label: {
                        Label("Clear Unused > 30 days", systemImage: "calendar.badge.minus")
                    }
                    .destructiveControlTint()
                    .controlSize(.regular)
                    .disabled(unusedCandidates(olderThanDays: 30).isEmpty)

                    Spacer()
                }
            } footer: {
                if isOversized {
                    Label("Cache is using more than 1 GB. Consider clearing unused projects.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Colors.Status.warning)
                }
            }
        }
    }

    // MARK: - Header / rows

    @ViewBuilder
    private var summaryRow: some View {
        if isLoading {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Calculating cache size…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if let stats {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(byteFormatter.string(fromByteCount: Int64(stats.totalBytes)))
                        .font(DesignTokens.Typography.pageTitle)
                    Spacer()
                    if isOversized {
                        Label("Over 1 GB", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(DesignTokens.Colors.Status.warning)
                    }
                }
                Text("Across \(stats.entries.count) project\(stats.entries.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("No cache entries yet.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func cacheRow(for entry: WPECacheStats.Entry) -> some View {
        let title = displayTitle(for: entry.workshopID)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // Workshop names can be 60+ chars; without explicit truncation one
                // long entry forces every row to the longest title's width and wraps.
                Text(verbatim: title)
                    .font(DesignTokens.Typography.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: title))
                Text(rowSubtitle(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Button(role: .destructive) {
                confirmPurge(entry: entry)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(DesignTokens.Colors.Status.danger)
            .help(Text("Remove cached files for \(entry.workshopID)"))
            .accessibilityLabel(Text("Remove cache for \(entry.workshopID)"))
        }
        .padding(.vertical, 2)
    }

    /// Entries old enough to count as "unused" that are also unreachable. Single
    /// definition shared by the button's disabled state, confirmation count, and purge.
    func unusedCandidates(olderThanDays days: Int) -> [WPECacheStats.Entry] {
        let cutoff = Date().addingTimeInterval(TimeInterval(-days * 86_400))
        return (stats?.entries ?? []).filter {
            !reachableIDs.contains($0.workshopID) && ($0.lastUsed ?? .distantPast) <= cutoff
        }
    }

    private var isOversized: Bool {
        (stats?.totalBytes ?? 0) > 1_073_741_824
    }


    func displayTitle(for workshopID: String) -> String {
        cacheEntryTitles[workshopID] ?? workshopID
    }

    private func rowSubtitle(for entry: WPECacheStats.Entry) -> String {
        let size = byteFormatter.string(fromByteCount: Int64(entry.sizeBytes))
        guard let lastUsed = entry.lastUsed else { return size }
        let relative = relativeFormatter.localizedString(for: lastUsed, relativeTo: Date())
        return "\(size) · used \(relative)"
    }
}
#endif
