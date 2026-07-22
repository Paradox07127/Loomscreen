import Foundation
import Combine
import LiveWallpaperCore

// MARK: - Widget-facing contract (orchestrator-owned)

struct MonitorWidgetContext {
    var snapshot: MonitorSnapshot
    var history: MonitorHistorySnapshot
    var placement: MonitorWidgetPlacement
    var isEditing: Bool
    var reduceMotion: Bool
    var now: Date
}

#if DEBUG
extension MonitorWidgetContext {
    /// A copy with `now` replaced — lets an isolated `#Preview` wrap a widget in its own TimelineView and feed the ticking date through the normal `context.now` channel (the board does this in production).
    func at(_ date: Date) -> MonitorWidgetContext {
        var copy = self
        copy.now = date
        return copy
    }
}
#endif

struct MonitorHistorySnapshot: Sendable, Equatable {
    var sampleTimes: [Double] = []
    var cpuTotal: [Double] = []
    var cpuUser: [Double] = []
    var cpuSystem: [Double] = []
    var memUsedFraction: [Double] = []
    /// Pressure level aligned with `memUsedFraction` — the memory curve is
    /// colored by discrete pressure segments, not by used%.
    var memPressure: [String] = []
    /// Per-category fractions (of total RAM) aligned with `memUsedFraction`, so the Memory history can stack app/wired/compressed as colored bands.
    var memAppFraction: [Double] = []
    var memWiredFraction: [Double] = []
    var memCompressedFraction: [Double] = []
    /// GPU keeps its own timeline: it samples ~6s, so aligning it with the
    /// 1Hz series would fabricate readings between real samples.
    var gpuSampleTimes: [Double] = []
    var gpuDevice: [Double] = []
    /// Aligned with `gpuSampleTimes`; nil where that sample lacked the key.
    var gpuRenderer: [Double?] = []
    var gpuTiler: [Double?] = []
    var netRx: [Double] = []
    var netTx: [Double] = []
    var diskRead: [Double] = []
    var diskWrite: [Double] = []

    var cpuPeak: Double = 0
    var gpuPeak: Double = 0
    var netRxPeak: Double = 0
    var netTxPeak: Double = 0
    var diskReadPeak: Double = 0
    var diskWritePeak: Double = 0

    var netRxSessionBytes: Double = 0
    var netTxSessionBytes: Double = 0
    var diskReadSessionBytes: Double = 0
    var diskWriteSessionBytes: Double = 0

    /// 5h-quota used% observations (own sparse timeline — statusline captures
    /// refresh slowly). Fuel for the burn-ETA slope; ≥2 samples required.
    var usageQuotaTimes: [Double] = []
    var usageFiveHourUsed: [Double] = []
}

@MainActor
final class MonitorHistoryStore: ObservableObject {
    @Published private(set) var current = MonitorHistorySnapshot()

    private let capacity: Int
    private var lastSampleAt: Double?
    private var lastGPUSampleAt: Double?

    init(capacity: Int = 120) {
        self.capacity = max(capacity, 2)
    }

    func reset() {
        current = MonitorHistorySnapshot()
        lastSampleAt = nil
        lastGPUSampleAt = nil
    }

    func ingest(_ snapshot: MonitorSnapshot) {
        let t = snapshot.timestamp > 0 ? snapshot.timestamp : Date().timeIntervalSince1970
        var next = current
        var quotaChanged = false
        if let pct = snapshot.usage?.fiveHourUsedPercent, snapshot.usage?.limitsStale != true,
           next.usageFiveHourUsed.last != pct {
            next.usageQuotaTimes.append(t)
            next.usageFiveHourUsed.append(pct)
            trim(&next.usageQuotaTimes)
            trim(&next.usageFiveHourUsed)
            quotaChanged = true
        }
        guard let sys = snapshot.system else {
            if quotaChanged { current = next }
            return
        }
        if let last = lastSampleAt, t <= last {
            if quotaChanged { current = next }
            return
        }
        let dt = lastSampleAt.map { min(max(t - $0, 0), 10) } ?? 0
        lastSampleAt = t
        next.sampleTimes.append(t)
        next.cpuTotal.append(sys.cpuTotal)
        next.cpuUser.append(sys.cpuUser)
        next.cpuSystem.append(sys.cpuSystem)
        let memFraction = sys.memTotalBytes > 0
            ? Double(sys.memUsedBytes) / Double(sys.memTotalBytes) : 0
        next.memUsedFraction.append(memFraction)
        next.memPressure.append(sys.memPressure)
        let total = Double(sys.memTotalBytes)
        let breakdown = sys.memBreakdown
        next.memAppFraction.append(total > 0 ? Double(breakdown?.appBytes ?? 0) / total : 0)
        next.memWiredFraction.append(total > 0 ? Double(breakdown?.wiredBytes ?? 0) / total : 0)
        next.memCompressedFraction.append(total > 0 ? Double(breakdown?.compressedBytes ?? 0) / total : 0)
        next.netRx.append(sys.netRxBytesPerSec)
        next.netTx.append(sys.netTxBytesPerSec)
        next.diskRead.append(sys.diskReadBytesPerSec)
        next.diskWrite.append(sys.diskWriteBytesPerSec)

        if let gpu = sys.gpuUsage {
            let gpuAt = sys.gpuSampledAt ?? t
            if lastGPUSampleAt != gpuAt {
                lastGPUSampleAt = gpuAt
                next.gpuSampleTimes.append(gpuAt)
                next.gpuDevice.append(gpu)
                next.gpuRenderer.append(sys.gpuRendererUtil)
                next.gpuTiler.append(sys.gpuTilerUtil)
                trim(&next.gpuSampleTimes)
                trim(&next.gpuDevice)
                trim(&next.gpuRenderer)
                trim(&next.gpuTiler)
            }
        }

        trim(&next.sampleTimes)
        trim(&next.cpuTotal)
        trim(&next.cpuUser)
        trim(&next.cpuSystem)
        trim(&next.memUsedFraction)
        trim(&next.memPressure)
        trim(&next.memAppFraction)
        trim(&next.memWiredFraction)
        trim(&next.memCompressedFraction)
        trim(&next.netRx)
        trim(&next.netTx)
        trim(&next.diskRead)
        trim(&next.diskWrite)

        next.cpuPeak = next.cpuTotal.max() ?? 0
        next.gpuPeak = next.gpuDevice.max() ?? 0
        next.netRxPeak = next.netRx.max() ?? 0
        next.netTxPeak = next.netTx.max() ?? 0
        next.diskReadPeak = next.diskRead.max() ?? 0
        next.diskWritePeak = next.diskWrite.max() ?? 0

        next.netRxSessionBytes += sys.netRxBytesPerSec * dt
        next.netTxSessionBytes += sys.netTxBytesPerSec * dt
        next.diskReadSessionBytes += sys.diskReadBytesPerSec * dt
        next.diskWriteSessionBytes += sys.diskWriteBytesPerSec * dt

        current = next
    }

    private func trim<T>(_ array: inout [T]) {
        if array.count > capacity {
            array.removeFirst(array.count - capacity)
        }
    }
}
