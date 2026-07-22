import CoreGraphics
import Testing
@testable import LiveWallpaperCore

@MainActor
@Suite("FullScreenDetector window-union occlusion")
struct FullScreenOcclusionTests {

    @Test("Empty / degenerate inputs are zero area")
    func emptyIsZero() {
        #expect(FullScreenDetector.unionArea(of: []) == 0)
        #expect(FullScreenDetector.unionArea(of: [CGRect(x: 0, y: 0, width: 0, height: 100)]) == 0)
    }

    @Test("Disjoint rectangles sum their areas")
    func disjointSums() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 200, y: 200, width: 50, height: 50)
        #expect(FullScreenDetector.unionArea(of: [a, b]) == 12_500)
    }

    @Test("Overlapping rectangles count the overlap once")
    func overlapCountedOnce() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 50, y: 0, width: 100, height: 100)
        #expect(FullScreenDetector.unionArea(of: [a, b]) == 15_000)
    }

    @Test("A fully-contained rectangle adds nothing")
    func containedAddsNothing() {
        let big = CGRect(x: 0, y: 0, width: 100, height: 100)
        let small = CGRect(x: 10, y: 10, width: 20, height: 20)
        #expect(FullScreenDetector.unionArea(of: [big, small]) == 10_000)
    }

    @Test("Tiled windows reach the 85% threshold by union, not by any single window")
    func tiledReaches85Percent() {
        let screenArea: CGFloat = 1_000_000
        let tiles = [
            CGRect(x: 0, y: 0, width: 500, height: 450),
            CGRect(x: 500, y: 0, width: 500, height: 450),
            CGRect(x: 0, y: 550, width: 500, height: 450),
            CGRect(x: 500, y: 550, width: 500, height: 450),
        ]
        let union = FullScreenDetector.unionArea(of: tiles)
        #expect(union == 900_000)
        #expect(union >= screenArea * 0.85)
        #expect(tiles.allSatisfy { ($0.width * $0.height) < screenArea * 0.85 })
    }
}
