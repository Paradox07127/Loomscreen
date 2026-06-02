#if !LITE_BUILD
import Foundation
import simd

/// Per-object (per-layer) transform uniforms for WPE 2.8 model shaders.
///
/// `g_ModelMatrix` and `g_NormalModelMatrix` are *object*-scoped, so unlike the
/// per-frame `WPEMetalRuntimeUniforms` they are merged per layer in
/// `WPEPreparedRenderPipeline.addingMetalRuntimeUniforms`.
///
/// 2.8's `generic4`/`chroma4`/`foliage4`/`fur4` vertex shaders switched from
/// `CAST3X3(g_ModelMatrix)` to an explicit inverse-transpose normal matrix
/// (`g_NormalModelMatrix`). Our custom-shader compiler is fragment-only today
/// (it never executes those vertex shaders), so these uniforms exist so any
/// 2.8 shader that *declares* them can pack a value instead of failing; the
/// transpiler only packs declared uniforms, so identity defaults stay zero-cost
/// for the existing 2D/orthographic scenes.
enum WPEMetalObjectUniforms {

    /// `g_ModelMatrix` (16, column-major) + `g_NormalModelMatrix` (9, column-major).
    static func uniformValues(
        origin: SIMD3<Double>,
        scale: SIMD3<Double>,
        angles: SIMD3<Double>
    ) -> [String: WPESceneShaderConstantValue] {
        let model = modelMatrix(origin: origin, scale: scale, angles: angles)
        let normal = normalMatrix(from: model)
        return [
            "g_ModelMatrix": .vector(flattenedColumnMajor(model)),
            "g_NormalModelMatrix": .vector(flattenedColumnMajor(normal))
        ]
    }

    /// `M = T(origin) · Rz(angles.z) · Ry(angles.y) · Rx(angles.x) · S(scale)`.
    static func modelMatrix(
        origin: SIMD3<Double>,
        scale: SIMD3<Double>,
        angles: SIMD3<Double>
    ) -> simd_double4x4 {
        let rotation = rotationZ(angles.z) * rotationY(angles.y) * rotationX(angles.x)
        return translation(origin) * rotation * scaling(scale)
    }

    /// `transpose(inverse(mat3(model)))`. Falls back to identity when the
    /// upper-left 3×3 is (near-)singular — a zero/degenerate scale would
    /// otherwise produce NaN/Inf in the inverse.
    static func normalMatrix(from model: simd_double4x4) -> simd_double3x3 {
        let upper = simd_double3x3(
            SIMD3(model.columns.0.x, model.columns.0.y, model.columns.0.z),
            SIMD3(model.columns.1.x, model.columns.1.y, model.columns.1.z),
            SIMD3(model.columns.2.x, model.columns.2.y, model.columns.2.z)
        )
        guard abs(simd_determinant(upper)) >= 1e-8 else {
            return matrix_identity_double3x3
        }
        return upper.inverse.transpose
    }

    static func flattenedColumnMajor(_ m: simd_double4x4) -> [Double] {
        [
            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w
        ]
    }

    static func flattenedColumnMajor(_ m: simd_double3x3) -> [Double] {
        [
            m.columns.0.x, m.columns.0.y, m.columns.0.z,
            m.columns.1.x, m.columns.1.y, m.columns.1.z,
            m.columns.2.x, m.columns.2.y, m.columns.2.z
        ]
    }

    // MARK: - Column-major simd builders

    private static func translation(_ t: SIMD3<Double>) -> simd_double4x4 {
        var m = matrix_identity_double4x4
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }

    private static func scaling(_ s: SIMD3<Double>) -> simd_double4x4 {
        simd_double4x4(diagonal: SIMD4(s.x, s.y, s.z, 1))
    }

    private static func rotationX(_ a: Double) -> simd_double4x4 {
        let c = cos(a), s = sin(a)
        return simd_double4x4(
            SIMD4(1, 0, 0, 0),
            SIMD4(0, c, s, 0),
            SIMD4(0, -s, c, 0),
            SIMD4(0, 0, 0, 1)
        )
    }

    private static func rotationY(_ a: Double) -> simd_double4x4 {
        let c = cos(a), s = sin(a)
        return simd_double4x4(
            SIMD4(c, 0, -s, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(s, 0, c, 0),
            SIMD4(0, 0, 0, 1)
        )
    }

    private static func rotationZ(_ a: Double) -> simd_double4x4 {
        let c = cos(a), s = sin(a)
        return simd_double4x4(
            SIMD4(c, s, 0, 0),
            SIMD4(-s, c, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, 0, 0, 1)
        )
    }
}
#endif
