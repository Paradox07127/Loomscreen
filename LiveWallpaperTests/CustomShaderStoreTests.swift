#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("CustomShaderStore")
@MainActor
struct CustomShaderStoreTests {

    @Test("Initialization does not synchronously load shaders; reload does")
    func initializationDoesNotSynchronizeDiskReads() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("custom-shader-store-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let shader = CustomShader(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Disk shader",
            source: "fragment float4 mainImage(float2 uv, float time, float2 resolution) { return float4(uv, 0, 1); }",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(shader)
        try data.write(
            to: directory
                .appendingPathComponent(shader.id.uuidString)
                .appendingPathExtension("json"),
            options: .atomic
        )

        let store = CustomShaderStore(directory: directory, fileManager: fileManager)

        #expect(store.shaders.isEmpty)

        await store.reload()

        #expect(store.shaders.map(\.id) == [shader.id])
    }
}
#endif
