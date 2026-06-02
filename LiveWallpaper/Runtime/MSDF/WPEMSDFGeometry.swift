#if !LITE_BUILD
import CoreGraphics
import Foundation
import simd

enum WPEMSDFGeometryMath {
    static let epsilon = 1.0e-9

    static func dot(_ a: WPEMSDFPoint, _ b: WPEMSDFPoint) -> Double {
        a.x * b.x + a.y * b.y
    }

    static func cross(_ a: WPEMSDFPoint, _ b: WPEMSDFPoint) -> Double {
        a.x * b.y - a.y * b.x
    }

    static func length(_ value: WPEMSDFPoint) -> Double {
        sqrt(dot(value, value))
    }

    static func normalized(_ value: WPEMSDFPoint) -> WPEMSDFPoint {
        let len = length(value)
        guard len > epsilon else { return WPEMSDFPoint(0, 0) }
        return value / len
    }

    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    static func nonZeroSign(_ value: Double) -> Double {
        value > 0 ? 1.0 : -1.0
    }

    static func median(_ a: Double, _ b: Double, _ c: Double) -> Double {
        max(min(a, b), min(max(a, b), c))
    }

    static func lerp(_ a: WPEMSDFPoint, _ b: WPEMSDFPoint, _ t: Double) -> WPEMSDFPoint {
        a + (b - a) * t
    }
}

typealias WPEMSDFSignedDistance = (distance: Double, dot: Double)

enum WPEMSDFSegment {
    case linear(p0: WPEMSDFPoint, p1: WPEMSDFPoint, color: WPEMSDFEdgeColor)
    case quadratic(p0: WPEMSDFPoint, c: WPEMSDFPoint, p1: WPEMSDFPoint, color: WPEMSDFEdgeColor)
    case cubic(p0: WPEMSDFPoint, c0: WPEMSDFPoint, c1: WPEMSDFPoint, p1: WPEMSDFPoint, color: WPEMSDFEdgeColor)

    var color: WPEMSDFEdgeColor {
        get {
            switch self {
            case let .linear(_, _, color),
                 let .quadratic(_, _, _, color),
                 let .cubic(_, _, _, _, color):
                return color
            }
        }
        set {
            switch self {
            case let .linear(p0, p1, _):
                self = .linear(p0: p0, p1: p1, color: newValue)
            case let .quadratic(p0, c, p1, _):
                self = .quadratic(p0: p0, c: c, p1: p1, color: newValue)
            case let .cubic(p0, c0, c1, p1, _):
                self = .cubic(p0: p0, c0: c0, c1: c1, p1: p1, color: newValue)
            }
        }
    }

    var startPoint: WPEMSDFPoint {
        switch self {
        case let .linear(p0, _, _),
             let .quadratic(p0, _, _, _),
             let .cubic(p0, _, _, _, _):
            return p0
        }
    }

    var endPoint: WPEMSDFPoint {
        switch self {
        case let .linear(_, p1, _),
             let .quadratic(_, _, p1, _),
             let .cubic(_, _, _, p1, _):
            return p1
        }
    }

    var controlPoints: [WPEMSDFPoint] {
        switch self {
        case let .linear(p0, p1, _):
            return [p0, p1]
        case let .quadratic(p0, c, p1, _):
            return [p0, c, p1]
        case let .cubic(p0, c0, c1, p1, _):
            return [p0, c0, c1, p1]
        }
    }

    func point(at t: Double) -> WPEMSDFPoint {
        let t = WPEMSDFGeometryMath.clamp(t, 0, 1)
        let u = 1 - t
        switch self {
        case let .linear(p0, p1, _):
            return WPEMSDFGeometryMath.lerp(p0, p1, t)
        case let .quadratic(p0, c, p1, _):
            return p0 * (u * u) + c * (2 * u * t) + p1 * (t * t)
        case let .cubic(p0, c0, c1, p1, _):
            return p0 * (u * u * u) + c0 * (3 * u * u * t) + c1 * (3 * u * t * t) + p1 * (t * t * t)
        }
    }

    func direction(at t: Double) -> WPEMSDFPoint {
        let derivative = rawDerivative(at: t)
        let normalized = WPEMSDFGeometryMath.normalized(derivative)
        if WPEMSDFGeometryMath.length(normalized) > WPEMSDFGeometryMath.epsilon {
            return normalized
        }
        return WPEMSDFGeometryMath.normalized(endPoint - startPoint)
    }

