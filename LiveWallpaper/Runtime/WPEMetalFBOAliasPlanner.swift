#if !LITE_BUILD
import Foundation

/// Computes a memory-aliasing layout for render-target (FBO) textures: assigns
/// each one an OFFSET in a single shared heap such that targets whose
/// within-frame lifetimes do NOT overlap may share the same memory, while
/// targets that ARE alive at the same time never overlap in memory.
///
/// This is the algorithmic core of placement-heap FBO aliasing (the lever that
/// turns "sum of every FBO" into "≈ peak concurrent"). It is pure + value-typed
/// so the packing is unit-testable in isolation, BEFORE any GPU heap is wired
/// up. The GPU step (allocating the heap + placing textures + hazard fences)
/// consumes `Plan.heapSize` and `Placement.offset`.
///
/// Algorithm: a classic time-ordered offset allocator. Intervals are placed in
/// start order (largest first on ties); each is given the lowest offset whose
/// memory range is free for the whole of its lifetime (i.e. doesn't collide
/// with any concurrently-alive, already-placed interval). Greedy first-fit —
/// near-optimal for these cascade-shaped lifetimes and always correct (it never
/// overlaps two simultaneously-live targets).
enum WPEMetalFBOAliasPlanner {
    /// A render target's memory request + its inclusive within-frame lifetime
    /// `[firstPass, lastPass]` (pass indices in the flattened render order).
    struct Interval: Equatable {
        let id: Int
        let size: Int
        let firstPass: Int
        let lastPass: Int
    }

    struct Placement: Equatable {
        let id: Int
        let offset: Int
        let size: Int
    }

    struct Plan: Equatable {
        let placements: [Placement]
        let heapSize: Int
    }

    /// `alignment` rounds each offset up so placed textures meet the heap's
    /// allocation alignment (the GPU step passes the device's real value;
    /// tests/estimates can pass 1).
    static func plan(_ intervals: [Interval], alignment: Int = 1) -> Plan {
        let align = max(alignment, 1)
        let ordered = intervals.sorted {
            $0.firstPass != $1.firstPass ? $0.firstPass < $1.firstPass : $0.size > $1.size
        }

        var placements: [Placement] = []
        placements.reserveCapacity(ordered.count)
        var heapSize = 0

        for interval in ordered {
            // Ranges occupied by intervals alive at the same time as this one.
            let conflicts = placements
                .filter { placed in
                    guard let placedInterval = ordered.first(where: { $0.id == placed.id }) else { return false }
                    return placedInterval.firstPass <= interval.lastPass
                        && interval.firstPass <= placedInterval.lastPass
                }
                .map { (start: $0.offset, end: $0.offset + $0.size) }
                .sorted { $0.start < $1.start }

            // Lowest aligned offset whose [offset, offset+size) clears every
            // conflicting range.
            var offset = 0
            for range in conflicts {
                if offset + interval.size <= range.start {
                    break // fits in the gap before this conflict
                }
                offset = max(offset, roundUp(range.end, to: align))
            }

            placements.append(Placement(id: interval.id, offset: offset, size: interval.size))
            heapSize = max(heapSize, offset + interval.size)
        }

        return Plan(
            placements: placements.sorted { $0.id < $1.id },
            heapSize: heapSize
        )
    }

    private static func roundUp(_ value: Int, to alignment: Int) -> Int {
        guard alignment > 1 else { return value }
        let remainder = value % alignment
        return remainder == 0 ? value : value + (alignment - remainder)
    }
}
#endif
