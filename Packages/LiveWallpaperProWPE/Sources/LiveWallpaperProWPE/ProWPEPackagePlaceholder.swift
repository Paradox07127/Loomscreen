import Foundation
import LiveWallpaperCore

/// Phase 4 scaffold placeholder for the LiveWallpaperProWPE SPM package.
///
/// This package will host the Wallpaper Engine pipeline (plan §7): scene
/// renderer (WPEMetalSceneRenderer + WPEMetalRenderExecutor + helpers),
/// shader transpiler (WPEShaderTranspiler + WPESPIRVShaderCompiler),
/// particle / text / sound / scene-script runtimes, texture decoder
/// (WPETexDecoder + WPEMetalTextureLoader), import pipeline
/// (WPEImportCoordinator + WallpaperEngineImportService +
/// WallpaperEngineCache), and the Pro-side WPEOrigin / SceneDescriptor
/// behaviour extensions + WPEOriginReconciler.
///
/// The placeholder type itself is unused; Phase 4b removes it.
public enum LiveWallpaperProWPE {
    public static let packageVersion: String = "0.1.0-scaffold"
}
