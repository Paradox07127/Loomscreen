#if !LITE_BUILD && DIRECT_DISTRIBUTION
import LiveWallpaperSharedUI
import SwiftUI

/// Bottom-trailing live progress card for in-flight Workshop downloads. Reads
/// the shared `WorkshopDownloadCoordinator`, so a download's progress stays
/// visible after the detail inspector that started it is dismissed. The terminal
/// success/failure is announced separately by `WorkshopDownloadToastHost`.
struct WorkshopDownloadProgressHost: View {
    private var coordinator: WorkshopDownloadCoordinator { .shared }

    var body: some View {
        let active = coordinator.activeDownloads
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(active) { item in
                card(item)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: active)
    }

    private func card(_ item: WorkshopDownloadCoordinator.ActiveDownload) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.18)).frame(width: 28, height: 28)
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title.isEmpty
                     ? String(localized: "Workshop item", comment: "Fallback title in the download progress card.")
                     : item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let fraction = item.fraction, !item.isImporting {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                    Text(verbatim: "\(Int((fraction * 100).rounded()))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(item.isImporting ? "Importing…" : "Downloading…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 200, alignment: .leading)

            Button {
                coordinator.cancel(item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(Text("Cancel download"))
            .accessibilityLabel(Text("Cancel download"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
        .accessibilityElement(children: .combine)
    }
}

/// Bottom-trailing toast announcing a finished Workshop action (a SteamCMD
/// download or a local folder import — success or the failure reason). Observes
/// the shared `WorkshopToastCenter`, so it fires even after the detail sheet or
/// panel that started the action has been dismissed.
struct WorkshopDownloadToastHost: View {
    private let center = WorkshopToastCenter.shared
    @State private var shown: WorkshopToastEvent?

    var body: some View {
        VStack {
            if let event = shown {
                toast(event)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: shown?.token)
        // Reading `lastEvent` here ties this host to the @Observable center
        // so each new terminal outcome re-fires the toast.
        .onChange(of: center.lastEvent?.token) { _, _ in
            if let event = center.lastEvent { shown = event }
        }
        .task(id: shown?.token) {
            guard let event = shown else { return }
            // Errors linger longer than successes so they can be read.
            try? await Task.sleep(for: .seconds(event.isSuccess ? 4 : 7))
            withAnimation(.easeOut(duration: 0.2)) { shown = nil }
        }
    }

    private func toast(_ event: WorkshopToastEvent) -> some View {
        let tint = event.isSuccess ? Color.green : Color.red
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.18)).frame(width: 28, height: 28)
                Image(systemName: event.isSuccess ? "checkmark" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: event.headline)
                    .font(.system(size: 13, weight: .semibold))
                Text(verbatim: event.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: event.message)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 240, alignment: .leading)

            Button {
                withAnimation(.easeOut(duration: 0.2)) { shown = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(event.headline): \(event.title). \(event.message)"))
    }
}
#endif