    func signedDistance(to p: WPEMSDFPoint) -> (distance: WPEMSDFSignedDistance, t: Double) {
        let distanceT: Double
        let pseudoT: Double
        switch self {
        case let .linear(p0, p1, _):
            let edge = p1 - p0
            let denom = WPEMSDFGeometryMath.dot(edge, edge)
            let t = denom > WPEMSDFGeometryMath.epsilon
                ? WPEMSDFGeometryMath.dot(p - p0, edge) / denom
                : 0
            distanceT = WPEMSDFGeometryMath.clamp(t, 0, 1)
            pseudoT = t
        case .quadratic:
            let t = nearestParameter(to: p, samples: 16, refinementSteps: 4)
            distanceT = t
            pseudoT = pseudoDistanceParameter(nearest: t, origin: p)
        case .cubic:
            let t = nearestParameter(to: p, samples: 24, refinementSteps: 6)
            distanceT = t
            pseudoT = pseudoDistanceParameter(nearest: t, origin: p)
        }
        return (signedDistance(at: distanceT, to: p), pseudoT)
    }

    func distanceToPseudoDistance(_ sd: WPEMSDFSignedDistance, origin p: WPEMSDFPoint, t: Double) -> Double {
        let endpoint: WPEMSDFPoint
        let tangent: WPEMSDFPoint
        let isBeyondEndpoint: (Double) -> Bool

        if t < 0 {
            endpoint = point(at: 0)
            tangent = direction(at: 0)
            isBeyondEndpoint = { $0 < 0 }
        } else if t > 1 {
            endpoint = point(at: 1)
            tangent = direction(at: 1)
            isBeyondEndpoint = { $0 > 0 }
        } else {
            return sd.distance
        }

        let delta = p - endpoint
        let projection = WPEMSDFGeometryMath.dot(delta, tangent)
        guard isBeyondEndpoint(projection) else { return sd.distance }

        let pseudoDistance = WPEMSDFGeometryMath.cross(tangent, delta)
        return abs(pseudoDistance) <= abs(sd.distance) ? pseudoDistance : sd.distance
    }

    func split(at t: Double) -> (WPEMSDFSegment, WPEMSDFSegment) {
        let t = WPEMSDFGeometryMath.clamp(t, 0, 1)
        switch self {
        case let .linear(p0, p1, color):
            let p = WPEMSDFGeometryMath.lerp(p0, p1, t)
            return (
                .linear(p0: p0, p1: p, color: color),
                .linear(p0: p, p1: p1, color: color)
            )
        case let .quadratic(p0, c, p1, color):
            let p01 = WPEMSDFGeometryMath.lerp(p0, c, t)
            let p12 = WPEMSDFGeometryMath.lerp(c, p1, t)
            let p012 = WPEMSDFGeometryMath.lerp(p01, p12, t)
            return (
                .quadratic(p0: p0, c: p01, p1: p012, color: color),
                .quadratic(p0: p012, c: p12, p1: p1, color: color)
            )
        case let .cubic(p0, c0, c1, p1, color):
            let p01 = WPEMSDFGeometryMath.lerp(p0, c0, t)
            let p12 = WPEMSDFGeometryMath.lerp(c0, c1, t)
            let p23 = WPEMSDFGeometryMath.lerp(c1, p1, t)
            let p012 = WPEMSDFGeometryMath.lerp(p01, p12, t)
            let p123 = WPEMSDFGeometryMath.lerp(p12, p23, t)
            let p0123 = WPEMSDFGeometryMath.lerp(p012, p123, t)
            return (
                .cubic(p0: p0, c0: p01, c1: p012, p1: p0123, color: color),
                .cubic(p0: p0123, c0: p123, c1: p23, p1: p1, color: color)
            )
        }
    }

    func transformed(scale: Double, translate: WPEMSDFPoint) -> WPEMSDFSegment {
        func map(_ p: WPEMSDFPoint) -> WPEMSDFPoint { p * scale + translate }
        switch self {
        case let .linear(p0, p1, color):
            return .linear(p0: map(p0), p1: map(p1), color: color)
        case let .quadratic(p0, c, p1, color):
            return .quadratic(p0: map(p0), c: map(c), p1: map(p1), color: color)
        case let .cubic(p0, c0, c1, p1, color):
            return .cubic(p0: map(p0), c0: map(c0), c1: map(c1), p1: map(p1), color: color)
        }
    }

