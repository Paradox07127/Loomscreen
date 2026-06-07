import Foundation
import LiveWallpaperProWPE
import Testing

struct WPEParticleSpriteSheetTests {

    @Test("Parses leaves7.tex-json into 6×5 / 30 frame / RGBA sheet")
    func parsesLeavesAtlas() throws {
        let json = #"""
        {
            "clampuvs": false,
            "format": "rgba8888",
            "nonpoweroftwo": true,
            "spritesheetsequences": [
                { "duration": 1, "frames": 30, "height": 102.4, "width": 85.334 }
            ]
        }
        """#
        let sheet = try #require(WPEParticleSpriteSheetParser.parse(
            data: Data(json.utf8),
            atlasPixelSize: (width: 512, height: 512)
        ))
        #expect(sheet.cols == 6)
        #expect(sheet.rows == 5)
        #expect(sheet.frameCount == 30)
        #expect(abs(sheet.baseFrameRate - 30) < 0.001)
        #expect(sheet.isAlphaMask == false)
        #expect(sheet.frameRects == nil)
    }

    @Test("Explicit frame-rect sheets derive frame count from the rects")
    func explicitFrameRectsDeriveFrameCount() throws {
        let rects = [
            SIMD4<Float>(0, 0, 0.25, 0.5),
            SIMD4<Float>(0.25, 0, 0.5, 0.5)
        ]
        let sheet = WPEParticleSpriteSheet(
            cols: 1, rows: 1, frameCount: 99, baseFrameRate: 10, isAlphaMask: false, frameRects: rects
        )
        #expect(sheet.frameCount == 2)
        #expect(sheet.frameRects == rects)
        #expect(sheet == WPEParticleSpriteSheet(
            cols: 1, rows: 1, frameCount: 2, baseFrameRate: 10, isAlphaMask: false, frameRects: rects
        ))
    }

    @Test("Parses fog1.tex-json into 8×8 / 64 frame / r8 mask sheet")
    func parsesFogAtlas() throws {
        let json = #"""
        {
            "format": "r8",
            "nonpoweroftwo": true,
            "spritesheetsequences": [
                { "duration": 1, "frames": 64, "height": 128, "width": 128 }
            ]
        }
        """#
        let sheet = try #require(WPEParticleSpriteSheetParser.parse(
            data: Data(json.utf8),
            atlasPixelSize: (width: 1024, height: 1024)
        ))
        #expect(sheet.cols == 8)
        #expect(sheet.rows == 8)
        #expect(sheet.frameCount == 64)
        #expect(sheet.isAlphaMask == true)
    }

    @Test("Missing spritesheetsequences returns nil")
    func absentSequencesReturnsNil() {
        let json = #"""
        { "format": "rgba8888" }
        """#
        let sheet = WPEParticleSpriteSheetParser.parse(
            data: Data(json.utf8),
            atlasPixelSize: (width: 512, height: 512)
        )
        #expect(sheet == nil)
    }

    @Test("Unknown format defaults to RGBA (not mask)")
    func unknownFormatTreatedAsRGBA() throws {
        let json = #"""
        {
            "format": "dxt5",
            "spritesheetsequences": [
                { "duration": 2, "frames": 4, "height": 256, "width": 256 }
            ]
        }
        """#
        let sheet = try #require(WPEParticleSpriteSheetParser.parse(
            data: Data(json.utf8),
            atlasPixelSize: (width: 512, height: 512)
        ))
        #expect(sheet.isAlphaMask == false)
        #expect(sheet.cols == 2)
        #expect(sheet.rows == 2)
        #expect(sheet.frameCount == 4)
        // duration 2s, 4 frames → 2 fps
        #expect(abs(sheet.baseFrameRate - 2) < 0.001)
    }

    @Test("Particle parser captures sequencemultiplier")
    func parserCapturesSequenceMultiplier() throws {
        let json = #"""
        {
            "maxcount": 50,
            "sequencemultiplier": 3,
            "emitter": [{"rate": 5}],
            "initializer": [],
            "operator": []
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(abs(def.sequenceMultiplier - 3) < 0.0001)
    }

    @Test("Sequence multiplier defaults to 1 when missing")
    func sequenceMultiplierDefaultIsOne() throws {
        let json = #"""
        {
            "maxcount": 10,
            "emitter": [{"rate": 1}],
            "initializer": [],
            "operator": []
        }
        """#
        let def = try #require(WPEParticleDefinitionParser.parse(data: Data(json.utf8)))
        #expect(abs(def.sequenceMultiplier - 1) < 0.0001)
    }
}
