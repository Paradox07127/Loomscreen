import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@Suite("Toolchain availability sanity")
struct ToolchainAvailabilityTests {
    @Test("isToolchainAvailable returns true in the LiveWallpaper target")
    func toolchainIsLinked() {
        #expect(WPESPIRVShaderCompiler.isToolchainAvailable(), "canImport(WPEShaderToolchain) must be true for the seam swap to actually fire")
    }
}
