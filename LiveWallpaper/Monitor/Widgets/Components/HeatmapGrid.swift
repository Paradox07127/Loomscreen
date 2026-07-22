import SwiftUI

struct HeatmapGrid: View {
    /// Row-major intensities 0…1. Grid is `rows` × `columns`; short arrays leave
    /// trailing cells at zero, long arrays are clipped.
    var intensities: [Double]
    var rows: Int
    var columns: Int
    var spacing: CGFloat = 3
    var cellCornerRadius: CGFloat = 2

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<max(1, rows), id: \.self) { r in
                HStack(spacing: spacing) {
                    ForEach(0..<max(1, columns), id: \.self) { c in
                        cell(at: r * columns + c)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(at index: Int) -> some View {
        let value = index < intensities.count ? min(1, max(0, intensities[index])) : 0
        RoundedRectangle(cornerRadius: cellCornerRadius, style: .continuous)
            .fill(MonitorDesign.track2)
            .overlay(
                RoundedRectangle(cornerRadius: cellCornerRadius, style: .continuous)
                    .fill(Self.rampColor(value))
                    .opacity(Self.rampOpacity(value))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cellCornerRadius, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.3), lineWidth: 1)
            )
            .aspectRatio(1, contentMode: .fit)
    }

    /// Fill hue for an intensity — amber for load, coral above the 0.8 band.
    /// Pure so tests can pin the ramp.
    nonisolated static func rampColor(_ value: Double) -> Color {
        value > 0.8 ? MonitorDesign.signalCoral : MonitorDesign.signalAmber
    }

    nonisolated static func rampOpacity(_ value: Double) -> Double {
        0.12 + min(1, max(0, value)) * 0.88
    }
}

#Preview("Heatmap grid") {
    VStack(spacing: 20) {
        HeatmapGrid(
            intensities: (0..<18).map { _ in Double.random(in: 0...1) },
            rows: 3, columns: 6
        )
        .frame(width: 200, height: 100)

        HeatmapGrid(
            intensities: (0..<49).map { Double($0 % 7) / 7.0 },
            rows: 7, columns: 7
        )
        .frame(width: 180, height: 180)
    }
    .padding(28)
    .background(MonitorDesign.boardWash)
}
