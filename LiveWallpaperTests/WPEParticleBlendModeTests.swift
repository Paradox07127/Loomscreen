import Foundation
import LiveWallpaperProWPE
import Testing

struct WPEParticleBlendModeTests {

    @Test("Translucent material string maps to .translucent")
    func translucent() {
        #expect(WPEParticleBlendMode(materialString: "translucent") == .translucent)
        #expect(WPEParticleBlendMode(materialString: "TRANSLUCENT") == .translucent)
    }

    @Test("Additive material string maps to .additive")
    func additive() {
        #expect(WPEParticleBlendMode(materialString: "additive") == .additive)
        #expect(WPEParticleBlendMode(materialString: "Additive") == .additive)
    }

    @Test("Normal material string maps to .normal")
    func normal() {
        #expect(WPEParticleBlendMode(materialString: "normal") == .normal)
    }

    @Test("Unknown blend string falls back to .translucent")
    func unknownFallsBackToTranslucent() {
        #expect(WPEParticleBlendMode(materialString: "screen") == .translucent)
        #expect(WPEParticleBlendMode(materialString: "") == .translucent)
        #expect(WPEParticleBlendMode(materialString: nil) == .translucent)
    }
}
