import Foundation

struct WPESceneCapabilityClassifier: Sendable {
    func capabilityTier(for document: WPESceneDocument, cacheURL: URL) -> SceneCapabilityTier {
        guard !document.imageObjects.isEmpty else {
            return .unsupported
        }

        let resolver = SceneResourceResolver(cacheRootURL: cacheURL)
        var resolvable = 0
        var unresolvable = 0
        for object in document.imageObjects {
            switch resolver.probeRenderableImage(relativePath: object.imageRelativePath) {
            case .success:
                resolvable += 1
            case .failure:
                unresolvable += 1
            }
        }

        if resolvable == 0 { return .unsupported }
        let blockingDiagnostics = document.diagnostics.filter { diagnostic in
            !diagnostic.message.contains(".tex texture")
        }
        if unresolvable == 0 && blockingDiagnostics.isEmpty {
            return .imageOnly
        }
        return .degraded
    }
}
