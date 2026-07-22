import LiveWallpaperCore
import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI file-document wrapper around a configuration payload encoded on the main actor.
struct ConfigurationDocument: FileDocument {
    /// File panels prefer the app's configuration type while accepting raw JSON imports.
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

    /// Required by `FileDocument`; interactive imports use `ConfigurationPorter` for confirmation.
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