    private func rawDerivative(at t: Double) -> WPEMSDFPoint {
        let t = WPEMSDFGeometryMath.clamp(t, 0, 1)
        let u = 1 - t
        switch self {
        case let .linear(p0, p1, _):
            return p1 - p0
        case let .quadratic(p0, c, p1, _):
            return (c - p0) * (2 * u) + (p1 - c) * (2 * t)
        case let .cubic(p0, c0, c1, p1, _):
            return (c0 - p0) * (3 * u * u) + (c1 - c0) * (6 * u * t) + (p1 - c1) * (3 * t * t)
        }
    }

    private func rawSecondDerivative(at t: Double) -> WPEMSDFPoint {
        let t = WPEMSDFGeometryMath.clamp(t, 0, 1)
        switch self {
        case .linear:
            return WPEMSDFPoint(0, 0)
        case let .quadratic(p0, c, p1, _):
            return (p1 - c * 2 + p0) * 2
        case let .cubic(p0, c0, c1, p1, _):
            return (c1 - c0 * 2 + p0) * (6 * (1 - t)) + (p1 - c1 * 2 + c0) * (6 * t)
        }
    }

    private func nearestParameter(to p: WPEMSDFPoint, samples: Int, refinementSteps: Int) -> Double {
        var bestT = 0.0
        var bestDistance = Double.greatestFiniteMagnitude
        for i in 0...samples {
            let t = Double(i) / Double(samples)
            let delta = point(at: t) - p
            let d2 = WPEMSDFGeometryMath.dot(delta, delta)
            if d2 < bestDistance {
                bestDistance = d2
                bestT = t
            }
        }

        var t = bestT
        for _ in 0..<refinementSteps {
            let q = point(at: t)
            let d1 = rawDerivative(at: t)
            let d2 = rawSecondDerivative(at: t)
            let delta = q - p
            let numerator = WPEMSDFGeometryMath.dot(delta, d1)
            let denominator = WPEMSDFGeometryMath.dot(d1, d1) + WPEMSDFGeometryMath.dot(delta, d2)
            guard abs(denominator) > WPEMSDFGeometryMath.epsilon else { break }
            t = WPEMSDFGeometryMath.clamp(t - numerator / denominator, 0, 1)
        }
        return t
    }

    private func pseudoDistanceParameter(nearest t: Double, origin p: WPEMSDFPoint) -> Double {
        if t <= WPEMSDFGeometryMath.epsilon {
            let projection = WPEMSDFGeometryMath.dot(p - point(at: 0), direction(at: 0))
            if projection < 0 { return -1 }
        } else if t >= 1 - WPEMSDFGeometryMath.epsilon {
            let projection = WPEMSDFGeometryMath.dot(p - point(at: 1), direction(at: 1))
            if projection > 0 { return 2 }
        }
        return t
    }

    private func signedDistance(at t: Double, to p: WPEMSDFPoint) -> WPEMSDFSignedDistance {
        let q = point(at: t)
        let delta = p - q
        let magnitude = WPEMSDFGeometryMath.length(delta)
        let tangent = direction(at: t)
        let sign = WPEMSDFGeometryMath.nonZeroSign(WPEMSDFGeometryMath.cross(tangent, delta))
        let dot = magnitude > WPEMSDFGeometryMath.epsilon
            ? abs(WPEMSDFGeometryMath.dot(delta / magnitude, tangent))
            : 0
        return (distance: sign * magnitude, dot: dot)
    }
}

struct WPEMSDFContour {
    var segments: [WPEMSDFSegment]
}

struct WPEMSDFShape {
    var contours: [WPEMSDFContour]

    private struct EdgeDistance {
        let signedDistance: WPEMSDFSignedDistance
        let pseudoDistance: Double
    }

    func bounds() -> CGRect {
        var hasPoint = false
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude

        for contour in contours {
            for segment in contour.segments {
                for point in segment.controlPoints {
                    hasPoint = true
                    minX = min(minX, point.x)
                    minY = min(minY, point.y)
                    maxX = max(maxX, point.x)
                    maxY = max(maxY, point.y)
                }
            }
        }

        guard hasPoint else { return .null }
        return CGRect(
            x: CGFloat(minX),
            y: CGFloat(minY),
            width: CGFloat(maxX - minX),
            height: CGFloat(maxY - minY)
        )
    }

