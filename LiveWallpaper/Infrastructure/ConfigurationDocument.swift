import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI `FileDocument` wrapper around a pre-encoded configuration
/// payload. We encode on MainActor before constructing the document (via
/// `ConfigurationDocument.snapshot()`), then SwiftUI's exporter pipeline
/// only handles raw bytes — this keeps `FileDocument`'s nonisolated
/// requirements clean under Swift 6 strict concurrency.
struct ConfigurationDocument: FileDocument {
    /// File panels filter to LiveWallpaper's custom UTType; reading a raw
    /// `.json` export is still possible because the type conforms to
    /// `public.json`.
    static let readableContentTypes: [UTType] = [ConfigurationBundle.contentType, .json]
    static let writableContentTypes: [UTType] = [ConfigurationBundle.contentType]

    private let encodedPayload: Data

    init(encodedPayload: Data) {
        self.encodedPayload = encodedPayload
    }

    @MainActor
    static func snapshot() throws -> ConfigurationDocument {
        let bundle = ConfigurationPorter.currentBundle()
        let data = try ConfigurationPorter.encode(bundle)
        return ConfigurationDocument(encodedPayload: data)
    }

    /// `FileDocument`'s reading initializer is required even though we never read via this path — import goes through `ConfigurationPorter` so it can show the confirmation alert before applying.
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.encodedPayload = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: encodedPayload)
    }
}
