#if DEBUG && !LITE_BUILD
    import Foundation
    @testable import LiveWallpaper
    import Metal
    import Testing

    /// Metal/GPU-bound: submits real command buffers and reads back stage-boundary
    /// counter samples, so it must stay OUT of `fast_app_contract_tests.sh`
    /// (headless CI runners hang on GPU work). Runs in the local/opt-in Metal job.
    struct WPEMetalPassGPUProfilerTests {
        private static let flagKey = "WPEPassGPUProfileEnabled"

        /// End-to-end proof the profiler produces live data: two labeled passes
        /// with real draws resolve to non-zero durations and a ranked CSV.
        @Test("Stage-boundary sampling yields a ranked per-pass CSV")
        func stageBoundarySamplingProducesRankedCSV() throws {
            guard let device = MTLCreateSystemDefaultDevice(),
                  device.supportsCounterSampling(.atStageBoundary) else {
                return // No sampling-capable GPU (VM runner) — nothing to verify.
            }
            UserDefaults.standard.set(true, forKey: Self.flagKey)
            defer { UserDefaults.standard.removeObject(forKey: Self.flagKey) }
            let profiler = try #require(WPEMetalPassGPUProfiler.makeIfEnabled(device: device))

            let library = try device.makeLibrary(
                source: """
                #include <metal_stdlib>
                using namespace metal;
                vertex float4 test_vertex(uint vid [[vertex_id]]) {
                    float2 p[4] = {float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1)};
                    return float4(p[vid], 0, 1);
                }
                fragment float4 test_fragment() { return float4(0.25, 0.5, 0.75, 1); }
                """,
                options: nil
            )
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = library.makeFunction(name: "test_vertex")
            pipelineDescriptor.fragmentFunction = library.makeFunction(name: "test_fragment")
            pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
            let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: 1024, height: 1024, mipmapped: false
            )
            textureDescriptor.usage = [.renderTarget]
            textureDescriptor.storageMode = .private
            let texture = try #require(device.makeTexture(descriptor: textureDescriptor))
            let queue = try #require(device.makeCommandQueue())

            let sceneID = "profiler-test-\(UUID().uuidString.prefix(8))"
            profiler.noteScene(String(sceneID))
            let commandBuffer = try #require(queue.makeCommandBuffer())
            for label in ["alpha", "beta"] {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = texture
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                profiler.attach(pass, to: commandBuffer, label: label)
                let encoder = try #require(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
                encoder.setRenderPipelineState(pipeline)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                encoder.endEncoding()
            }
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            #expect(commandBuffer.status == .completed)

            // Scene change flushes the CSV; the resolve runs in an async completion
            // handler, so poll briefly instead of asserting immediately.
            var csv: String?
            for attempt in 0 ..< 40 {
                // A unique id per attempt so each call actually flushes once the
                // async resolve has landed (same-id calls are no-ops); every flush
                // file name still embeds the original sceneID for the search below.
                profiler.noteScene("flush-\(sceneID)-\(attempt)")
                if let contents = try? FileManager.default.contentsOfDirectory(
                    at: profiler.reportDirectory, includingPropertiesForKeys: nil
                ), let file = contents.first(where: { $0.lastPathComponent.contains(sceneID) }) {
                    csv = try? String(contentsOf: file, encoding: .utf8)
                    try? FileManager.default.removeItem(at: file)
                    break
                }
                usleep(50000)
            }
            let report = try #require(csv, "profiler never wrote a CSV for \(sceneID)")
            #expect(report.contains("alpha,1,"))
            #expect(report.contains("beta,1,"))
            // Both passes must carry a real duration: a zero avg_ms would mean the
            // samples resolved to MTLCounterErrorValue/0 and were silently dropped.
            for line in report.split(separator: "\n").dropFirst(2) {
                let fields = line.split(separator: ",")
                let avgMs = try #require(Double(fields[2]))
                #expect(avgMs > 0)
            }
        }
    }
#endif
