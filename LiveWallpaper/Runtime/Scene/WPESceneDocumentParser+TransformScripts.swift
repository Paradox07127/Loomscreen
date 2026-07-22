#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

extension WPETransformScriptEvaluator: WPESceneTransformScriptResolving {}

// App-level parse entries: wire the JSContext-backed static-origin evaluator
// into the package parser, which cannot depend on the script runtime.
extension WPESceneDocumentParser {
    static func parse(data: Data) throws -> WPESceneDocument {
        try parse(data: data, userValues: [:])
    }

    static func parse(
        data: Data,
        userValues: [String: WallpaperEngineProjectPropertyValue]
    ) throws -> WPESceneDocument {
        try parse(data: data, userValues: userValues) {
            WPETransformScriptEvaluator(canvasWidth: $0, canvasHeight: $1)
        }
    }
}
#endif
