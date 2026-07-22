import Foundation
import simd
import Testing
@testable import LiveWallpaper

@Suite("WPE Metal object uniforms")
struct WPEMetalObjectUniformsTests {

    @Test("Identity geometry produces identity model and normal matrices")
    func identityGeometryProducesIdentity() {
        let values = WPEMetalObjectUniforms.uniformValues(
            origin: SIMD3<Double>(0, 0, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0)
        )
        #expect(values["g_ModelMatrix"]?.vectorValue == [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        #expect(values["g_NormalModelMatrix"]?.vectorValue == [1, 0, 0, 0, 1, 0, 0, 0, 1])
    }

    @Test("Translation lands in column-major column 3")
    func translationIsColumnMajor() {
        let m = WPEMetalObjectUniforms.modelMatrix(
            origin: SIMD3<Double>(5, 6, 7),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0)
        )
        let flat = WPEMetalObjectUniforms.flattenedColumnMajor(m)
        #expect(Array(flat[12..<16]) == [5, 6, 7, 1])
    }

    @Test("Non-uniform scale yields reciprocal normal-matrix diagonal")
    func nonUniformScaleNormalMatrix() throws {
        let values = WPEMetalObjectUniforms.uniformValues(
            origin: SIMD3<Double>(0, 0, 0),
            scale: SIMD3<Double>(2, 4, 1),
            angles: SIMD3<Double>(0, 0, 0)
        )
        let model = try #require(values["g_ModelMatrix"]?.vectorValue)
        #expect(model[0] == 2 && model[5] == 4 && model[10] == 1)

        let normal = try #require(values["g_NormalModelMatrix"]?.vectorValue)
        #expect(abs(normal[0] - 0.5) < 1e-9)
        #expect(abs(normal[4] - 0.25) < 1e-9)
        #expect(abs(normal[8] - 1.0) < 1e-9)
    }

    @Test("Degenerate (zero) scale falls back to identity normal matrix without NaN")
    func zeroScaleFallsBackToIdentityNormal() throws {
        let values = WPEMetalObjectUniforms.uniformValues(
            origin: SIMD3<Double>(0, 0, 0),
            scale: SIMD3<Double>(0, 0, 0),
            angles: SIMD3<Double>(0, 0, 0)
        )
        let normal = try #require(values["g_NormalModelMatrix"]?.vectorValue)
        #expect(normal == [1, 0, 0, 0, 1, 0, 0, 0, 1])
        #expect(normal.allSatisfy { $0.isFinite })
    }

    @Test("90° Z rotation maps +X to +Y (column-major sign convention)")
    func zRotationSignConvention() {
        let m = WPEMetalObjectUniforms.modelMatrix(
            origin: SIMD3<Double>(0, 0, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, .pi / 2)
        )
        let x = m * SIMD4<Double>(1, 0, 0, 1)
        #expect(abs(x.x) < 1e-9)
        #expect(abs(x.y - 1) < 1e-9)
    }

    @Test("Dispatcher object quads carry frame camera uniforms")
    func dispatcherObjectQuadsCarryFrameCameraUniforms() throws {
        let source = try Self.readSourceFile("LiveWallpaper/Runtime/Metal/WPEMetalShaderDispatcher.swift")
        let quadCallCount = source.components(separatedBy: "executor.objectQuadUniforms(").count - 1
        let cameraArgumentCount = source.components(separatedBy: "cameraUniforms: executor.objectQuadCameraUniforms(").count - 1

        #expect(quadCallCount > 0)
        #expect(cameraArgumentCount == quadCallCount)
    }

    private static func readSourceFile(_ relativePath: String) throws -> String {
        try RepositoryRoot.source(relativePath)
    }
}
