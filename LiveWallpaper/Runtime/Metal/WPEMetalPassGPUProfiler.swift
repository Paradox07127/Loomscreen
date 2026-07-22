#if !LITE_BUILD
    import Foundation
    import LiveWallpaperCore
    import Metal
    import os

    #if DEBUG
        /// Per-pass GPU timing via stage-boundary counter sampling. DEBUG-only, opt-in:
        /// `defaults write Taijia.LiveWallpaper WPEPassGPUProfileEnabled -bool YES`.
        /// Ranks render passes by GPU cost (CSV in Caches/WPEPassGPUProfile/) to pick
        /// pass-merge candidates. Apple GPUs only expose stage-boundary sampling, and
        /// TBDR overlaps vertex/fragment stages across passes — per-pass durations rank
        /// cost but must NOT be summed into a frame time (see the CSV header note).
        final class WPEMetalPassGPUProfiler: @unchecked Sendable {
            private struct Stat {
                var count = 0
                var totalSeconds = 0.0
                var maxSeconds = 0.0
            }

            /// Samples attached to one command buffer; resolved in its completion handler.
            private final class Session {
                var buffers: [MTLCounterSampleBuffer] = []
                var entries: [(label: String, buffer: Int, index: Int)] = []
                var cursor = 0
            }

            private let device: MTLDevice
            private let counterSet: MTLCounterSet
            private let lock = NSLock()
            private var sessions: [ObjectIdentifier: Session] = [:]
            private var stats: [String: Stat] = [:]
            private var cbTotalSeconds = 0.0
            private var cbCount = 0
            private var sessionsSinceReport = 0
            private var currentSceneID: String?
            /// Preferred sample-buffer capacity; lowered on first allocation failure so
            /// devices with a small per-buffer cap chain several small buffers instead.
            private var bufferCapacity = 256
            private let instance: Int
            let reportEverySessions: Int
            let reportDirectory: URL

            static func makeIfEnabled(device: MTLDevice) -> WPEMetalPassGPUProfiler? {
                guard defaultsFlag("WPEPassGPUProfileEnabled") else { return nil }
                guard device.supportsCounterSampling(.atStageBoundary),
                      let counterSet = device.counterSets?.first(where: {
                          $0.name == MTLCommonCounterSet.timestamp.rawValue
                      }) else {
                    Logger.warning(
                        "[WPE pass-gpu-profile] no stage-boundary timestamp sampling on this device — disabled",
                        category: .wpeRender
                    )
                    return nil
                }
                let profiler = WPEMetalPassGPUProfiler(device: device, counterSet: counterSet)
                guard profiler.selfTest() else {
                    Logger.warning(
                        "[WPE pass-gpu-profile] self-test failed (encoder rejected sample attachment) — disabled",
                        category: .wpeRender
                    )
                    return nil
                }
                Logger.notice(
                    "[WPE pass-gpu-profile] enabled — CSV every \(profiler.reportEverySessions) command buffers → \(profiler.reportDirectory.path)",
                    category: .wpeRender
                )
                return profiler
            }

            private static func defaultsFlag(_ key: String) -> Bool {
                for suite in [UserDefaults.appSuite, UserDefaults.standard] where suite.object(forKey: key) != nil {
                    return suite.bool(forKey: key)
                }
                return false
            }

            private init(device: MTLDevice, counterSet: MTLCounterSet) {
                self.device = device
                self.counterSet = counterSet
                instance = Self.nextInstance()
                let raw = UserDefaults.appSuite.integer(forKey: "WPEPassGPUProfileReportEvery")
                reportEverySessions = raw > 0 ? raw : 900
                reportDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("WPEPassGPUProfile", isDirectory: true)
            }

            private static let instanceCounter = OSAllocatedUnfairLock(initialState: 0)
            private static func nextInstance() -> Int {
                instanceCounter.withLock { count in
                    count += 1
                    return count
                }
            }

            /// Flush + reset when the scene changes so one CSV never mixes two scenes.
            func noteScene(_ sceneID: String?) {
                lock.lock()
                defer { lock.unlock() }
                guard sceneID != currentSceneID else { return }
                if !stats.isEmpty {
                    writeReportLocked()
                }
                stats.removeAll()
                cbTotalSeconds = 0
                cbCount = 0
                sessionsSinceReport = 0
                currentSceneID = sceneID
            }

            /// Attach timestamp sampling to a render pass. Safe to call for every pass;
            /// silently skips the pass when a sample buffer can't be allocated. The
            /// first attach on a command buffer registers the resolve handler, so no
            /// explicit begin/commit calls are needed at the call sites.
            func attach(_ descriptor: MTLRenderPassDescriptor, to commandBuffer: MTLCommandBuffer, label: String) {
                lock.lock()
                defer { lock.unlock() }
                let key = ObjectIdentifier(commandBuffer)
                let session: Session
                if let existing = sessions[key] {
                    session = existing
                } else {
                    session = Session()
                    sessions[key] = session
                    commandBuffer.addCompletedHandler { [weak self] completed in
                        self?.finish(key: ObjectIdentifier(completed), commandBuffer: completed)
                    }
                }
                if session.buffers.isEmpty || session.cursor + 4 > session.buffers[session.buffers.count - 1].sampleCount {
                    guard let buffer = makeSampleBuffer() else { return }
                    session.buffers.append(buffer)
                    session.cursor = 0
                }
                let base = session.cursor
                session.cursor += 4
                let attachment = descriptor.sampleBufferAttachments[0]!
                attachment.sampleBuffer = session.buffers[session.buffers.count - 1]
                attachment.startOfVertexSampleIndex = base
                attachment.endOfVertexSampleIndex = base + 1
                attachment.startOfFragmentSampleIndex = base + 2
                attachment.endOfFragmentSampleIndex = base + 3
                session.entries.append((label, session.buffers.count - 1, base))
            }

            private func makeSampleBuffer() -> MTLCounterSampleBuffer? {
                for capacity in [bufferCapacity, 64, 32] where capacity <= bufferCapacity {
                    let descriptor = MTLCounterSampleBufferDescriptor()
                    descriptor.counterSet = counterSet
                    descriptor.storageMode = .shared
                    descriptor.sampleCount = capacity
                    descriptor.label = "WPE pass GPU profile"
                    if let buffer = try? device.makeCounterSampleBuffer(descriptor: descriptor) {
                        bufferCapacity = capacity
                        return buffer
                    }
                }
                return nil
            }

            private func finish(key: ObjectIdentifier, commandBuffer: MTLCommandBuffer) {
                lock.lock()
                defer { lock.unlock() }
                guard let session = sessions.removeValue(forKey: key) else { return }
                let resolved: [[MTLCounterResultTimestamp]] = session.buffers.map { buffer in
                    guard let data = (try? buffer.resolveCounterRange(0 ..< buffer.sampleCount)) ?? nil else { return [] }
                    return data.withUnsafeBytes { Array($0.bindMemory(to: MTLCounterResultTimestamp.self)) }
                }
                var durations: [(label: String, ticks: UInt64)] = []
                var minStart = UInt64.max
                var maxEnd = UInt64.min
                for entry in session.entries {
                    let samples = resolved[entry.buffer]
                    guard entry.index + 3 < samples.count else { continue }
                    // Unresolvable samples come back as MTLCounterErrorValue (all-ones),
                    // and 0 means "never sampled" — drop both, keep whatever remains.
                    let valid = (0 ... 3)
                        .map { samples[entry.index + $0].timestamp }
                        .filter { $0 != 0 && $0 != .max }
                    guard let start = valid.min(), let end = valid.max(), end > start else { continue }
                    durations.append((entry.label, end - start))
                    minStart = min(minStart, start)
                    maxEnd = max(maxEnd, end)
                }
                // Convert GPU ticks to seconds by calibrating against this command
                // buffer's own wall-clock GPU span — no assumption about tick units.
                let cbSeconds = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
                guard maxEnd > minStart, cbSeconds > 0 else { return }
                let secondsPerTick = cbSeconds / Double(maxEnd - minStart)
                for item in durations {
                    let seconds = Double(item.ticks) * secondsPerTick
                    var stat = stats[item.label] ?? Stat()
                    stat.count += 1
                    stat.totalSeconds += seconds
                    stat.maxSeconds = max(stat.maxSeconds, seconds)
                    stats[item.label] = stat
                }
                cbTotalSeconds += cbSeconds
                cbCount += 1
                sessionsSinceReport += 1
                if sessionsSinceReport >= reportEverySessions {
                    sessionsSinceReport = 0
                    writeReportLocked()
                }
            }

            private func writeReportLocked() {
                let rows = stats.sorted { $0.value.totalSeconds > $1.value.totalSeconds }
                let attributedTotal = rows.reduce(0) { $0 + $1.value.totalSeconds }
                guard attributedTotal > 0 else { return }
                let scene = currentSceneID ?? "-"
                var csv = "# scene=\(scene) commandBuffers=\(cbCount) cbTotal_s=\(String(format: "%.3f", cbTotalSeconds))"
                    + " attributed_s=\(String(format: "%.3f", attributedTotal))"
                    + " — TBDR overlaps pass stages: rank by these numbers, do not sum them into a frame time\n"
                csv += "label,count,avg_ms,max_ms,total_s,share_pct\n"
                for (label, stat) in rows {
                    let avgMs = stat.totalSeconds / Double(max(stat.count, 1)) * 1000
                    csv += "\(label),\(stat.count)"
                        + ",\(String(format: "%.4f", avgMs))"
                        + ",\(String(format: "%.4f", stat.maxSeconds * 1000))"
                        + ",\(String(format: "%.3f", stat.totalSeconds))"
                        + ",\(String(format: "%.1f", stat.totalSeconds / attributedTotal * 100))\n"
                }
                try? FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
                let safeScene = scene.replacingOccurrences(of: "/", with: "_")
                let file = reportDirectory.appendingPathComponent("pass-profile-\(safeScene)-\(instance).csv")
                try? csv.write(to: file, atomically: true, encoding: .utf8)
                let top = rows.prefix(5)
                    .map { "\($0.key)=\(String(format: "%.2f", $0.value.totalSeconds / Double(max($0.value.count, 1)) * 1000))ms" }
                    .joined(separator: " ")
                Logger.notice(
                    "[WPE pass-gpu-profile] scene=\(scene) cb=\(cbCount) top: \(top)",
                    category: .wpeRender
                )
            }

            /// Proves the device accepts a sample-attached render pass before any real
            /// frame relies on it — a rejected attachment would fail encoder creation
            /// mid-frame and break rendering with the flag on.
            private func selfTest() -> Bool {
                guard let queue = device.makeCommandQueue(),
                      let commandBuffer = queue.makeCommandBuffer(),
                      let sampleBuffer = makeSampleBuffer() else { return false }
                let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false
                )
                textureDescriptor.usage = [.renderTarget]
                textureDescriptor.storageMode = .private
                guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return false }
                let descriptor = MTLRenderPassDescriptor()
                descriptor.colorAttachments[0].texture = texture
                descriptor.colorAttachments[0].loadAction = .clear
                descriptor.colorAttachments[0].storeAction = .dontCare
                let attachment = descriptor.sampleBufferAttachments[0]!
                attachment.sampleBuffer = sampleBuffer
                attachment.startOfVertexSampleIndex = 0
                attachment.endOfVertexSampleIndex = 1
                attachment.startOfFragmentSampleIndex = 2
                attachment.endOfFragmentSampleIndex = 3
                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return false }
                encoder.endEncoding()
                return true
            }
        }
    #else
        /// Release stub so call sites stay unconditional one-liners; `makeIfEnabled`
        /// always vends nil, so every optional-chained call is a no-op.
        final class WPEMetalPassGPUProfiler: @unchecked Sendable {
            static func makeIfEnabled(device _: MTLDevice) -> WPEMetalPassGPUProfiler? {
                nil
            }

            func noteScene(_: String?) {}
            func attach(_: MTLRenderPassDescriptor, to _: MTLCommandBuffer, label _: String) {}
        }
    #endif
#endif
