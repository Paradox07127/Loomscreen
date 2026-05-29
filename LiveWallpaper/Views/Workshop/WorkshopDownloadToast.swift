#if !LITE_BUILD && DIRECT_DISTRIBUTION
import SwiftUI

/// Bottom-trailing toast announcing a finished Workshop download (success or
/// the failure reason). Observes the shared download coordinator, so it fires
/// even after the detail sheet that started the download has been dismissed.
struct WorkshopDownloadToastHost: View {
    private let coordinator = WorkshopDownloadCoordinator.shared
    @State private var shown: WorkshopDownloadCoordinator.DownloadEvent?

    var body: some View {
        VStack {
            if let event = shown {
                toast(event)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: shown?.token)
        // Reading `lastEvent` here ties this host to the @Observable coordinator
        // so each new terminal outcome re-fires the toast.
        .onChange(of: coordinator.lastEvent?.token) { _, _ in
            if let event = coordinator.lastEvent { shown = event }
        }
        .task(id: shown?.token) {
            guard let event = shown else { return }
            // Errors linger longer than successes so they can be read.
            try? await Task.sleep(for: .seconds(event.isSuccess ? 4 : 7))
            withAnimation(.easeOut(duration: 0.2)) { shown = nil }
        }
    }

    private func toast(_ event: WorkshopDownloadCoordinator.DownloadEvent) -> some View {
        let tint = event.isSuccess ? Color.green : Color.red
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.18)).frame(width: 28, height: 28)
                Image(systemName: event.isSuccess ? "checkmark" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(event.isSuccess ? "Downloaded" : "Download failed")
                    .font(.system(size: 13, weight: .semibold))
                Text(event.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(event.message)
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
        .accessibilityLabel(Text(event.isSuccess
            ? "Downloaded \(event.title). \(event.message)"
            : "Download failed for \(event.title). \(event.message)"))
    }
}
#endif
