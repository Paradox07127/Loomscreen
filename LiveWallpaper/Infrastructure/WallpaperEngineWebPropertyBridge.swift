import Foundation
import LiveWallpaperCore

/// Builds the small Wallpaper Engine compatibility bridge needed by Web
/// workshop projects. WPE calls `window.wallpaperPropertyListener` with the
/// defaults from `project.json`; some projects wait for that call before they
/// start rendering.
///
/// The bridge has two entry points:
/// - The `forFolder:` flavors read `project.json` synchronously and are used
///   on the cold-start (loadSource) path, where the disk hit is unavoidable.
/// - The `schema:` flavors take an already-parsed schema so the runtime
///   apply path (slider drags, toggle flips) can re-serialize JSON without
///   re-parsing the manifest on every frame tick.
enum WallpaperEngineWebPropertyBridge {
    static func bootstrapScript(
        forFolder folderURL: URL,
        overrides: [String: WallpaperEngineProjectPropertyValue] = [:]
    ) -> String? {
        guard let schema = parseSchema(forFolder: folderURL) else { return nil }
        return bootstrapScript(schema: schema, overrides: overrides)
    }

    static func bootstrapScript(
        schema: WallpaperEngineProjectPropertySchema,
        overrides: [String: WallpaperEngineProjectPropertyValue] = [:]
    ) -> String? {
        guard let json = propertiesJSON(schema: schema, overrides: overrides) else {
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

    static func applyScript(
        forFolder folderURL: URL,
        overrides: [String: WallpaperEngineProjectPropertyValue]
    ) -> String? {
        guard let schema = parseSchema(forFolder: folderURL) else { return nil }
        return applyScript(schema: schema, overrides: overrides)
    }

    static func applyScript(
        schema: WallpaperEngineProjectPropertySchema,
        overrides: [String: WallpaperEngineProjectPropertyValue]
    ) -> String? {
        guard let json = propertiesJSON(schema: schema, overrides: overrides) else {
            return nil
        }

        return """
        (function () {
            var listener = window.wallpaperPropertyListener;
            if (listener && typeof listener.applyUserProperties === 'function') {
                listener.applyUserProperties(\(json));
            }
        })();
        """
    }

    static func applyScript(
        schema: WallpaperEngineProjectPropertySchema,
        previousOverrides: [String: WallpaperEngineProjectPropertyValue],
        overrides: [String: WallpaperEngineProjectPropertyValue]
    ) -> String? {
        let previousValues = schema.effectiveValues(overrides: previousOverrides)
        let currentValues = schema.effectiveValues(overrides: overrides)
        let changedKeys = Set(schema.properties.compactMap { property -> String? in
            previousValues[property.key] == currentValues[property.key] ? nil : property.key
        })
        guard !changedKeys.isEmpty,
              let json = propertiesJSON(
                  schema: schema,
                  overrides: overrides,
                  includingKeys: changedKeys
              ) else {
            return nil
        }

        return """
        (function () {
            var listener = window.wallpaperPropertyListener;
            if (listener && typeof listener.applyUserProperties === 'function') {
                listener.applyUserProperties(\(json));
            }
        })();
        """
    }

    /// Synchronous disk read + JSON parse. Callers on hot paths should
    /// cache the result and use the `schema:` overloads above.
    static func parseSchema(forFolder folderURL: URL) -> WallpaperEngineProjectPropertySchema? {
        let manifestURL = folderURL.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let schema = try? WallpaperEngineProjectPropertySchema.parse(data: data),
              !schema.properties.isEmpty else {
            return nil
        }
        return schema
    }

    private static func propertiesJSON(
        schema: WallpaperEngineProjectPropertySchema,
        overrides: [String: WallpaperEngineProjectPropertyValue],
        includingKeys allowedKeys: Set<String>? = nil
    ) -> String? {
        guard !schema.properties.isEmpty else { return nil }

        let values = schema.effectiveValues(overrides: overrides)
        var payload: [String: Any] = [:]
        for property in schema.properties {
            if let allowedKeys, !allowedKeys.contains(property.key) { continue }
            guard let value = values[property.key]?.jsonObject else { continue }
            let wrapped: [String: Any] = ["value": value]
            guard JSONSerialization.isValidJSONObject(wrapped) else { continue }
            payload[property.key] = wrapped
        }

        guard !payload.isEmpty,
              JSONSerialization.isValidJSONObject(payload),
              let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: jsonData, encoding: .utf8) else {
            return nil
        }

        return json
    }
}

private extension WallpaperEngineProjectPropertyValue {
    var jsonObject: Any? {
        switch self {
        case .bool(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        }
    }
}
