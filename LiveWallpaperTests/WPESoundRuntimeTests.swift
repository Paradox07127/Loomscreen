import Foundation
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

struct WPESoundRuntimeTests {

    @Test("Parses sound object with array of paths")
    func parsesSoundObjectWithArrayPaths() throws {
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [{
                "id": 7,
                "name": "BGM",
                "type": "sound",
                "sound": ["sounds/track1.mp3", "sounds/track2.mp3"],
                "volume": 0.5,
                "playbackmode": "loop"
            }]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        #expect(document.soundObjects.count == 1)
        let sound = try #require(document.soundObjects.first)
        #expect(sound.soundRelativePaths == ["sounds/track1.mp3", "sounds/track2.mp3"])
        #expect(sound.volume == 0.5)
        #expect(sound.playbackMode == "loop")
    }

    @Test("Parses sound object with single string path")
    func parsesSoundObjectWithStringPath() throws {
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [{
                "id": 7,
                "name": "Single",
                "type": "sound",
                "sound": "sounds/single.wav"
            }]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let sound = try #require(document.soundObjects.first)
        #expect(sound.soundRelativePaths == ["sounds/single.wav"])
        #expect(sound.volume == 1)
    }

    @Test("Empty sound list rejects parse")
    func emptySoundRejected() throws {
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [{
                "id": 7,
                "name": "Empty",
                "type": "sound",
                "sound": []
            }]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        #expect(document.soundObjects.isEmpty)
    }

    @Test("WPESoundRuntime initializes with default zero spectrum")
    func soundRuntimeInitializesWithSilence() throws {
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: FileManager.default.temporaryDirectory,
            dependencyMounts: []
        )
        let runtime = WPESoundRuntime(resolver: resolver)
        let spectrum = runtime.currentSpectrum
        #expect(spectrum.count == WPESoundRuntime.binCount)
        #expect(spectrum.allSatisfy { $0 == 0 })
    }

    @Test("WPESoundRuntime.start with no sounds returns 0 attached but still installs FFT tap")
    func soundRuntimeStartsWithoutSounds() throws {
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: FileManager.default.temporaryDirectory,
            dependencyMounts: []
        )
        let runtime = WPESoundRuntime(resolver: resolver)
        let attached = runtime.start(sounds: [])
        defer { runtime.stop() }
        #expect(attached == 0)
        #expect(runtime.currentSpectrum.count == WPESoundRuntime.binCount)
    }

    @Test("Master mute set before start() seeds the runtime's initial state")
    func masterMuteBeforeStartIsHonored() throws {
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: FileManager.default.temporaryDirectory,
            dependencyMounts: []
        )
        let runtime = WPESoundRuntime(resolver: resolver)
        runtime.setMuted(true)
        runtime.setMasterVolume(0.25)
        let attached = runtime.start(sounds: [])
        defer { runtime.stop() }
        #expect(attached == 0)
    }

    @Test("setMasterVolume clamps to [0, 1]")
    func masterVolumeClamps() throws {
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: FileManager.default.temporaryDirectory,
            dependencyMounts: []
        )
        let runtime = WPESoundRuntime(resolver: resolver)
        runtime.setMasterVolume(-1.5)
        runtime.setMasterVolume(2.0)
    }

    @Test("prepare() attaches without playing; play() is a no-op when nothing prepared")
    func prepareDefersPlayback() throws {
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: FileManager.default.temporaryDirectory,
            dependencyMounts: []
        )
        let runtime = WPESoundRuntime(resolver: resolver)
        defer { runtime.stop() }
        let attached = runtime.prepare(sounds: [])
        #expect(attached == 0)
        #expect(runtime.play() == false)
    }

    @Test("prepare() then stop() without play() (stale-scene teardown) is safe")
    func prepareThenStopWithoutPlayIsSafe() throws {
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: FileManager.default.temporaryDirectory,
            dependencyMounts: []
        )
        let runtime = WPESoundRuntime(resolver: resolver)
        _ = runtime.prepare(sounds: [])
        runtime.stop()
    }
}
