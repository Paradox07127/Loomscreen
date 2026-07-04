import SwiftUI

struct SparkleUpdateTestPanel: View {
    private let configuration = SparkleUpdateConfiguration.self
    private let service: SparkleUpdateService

    init(service: SparkleUpdateService = .shared) {
        self.service = service
    }

    var body: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(verbatim: "Sparkle update testing")
                            .font(.subheadline.weight(.medium))
                        Label("Testing only", systemImage: "testtube.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(verbatim: configuration.feedSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    service.checkForUpdates()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(Text(verbatim: "Check local Sparkle appcast"))
                .accessibilityLabel(Text(verbatim: "Check local Sparkle appcast"))
                .disabled(!configuration.manualChecksEnabled)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
        }
        .opacity(configuration.manualChecksEnabled ? 1 : 0.55)
    }
}
