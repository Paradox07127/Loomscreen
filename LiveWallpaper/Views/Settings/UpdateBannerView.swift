#if LITE_BUILD
import SwiftUI
import AppKit

/// One-row update status surface for the About panel. Drives `UpdateChecker.shared`
/// and renders the four state-machine outcomes plus a manual "Check Now" affordance.
/// Renders ONLY in the Loomscreen Lite build — Pro hides this section entirely
/// because its update path will be Sparkle, not GitHub Releases.
struct UpdateBannerView: View {
    @State private var checker = UpdateChecker.shared
    @State private var showingAvailableAlert = false
    @State private var availableRelease: UpdateChecker.LatestRelease?

    var body: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 12) {
                statusGlyph
                    .font(.title3)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.subheadline.weight(.medium))
                    if let detail = statusDetail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailingAction
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
        }
        .onChange(of: checker.status) { _, newStatus in
            if case .available(let release) = newStatus {
                availableRelease = release
                showingAvailableAlert = true
            }
        }
        .alert(
            "New version available",
            isPresented: $showingAvailableAlert,
            presenting: availableRelease
        ) { release in
            Button("Open download page") {
                NSWorkspace.shared.open(release.releasePageURL)
            }
            Button("Skip this version") {
                checker.skipCurrentAvailable()
            }
            Button("Later", role: .cancel) {}
        } message: { release in
            Text("\(BundleIdentity.productDisplayName) \(release.version.description) is available. Open the GitHub Releases page to download the new build.")
        }
    }

    // MARK: - Status rendering

    @ViewBuilder
    private var statusGlyph: some View {
        switch checker.status {
        case .idle:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .available:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var statusTitle: String {
        switch checker.status {
        case .idle:
            return "Update checker idle"
        case .checking:
            return "Checking for updates…"
        case .upToDate:
            return "\(BundleIdentity.productDisplayName) is up to date"
        case .available(let release):
            return "\(BundleIdentity.productDisplayName) \(release.version.description) available"
        case .failed:
            return "Update check failed"
        }
    }

    private var statusDetail: String? {
        switch checker.status {
        case .idle:
            return lastCheckedSummary
        case .checking:
            return "Asking GitHub for the latest release tag…"
        case .upToDate:
            return lastCheckedSummary
        case .available(let release):
            if let publishedAt = release.publishedAt {
                return "Released " + Self.relativeFormatter.localizedString(for: publishedAt, relativeTo: Date())
            }
            return release.tagName
        case .failed(let reason):
            return reason
        }
    }

    @ViewBuilder
    private var trailingAction: some View {
        switch checker.status {
        case .available(let release):
            Button("Open") {
                NSWorkspace.shared.open(release.releasePageURL)
            }
            .controlSize(.small)
        case .checking:
            EmptyView()
        default:
            Button {
                Task { await checker.checkNow(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(Text("Check for updates now"))
            .accessibilityLabel(Text("Check for updates now"))
        }
    }

    private var lastCheckedSummary: String {
        guard let date = checker.lastCheckedAt else {
            return "Not checked yet"
        }
        return "Last checked " + Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
#endif
