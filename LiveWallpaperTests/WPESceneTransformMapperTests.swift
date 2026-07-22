import CoreGraphics
import Testing
@testable import LiveWallpaper

@Suite("WPESceneTransformMapper")
struct WPESceneTransformMapperTests {
    @Test("Angles are interpreted as radians")
    func angleUsesRadians() {
        let result = WPESceneTransformMapper.spriteTransform(
            origin: SIMD3<Double>(0.5, 0.5, 0),
            angles: SIMD3<Double>(0, 0, Double.pi / 2),
            alignment: .center,
            canvas: CGSize(width: 1920, height: 1080)
        )

        #expect(abs(result.zRotation - CGFloat(Double.pi / 2)) < 0.0001)
    }

    @Test("Normalized center origins map to the scene center")
    func normalizedOriginHeuristicIsPreserved() {
        let result = WPESceneTransformMapper.spriteTransform(
            origin: SIMD3<Double>(0.5, 0.5, 0),
            angles: SIMD3<Double>(0, 0, 0),
            alignment: .center,
            canvas: CGSize(width: 1920, height: 1080)
        )

        #expect(result.position == CGPoint(x: 960, y: 540))
    }

    @Test("Top-left alignment preserves authored scene coordinates")
    func topLeftAlignmentHeuristicIsPreserved() {
        let result = WPESceneTransformMapper.spriteTransform(
            origin: SIMD3<Double>(100, 200, 0),
            angles: SIMD3<Double>(0, 0, 0),
            alignment: .topLeft,
            canvas: CGSize(width: 1920, height: 1080)
        )

        #expect(result.position == CGPoint(x: 100, y: 880))
    }
}
