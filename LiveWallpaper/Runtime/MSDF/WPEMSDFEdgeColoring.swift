#if !LITE_BUILD
import Foundation

enum WPEMSDFEdgeColoring {
    private static let palette: [WPEMSDFEdgeColor] = [.yellow, .cyan, .magenta]

    static func colorShape(_ shape: inout WPEMSDFShape, angleThreshold: Double) {
        let threshold = max(angleThreshold, 0)
        for contourIndex in shape.contours.indices {
            colorContour(&shape.contours[contourIndex], angleThreshold: threshold)
        }
    }

    private static func colorContour(_ contour: inout WPEMSDFContour, angleThreshold: Double) {
        guard !contour.segments.isEmpty else { return }

        var corners = cornerIndices(in: contour, angleThreshold: angleThreshold)
        guard !corners.isEmpty else {
            setAllSegments(in: &contour, to: .white)
            return
        }

        if contour.segments.count == 1 {
            contour.segments = splitIntoThirds(contour.segments[0])
            corners = cornerIndices(in: contour, angleThreshold: angleThreshold)
            if corners.isEmpty { corners = [0] }
        } else if contour.segments.count == 2 {
            contour.segments = contour.segments.flatMap { segment -> [WPEMSDFSegment] in
                let halves = segment.split(at: 0.5)
                return [halves.0, halves.1]
            }
            corners = cornerIndices(in: contour, angleThreshold: angleThreshold)
            if corners.isEmpty { corners = [0, contour.segments.count / 2] }
        }

        if corners.count == 1 {
            colorSingleCornerContour(&contour, corner: corners[0])
            return
        }

        let colors = colorsForCornerCount(corners.count)
        for offset in corners.indices {
            let start = corners[offset]
            let end = corners[(offset + 1) % corners.count]
            assignSpan(in: &contour, start: start, end: end, color: colors[offset])
        }
    }

    private static func cornerIndices(in contour: WPEMSDFContour, angleThreshold: Double) -> [Int] {
        let count = contour.segments.count
        guard count > 0 else { return [] }
        var indices: [Int] = []
        for index in 0..<count {
            let previous = contour.segments[(index + count - 1) % count]
            let current = contour.segments[index]
            if cornerAngle(previous: previous, current: current) > angleThreshold {
                indices.append(index)
            }
        }
        return indices
    }

    private static func cornerAngle(previous: WPEMSDFSegment, current: WPEMSDFSegment) -> Double {
        let a = previous.direction(at: 1)
        let b = current.direction(at: 0)
        guard WPEMSDFGeometryMath.length(a) > WPEMSDFGeometryMath.epsilon,
              WPEMSDFGeometryMath.length(b) > WPEMSDFGeometryMath.epsilon else {
            return 0
        }
        let dot = WPEMSDFGeometryMath.clamp(WPEMSDFGeometryMath.dot(a, b), -1, 1)
        return acos(dot)
    }

    private static func splitIntoThirds(_ segment: WPEMSDFSegment) -> [WPEMSDFSegment] {
        let firstSplit = segment.split(at: 1.0 / 3.0)
        let secondSplit = firstSplit.1.split(at: 0.5)
        return [firstSplit.0, secondSplit.0, secondSplit.1]
    }

    private static func colorSingleCornerContour(_ contour: inout WPEMSDFContour, corner: Int) {
        let count = contour.segments.count
        guard count > 0 else { return }
        for offset in 0..<count {
            let colorIndex = min(offset * palette.count / count, palette.count - 1)
            let index = (corner + offset) % count
            contour.segments[index].color = palette[colorIndex]
        }
    }

    private static func colorsForCornerCount(_ count: Int) -> [WPEMSDFEdgeColor] {
        guard count > 0 else { return [] }
        var colors = (0..<count).map { palette[$0 % palette.count] }
        if count > 1, colors.last == colors.first {
            colors[colors.count - 1] = .cyan
        }
        return colors
    }

    private static func assignSpan(
        in contour: inout WPEMSDFContour,
        start: Int,
        end: Int,
        color: WPEMSDFEdgeColor
    ) {
        let count = contour.segments.count
        guard count > 0 else { return }
        var index = start
        while true {
            contour.segments[index].color = color
            index = (index + 1) % count
            if index == end { break }
        }
    }

    private static func setAllSegments(in contour: inout WPEMSDFContour, to color: WPEMSDFEdgeColor) {
        for index in contour.segments.indices {
            contour.segments[index].color = color
        }
    }
}
#endif
