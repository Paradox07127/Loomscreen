#if !LITE_BUILD && DIRECT_DISTRIBUTION
import SwiftUI

/// Observes the shared `WorkshopToastCenter` so it fires even after the detail
/// sheet or panel that started the action has been dismissed.
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
        // Reading `lastEvent` ties this host to the @Observable center so each new outcome re-fires.
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
        let tint = event.isSuccess ? DesignTokens.Colors.Status.active : DesignTokens.Colors.Status.danger
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.18)).frame(width: 28, height: 28)
                Image(systemName: event.isSuccess ? "checkmark" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: event.headline)
                    .font(DesignTokens.Typography.bodyEmphasized)
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
        .adaptiveGlassSurface(.roundedRectangle(DesignTokens.Corner.xl))
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(event.headline): \(event.title). \(event.message)"))
    }
}
#endif