    mutating func applyTransform(scale: Double, translate: WPEMSDFPoint) {
        for contourIndex in contours.indices {
            for segmentIndex in contours[contourIndex].segments.indices {
                contours[contourIndex].segments[segmentIndex] = contours[contourIndex].segments[segmentIndex].transformed(
                    scale: scale,
                    translate: translate
                )
            }
        }
    }

    func signedDistance(at point: WPEMSDFPoint, channel: WPEMSDFEdgeColor) -> Double {
        let distances = signedDistances(at: point)
        switch channel {
        case .red:
            return distances.r
        case .green:
            return distances.g
        case .blue:
            return distances.b
        default:
            return WPEMSDFGeometryMath.median(distances.r, distances.g, distances.b)
        }
    }

    /// Per-channel signed pseudo-distances for one pixel (msdfgen semantics):
    /// pick each channel's nearest same-color edge, take that edge's signed
    /// pseudo-distance, then correct the overall sign against the winding number
    /// so glyph fill can never invert regardless of contour orientation.
    func signedDistances(at point: WPEMSDFPoint) -> (r: Double, g: Double, b: Double) {
        let distances = closestDistances(at: point)
        func value(_ candidate: EdgeDistance?) -> Double {
            (candidate ?? distances.any)?.pseudoDistance ?? 0
        }

        var r = value(distances.red)
        var g = value(distances.green)
        var b = value(distances.blue)
        let insideSign = windingNumber(at: point) == 0 ? -1.0 : 1.0
        let median = WPEMSDFGeometryMath.median(r, g, b)
        if WPEMSDFGeometryMath.nonZeroSign(median) != insideSign {
            r = -r
            g = -g
            b = -b
        }
        return (r, g, b)
    }

    private func closestDistances(
        at point: WPEMSDFPoint
    ) -> (red: EdgeDistance?, green: EdgeDistance?, blue: EdgeDistance?, any: EdgeDistance?) {
        var red: EdgeDistance?
        var green: EdgeDistance?
        var blue: EdgeDistance?
        var any: EdgeDistance?

        func update(_ current: inout EdgeDistance?, with candidate: EdgeDistance) {
            if isBetter(candidate.signedDistance, than: current?.signedDistance) {
                current = candidate
            }
        }

        for contour in contours {
            for segment in contour.segments {
                let distance = segment.signedDistance(to: point)
                let candidate = EdgeDistance(
                    signedDistance: distance.distance,
                    pseudoDistance: segment.distanceToPseudoDistance(distance.distance, origin: point, t: distance.t)
                )
                update(&any, with: candidate)
                if segment.color.contains(.red) { update(&red, with: candidate) }
                if segment.color.contains(.green) { update(&green, with: candidate) }
                if segment.color.contains(.blue) { update(&blue, with: candidate) }
            }
        }
        return (red, green, blue, any)
    }

    private func isBetter(
        _ candidate: WPEMSDFSignedDistance,
        than current: WPEMSDFSignedDistance?
    ) -> Bool {
        guard let current else { return true }
        let candidateDistance = abs(candidate.distance)
        let currentDistance = abs(current.distance)
        if abs(candidateDistance - currentDistance) > 1.0e-7 {
            return candidateDistance < currentDistance
        }
        return candidate.dot < current.dot
    }

    private func windingNumber(at point: WPEMSDFPoint) -> Int {
        var winding = 0
        for contour in contours {
            for segment in contour.segments {
                let steps = flattenedStepCount(for: segment)
                var previous = segment.point(at: 0)
                for step in 1...steps {
                    let t = Double(step) / Double(steps)
                    let current = segment.point(at: t)
                    addWindingEdge(from: previous, to: current, point: point, winding: &winding)
                    previous = current
                }
            }
        }
        return winding
    }

    private func flattenedStepCount(for segment: WPEMSDFSegment) -> Int {
        switch segment {
        case .linear:
            return 1
        case .quadratic:
            return 12
        case .cubic:
            return 24
        }
    }

    private func addWindingEdge(
        from a: WPEMSDFPoint,
        to b: WPEMSDFPoint,
        point: WPEMSDFPoint,
        winding: inout Int
    ) {
        guard WPEMSDFGeometryMath.length(b - a) > WPEMSDFGeometryMath.epsilon else { return }
        if a.y <= point.y {
            if b.y > point.y && WPEMSDFGeometryMath.cross(b - a, point - a) > 0 {
                winding += 1
            }
        } else if b.y <= point.y && WPEMSDFGeometryMath.cross(b - a, point - a) < 0 {
            winding -= 1
        }
    }
}
#endif
