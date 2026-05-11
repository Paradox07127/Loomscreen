import Foundation

/// Builds the small Wallpaper Engine compatibility bridge needed by Web
/// workshop projects. WPE calls `window.wallpaperPropertyListener` with the
/// defaults from `project.json`; some projects wait for that call before they
/// start rendering.
enum WallpaperEngineWebPropertyBridge {
    static func bootstrapScript(forFolder folderURL: URL) -> String? {
        let manifestURL = folderURL.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let general = root["general"] as? [String: Any],
              let properties = general["properties"] as? [String: Any] else {
            return nil
        }

        var payload: [String: Any] = [:]
        for (key, rawProperty) in properties {
            guard let property = rawProperty as? [String: Any],
                  let value = property["value"] else { continue }
            let wrapped = ["value": value]
            guard JSONSerialization.isValidJSONObject(wrapped) else { continue }
            payload[key] = wrapped
        }

        guard !payload.isEmpty,
              JSONSerialization.isValidJSONObject(payload),
              let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: jsonData, encoding: .utf8) else {
            return nil
        }

        return """
        (function () {
            var properties = \(json);
            var attempts = 0;
            function applyProperties() {
                var listener = window.wallpaperPropertyListener;
                if (listener && typeof listener.applyUserProperties === 'function') {
                    try {
                        listener.applyUserProperties(properties);
                    } catch (error) {
                        console.error('LiveWallpaper failed to apply Wallpaper Engine properties', error);
                    }
                    return;
                }
                if (attempts++ < 120) {
                    window.requestAnimationFrame(applyProperties);
                }
            }
            applyProperties();
        })();
        """
    }
}
