import CoreGraphics
import Foundation

struct WPESceneSpriteTransform: Equatable, Sendable {
    let position: CGPoint
    let zRotation: CGFloat
}

enum WPESceneTransformMapper {
    static func spriteTransform(
        origin: SIMD3<Double>,
        angles: SIMD3<Double>,
        alignment: WPESceneAlignment,
        canvas: CGSize
    ) -> WPESceneSpriteTransform {
        WPESceneSpriteTransform(
            position: position(for: origin, canvas: canvas, alignment: alignment),
            zRotation: CGFloat(angles.z)
        )
    }

    private static func position(
        for origin: SIMD3<Double>,
        canvas: CGSize,
        alignment: WPESceneAlignment
    ) -> CGPoint {
        let x = CGFloat(origin.x)
        let y = CGFloat(origin.y)
        // Preserve the Phase 2.0 compatibility heuristic: existing imported
        // scenes may rely on normalized origins until we have fixture evidence
        // to replace this with exact WPE projection math.
        let xPx = (x >= 0 && x <= 1) ? x * canvas.width : x
        let yPx = (y >= 0 && y <= 1) ? y * canvas.height : y

        switch alignment {
        case .center:       return CGPoint(x: xPx, y: yPx)
        case .topLeft:      return CGPoint(x: xPx, y: canvas.height - yPx)
        case .topRight:     return CGPoint(x: canvas.width - xPx, y: canvas.height - yPx)
        case .bottomLeft:   return CGPoint(x: xPx, y: yPx)
        case .bottomRight:  return CGPoint(x: canvas.width - xPx, y: yPx)
        case .top:          return CGPoint(x: xPx, y: canvas.height - yPx)
        case .bottom:       return CGPoint(x: xPx, y: yPx)
        case .left:         return CGPoint(x: xPx, y: yPx)
        case .right:        return CGPoint(x: canvas.width - xPx, y: yPx)
        }
    }
}
