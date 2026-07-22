#if DEBUG && !LITE_BUILD
    import Foundation
    @testable import LiveWallpaper
    import Metal
    import Testing

    struct WPEMetalPassGPUProfilerTests {
        private static let flagKey = "WPEPassGPUProfileEnabled"

        @Test("Stage-boundary sampling yields a ranked per-pass CSV")
        func stageBoundarySamplingProducesRankedCSV() throws {
            guard let device = MTLCreateSystemDefaultDevice(),
                  device.supportsCounterSampling(.atStageBoundary) else {
                return
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

            var csv: String?
            for attempt in 0 ..< 40 {
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
            for line in report.split(separator: "\n").dropFirst(2) {
                let fields = line.split(separator: ",")
                let avgMs = try #require(Double(fields[2]))
                #expect(avgMs > 0)
            }
        }
    }
#endif
