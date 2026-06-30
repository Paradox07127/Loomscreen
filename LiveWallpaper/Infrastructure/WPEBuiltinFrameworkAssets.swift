#if !LITE_BUILD
import Foundation

/// App-bundled clean-room equivalents of the small Wallpaper Engine framework
/// files referenced by common scene projects. Authored locally, contain no
/// WPE bytes; ship under `wpe-builtins/` (~68 KB). See `expectedFiles` for
/// the authoritative inventory. Noise PNGs are generated idempotently by
/// `scripts/generate-wpe-builtin-noise.py`.
enum WPEBuiltinFrameworkAssets {
    /// Bundle directory containing the resources. `.bundle` extension keeps
    /// the subdirectory tree intact so `models/util/*.json` doesn't collide
    /// with `materials/util/*.json` after Xcode resource copying. `nil` only
    /// in test bundles that don't ship the resource subtree.
    static let rootURL: URL? = Bundle.main.url(
        forResource: "wpe-builtins",
        withExtension: "bundle"
    )

    /// Authoritative inventory; tests verify the subtree shipped intact.
    /// Append new files here when adding to `LiveWallpaper/Resources/wpe-builtins/`.
    static let expectedFiles: [String] = [
        "materials/effects/refractnormal.png",
        "materials/effects/waterflowphase.png",
        "materials/effects/waterripplenormal.png",
        "materials/util/black.png",
        "materials/util/clouds_256.png",
        "materials/util/composelayer.json",
        "materials/util/effectcomposebackground.json",
        "materials/util/flatnormal.png",
        "materials/util/fullscreenlayer.json",
        "materials/util/noise.png",
        "materials/util/solidlayer.json",
        "materials/util/solidlayer_depthtest.json",
        "materials/util/solidlayer_instance.json",
        "materials/util/solidlayer_instance_4.json",
        "materials/util/solidlayer_instance_depthtest_4.json",
        "materials/util/white.png",
        "models/util/composelayer.json",
        "models/util/fullscreenlayer.json",
        "models/util/projectlayer.json",
        "models/util/solidlayer.json",
        "models/util/solidlayer_depthtest.json",
        "shaders/effectcomposebackground.frag",
        "shaders/effectcomposebackground.vert"
    ]
}
#endif
