import Testing
@testable import LiveWallpaper

struct WPEMetalFBOAliasPlannerTests {
    private typealias Planner = WPEMetalFBOAliasPlanner
    private typealias Interval = WPEMetalFBOAliasPlanner.Interval

    /// The safety invariant: any two intervals whose lifetimes overlap MUST get
    /// disjoint memory ranges. A violation here would be on-screen corruption.
    private func assertNoLiveOverlap(_ plan: Planner.Plan, _ intervals: [Interval], sourceLocation: SourceLocation = #_sourceLocation) {
        let byID = Dictionary(uniqueKeysWithValues: intervals.map { ($0.id, $0) })
        for a in plan.placements {
            for b in plan.placements where a.id < b.id {
                guard let ia = byID[a.id], let ib = byID[b.id] else { continue }
                let lifetimesOverlap = ia.firstPass <= ib.lastPass && ib.firstPass <= ia.lastPass
                guard lifetimesOverlap else { continue }
                let memoryOverlap = a.offset < b.offset + b.size && b.offset < a.offset + a.size
                #expect(!memoryOverlap, "ids \(a.id)/\(b.id) are alive together but share memory", sourceLocation: sourceLocation)
            }
        }
    }

    @Test("Non-overlapping cascade fully aliases into one slot")
    func cascadeShares() {
        let intervals = [
            Interval(id: 0, size: 100, firstPass: 0, lastPass: 1),
            Interval(id: 1, size: 100, firstPass: 2, lastPass: 3),
            Interval(id: 2, size: 100, firstPass: 4, lastPass: 5)
        ]
        let plan = Planner.plan(intervals)
        #expect(plan.heapSize == 100)
        #expect(plan.placements.allSatisfy { $0.offset == 0 })
        assertNoLiveOverlap(plan, intervals)
    }

    @Test("Fully concurrent intervals never share memory")
    func concurrentNeverShares() {
        let intervals = (0..<3).map { Interval(id: $0, size: 100, firstPass: 0, lastPass: 5) }
        let plan = Planner.plan(intervals)
        #expect(plan.heapSize == 300)
        #expect(Set(plan.placements.map(\.offset)) == [0, 100, 200])
        assertNoLiveOverlap(plan, intervals)
    }

    @Test("Mixed lifetimes: non-overlapping pair shares, overlapping one is separate")
    func mixedSharing() {
        let intervals = [
            Interval(id: 0, size: 100, firstPass: 0, lastPass: 1),
            Interval(id: 1, size: 100, firstPass: 2, lastPass: 3),
            Interval(id: 2, size: 100, firstPass: 1, lastPass: 2)
        ]
        let plan = Planner.plan(intervals)
        // 0 and 1 don't overlap → share offset 0; 2 overlaps both → offset 100.
        #expect(plan.heapSize == 200)
        let offsets = Dictionary(uniqueKeysWithValues: plan.placements.map { ($0.id, $0.offset) })
        #expect(offsets[0] == 0)
        #expect(offsets[1] == 0)
        #expect(offsets[2] == 100)
        assertNoLiveOverlap(plan, intervals)
    }

    @Test("Heap size never exceeds the sum and never undercuts the concurrent peak")
    func boundsAreSane() {
        let intervals = [
            Interval(id: 0, size: 320, firstPass: 0, lastPass: 2),
            Interval(id: 1, size: 64, firstPass: 1, lastPass: 4),
            Interval(id: 2, size: 320, firstPass: 3, lastPass: 5),
            Interval(id: 3, size: 16, firstPass: 5, lastPass: 6)
        ]
        let plan = Planner.plan(intervals)
        let sum = intervals.reduce(0) { $0 + $1.size }
        // Peak concurrency: passes 1..2 hold id0(320)+id1(64) = 384.
        #expect(plan.heapSize >= 384)
        #expect(plan.heapSize <= sum)
        assertNoLiveOverlap(plan, intervals)
    }

    @Test("Offsets honor alignment")
    func alignmentRespected() {
        let intervals = [
            Interval(id: 0, size: 100, firstPass: 0, lastPass: 1),
            Interval(id: 1, size: 100, firstPass: 0, lastPass: 1)
        ]
        let plan = Planner.plan(intervals, alignment: 64)
        let offsets = plan.placements.map(\.offset).sorted()
        #expect(offsets == [0, 128]) // second rounded up from 100 to 128
        #expect(plan.placements.allSatisfy { $0.offset % 64 == 0 })
        assertNoLiveOverlap(plan, intervals)
    }

    @Test("Empty input yields an empty plan")
    func emptyInput() {
        let plan = Planner.plan([])
        #expect(plan.placements.isEmpty)
        #expect(plan.heapSize == 0)
    }
}
