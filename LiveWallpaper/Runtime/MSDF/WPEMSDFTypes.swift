#if !LITE_BUILD
import CoreGraphics
import Foundation
import simd

struct WPEMSDFParameters {
    var pixelRange: Double = 4
    var padding: Int = 4
    var angleThreshold: Double = 3.0
    /// Max atlas cell side (pixels). MSDF is resolution-independent, so glyphs are
    /// rasterized at this fixed size and scaled up by the shader — generating at the
    /// on-screen point size (e.g. 200px) would cost ~18× more pixels and stall the
    /// main thread.
    var generationCellCap: Int = 64
}

typealias WPEMSDFPoint = SIMD2<Double>

enum WPEMSDFEdgeColor: UInt8, CaseIterable {
    case black = 0
    case red
    case green
    case yellow
    case blue
    case magenta
    case cyan
    case white

    func contains(_ channel: WPEMSDFEdgeColor) -> Bool {
        rawValue & channel.rawValue != 0
    }
}

struct WPEMSDFBitmap {
    let width: Int
    let height: Int
    var pixels: [SIMD4<Float>]

    init(width: Int, height: Int, fill: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)) {
        precondition(width >= 0 && height >= 0)
        self.width = width
        self.height = height
        self.pixels = [SIMD4<Float>](repeating: fill, count: width * height)
    }

    subscript(x: Int, y: Int) -> SIMD4<Float> {
        get {
            pixels[y * width + x]
        }
        set {
            pixels[y * width + x] = newValue
        }
    }

    func rgba8Data() -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for pixel in pixels {
            bytes.append(Self.byte(pixel.x))
            bytes.append(Self.byte(pixel.y))
            bytes.append(Self.byte(pixel.z))
            bytes.append(Self.byte(pixel.w))
        }
        return Data(bytes)
    }

    private static func byte(_ value: Float) -> UInt8 {
        let clamped = min(max(value, 0), 1)
        return UInt8((clamped * 255).rounded())
    }
}

struct WPEMSDFGlyphMetrics: Equatable {
    let cellSize: CGSize
    let bearing: WPEMSDFPoint
    let advance: WPEMSDFPoint
    let scale: Double
    let translate: WPEMSDFPoint
    let emUnitsPerPixel: Double

    init(
        cellSize: CGSize,
        bearing: WPEMSDFPoint,
        advance: WPEMSDFPoint,
        scale: Double,
        translate: WPEMSDFPoint,
        emUnitsPerPixel: Double
    ) {
        self.cellSize = cellSize
        self.bearing = bearing
        self.advance = advance
        self.scale = scale
        self.translate = translate
        self.emUnitsPerPixel = emUnitsPerPixel
    }
}

#endif
