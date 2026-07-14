import simd

/// Deterministic curl noise for WPE's `turbulentvelocityrandom` initializer and
/// `turbulence` operator. Pure functions (no RNG, no global state), so the same
/// input always yields the same vector — the oracle can seed particle RNG and
/// still get a reproducible turbulence field.
///
/// Mirrors the reference C++ renderer (catsout/wallpaper-scene-renderer,
/// `Utils/Algorism`): classic Perlin gradient noise with the canonical 256-entry
/// permutation table, sampled three times at fixed offsets to build a vector
/// field, then the analytic curl of that field. Curl noise is divergence-free,
/// so particles advected by it swirl without clumping.
public enum WPEParticleCurlNoise {
    // Perlin's reference permutation, doubled so index math never wraps.
    private static let perm: [Int] = {
        let base: [Int] = [
            151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225, 140, 36,
            103, 30, 69, 142, 8, 99, 37, 240, 21, 10, 23, 190, 6, 148, 247, 120, 234, 75,
            0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32, 57, 177, 33, 88, 237, 149,
            56, 87, 174, 20, 125, 136, 171, 168, 68, 175, 74, 165, 71, 134, 139, 48, 27, 166,
            77, 146, 158, 231, 83, 111, 229, 122, 60, 211, 133, 230, 220, 105, 92, 41, 55, 46,
            245, 40, 244, 102, 143, 54, 65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187,
            208, 89, 18, 169, 200, 196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186,
            3, 64, 52, 217, 226, 250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212,
            207, 206, 59, 227, 47, 16, 58, 17, 182, 189, 28, 42, 223, 183, 170, 213, 119, 248,
            152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43, 172, 9, 129, 22, 39, 253,
            19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104, 218, 246, 97, 228, 251, 34,
            242, 193, 238, 210, 144, 12, 191, 179, 162, 241, 81, 51, 145, 235, 249, 14, 239, 107,
            49, 192, 214, 31, 181, 199, 106, 157, 184, 84, 204, 176, 115, 121, 50, 45, 127, 4,
            150, 254, 138, 236, 205, 93, 222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66,
            215, 61, 156, 180,
        ]
        return base + base
    }()

    @inline(__always)
    private static func fade(_ t: Double) -> Double {
        t * t * t * (t * (t * 6 - 15) + 10)
    }

    @inline(__always)
    private static func lerp(_ t: Double, _ a: Double, _ b: Double) -> Double {
        a + t * (b - a)
    }

    @inline(__always)
    private static func grad(_ hash: Int, _ x: Double, _ y: Double, _ z: Double) -> Double {
        let h = hash & 15
        let u = h < 8 ? x : y
        let v = h < 4 ? y : (h == 12 || h == 14 ? x : z)
        return ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v)
    }

    public static func perlin(_ x: Double, _ y: Double, _ z: Double) -> Double {
        let xi = Int(x.rounded(.down)) & 255
        let yi = Int(y.rounded(.down)) & 255
        let zi = Int(z.rounded(.down)) & 255
        let xf = x - x.rounded(.down)
        let yf = y - y.rounded(.down)
        let zf = z - z.rounded(.down)
        let u = fade(xf)
        let v = fade(yf)
        let w = fade(zf)

        let a = perm[xi] + yi
        let aa = perm[a] + zi
        let ab = perm[a + 1] + zi
        let b = perm[xi + 1] + yi
        let ba = perm[b] + zi
        let bb = perm[b + 1] + zi

        return lerp(w,
            lerp(v,
                lerp(u, grad(perm[aa], xf, yf, zf),
                        grad(perm[ba], xf - 1, yf, zf)),
                lerp(u, grad(perm[ab], xf, yf - 1, zf),
                        grad(perm[bb], xf - 1, yf - 1, zf))),
            lerp(v,
                lerp(u, grad(perm[aa + 1], xf, yf, zf - 1),
                        grad(perm[ba + 1], xf - 1, yf, zf - 1)),
                lerp(u, grad(perm[ab + 1], xf, yf - 1, zf - 1),
                        grad(perm[bb + 1], xf - 1, yf - 1, zf - 1))))
    }

    // Three decorrelated Perlin samples → a vector field (fixed offsets from the
    // reference implementation so different curl components stay independent).
    @inline(__always)
    private static func perlinVec3(_ p: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(
            perlin(p.x, p.y, p.z),
            perlin(p.x + 89.2, p.y + 33.1, p.z + 57.3),
            perlin(p.x + 100.3, p.y + 120.1, p.z + 142.2)
        )
    }

    /// Analytic curl of the Perlin vector field via central differences.
    /// Result is unnormalized; callers normalize to a direction.
    public static func curl(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let e = 1e-5
        let dx = SIMD3<Double>(e, 0, 0)
        let dy = SIMD3<Double>(0, e, 0)
        let dz = SIMD3<Double>(0, 0, e)
        let x0 = perlinVec3(p - dx), x1 = perlinVec3(p + dx)
        let y0 = perlinVec3(p - dy), y1 = perlinVec3(p + dy)
        let z0 = perlinVec3(p - dz), z1 = perlinVec3(p + dz)
        let cx = y1.z - y0.z - z1.y + z0.y
        let cy = z1.x - z0.x - x1.z + x0.z
        let cz = x1.y - x0.y - y1.x + y0.x
        return SIMD3<Double>(cx, cy, cz) / (2 * e)
    }

    /// Curl direction (unit vector), or `fallback` when the field is degenerate.
    public static func direction(
        at p: SIMD3<Double>,
        fallback: SIMD3<Double> = SIMD3<Double>(0, 1, 0)
    ) -> SIMD3<Double> {
        let c = curl(p)
        let len = simd_length(c)
        return len > 1e-9 ? c / len : fallback
    }
}
