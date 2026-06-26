#if !LITE_BUILD && DIRECT_DISTRIBUTION
import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

@MainActor
struct WorkshopCacheManagementView: View {
    let cache: WorkshopQueryCache

    @State private var cacheSizeBytes: Int64 = 0
    @State private var isLoading: Bool = true
    @State private var showingClearConfirmation: Bool = false

    var body: some View {
        Form {
            Section {
                if isLoading {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Calculating cache size…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(byteFormatter.string(fromByteCount: cacheSizeBytes))
                            .font(DesignTokens.Typography.pageTitle)
                        Text("On-disk Workshop browse cache")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Workshop browse cache")
            } footer: {
                Text("Caches Steam Workshop `QueryFiles` JSON responses for 5 minutes to keep browsing snappy. Preview thumbnails share the v1 image cache and are cleared separately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Label("Clear cache", systemImage: "trash")
                }
                .destructiveControlTint()
                .disabled(cacheSizeBytes == 0 || isLoading)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
        .padding(.vertical, DesignTokens.Settings.formVerticalMargin)
        .background(DesignTokens.Colors.pageBackground)
        .onAppear { Task { await refresh() } }
        .confirmationDialog(
            "Clear Workshop browse cache?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                Task {
                    await cache.clear()
                    await refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes all cached Workshop query responses. Pages will reload from Steam the next time you browse.")
        }
    }

    private func refresh() async {
        isLoading = true
        cacheSizeBytes = await cache.sizeBytes()
        isLoading = false
    }

    private var byteFormatter: ByteCountFormatter {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        f.includesUnit = true
        return f
    }
}
#endif
