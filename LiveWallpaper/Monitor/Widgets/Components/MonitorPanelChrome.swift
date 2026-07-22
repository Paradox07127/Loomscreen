import AppKit
import SwiftUI

struct MonitorPanelChrome: ViewModifier {
    var cornerRadius: CGFloat = MonitorBoardGeometry.appleCornerRadius

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [MonitorDesign.panelFillTop, MonitorDesign.panelFillBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(MonitorGrain(cornerRadius: cornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [MonitorDesign.panelTopHighlight, .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: .black.opacity(0.42), radius: 22, x: 0, y: 14)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(MonitorDesign.panelStroke, lineWidth: MonitorDesign.hairlineWidth)
            )
    }
}

extension View {
    /// Wrap a widget's content in the standard Ambient-Instrument panel body.
    func monitorPanelChrome(cornerRadius: CGFloat = MonitorBoardGeometry.appleCornerRadius) -> some View {
        modifier(MonitorPanelChrome(cornerRadius: cornerRadius))
    }
}

/// Procedural film-grain: a seeded speckle field drawn once into a bitmap and tiled at whisper opacity via `overlay` blend.
struct MonitorGrain: View {
    var cornerRadius: CGFloat = MonitorBoardGeometry.appleCornerRadius
    var opacity: Double = 0.022

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            if let image = Self.grainImage(width: size.width, height: size.height) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: size.width, height: size.height)
                    .opacity(opacity)
                    .blendMode(.overlay)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
    }

    /// Deterministic monochrome speckle, cached by rounded pixel dimensions so a
    /// steady panel size hits the cache instead of re-rasterising.
    private static var cache: [String: NSImage] = [:]

    static func grainImage(width: CGFloat, height: CGFloat) -> NSImage? {
        let w = max(1, Int(width.rounded()))
        let h = max(1, Int(height.rounded()))
        let key = "\(w)x\(h)"
        if let hit = cache[key] { return hit }

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        var state: UInt64 = 0x9E3779B97F4A7C15  // fixed seed → stable grain

        for i in stride(from: 0, to: pixels.count, by: 4) {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let v = UInt8(truncatingIfNeeded: state)
            pixels[i] = v
            pixels[i + 1] = v
            pixels[i + 2] = v
            pixels[i + 3] = 255
        }

        guard let ctx = CGContext(
            data: &pixels,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = ctx.makeImage() else { return nil }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: w, height: h))
        cache[key] = image
        return image
    }
}

#Preview("Panel chrome") {
    VStack(spacing: 24) {
        Text("SMALL")
            .font(MonitorDesign.labelFont(size: 11))
            .foregroundStyle(MonitorDesign.inkFaint)
            .frame(width: 150, height: 150)
            .monitorPanelChrome()

        Text("WIDE PANEL")
            .font(MonitorDesign.labelFont(size: 11))
            .foregroundStyle(MonitorDesign.inkFaint)
            .frame(width: 320, height: 150)
            .monitorPanelChrome()
    }
    .padding(40)
    .background(MonitorDesign.boardWash)
}
