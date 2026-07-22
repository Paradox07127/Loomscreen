#if !LITE_BUILD
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import LiveWallpaper

@Suite("WorkshopAnimatedGIF bounded decode")
struct WorkshopAnimatedGIFDecodeTests {

    @Test("Single-frame PNG decodes to a static image")
    func staticPNGDecodesStatic() throws {
        let data = GIFTestFixtures.png(width: 8, height: 8)
        let asset = try #require(WorkshopAnimatedGIF.make(from: data))
        guard case .staticImage = asset else {
            Issue.record("Expected .staticImage, got \(asset)")
            return
        }
        #expect(asset.isAnimated == false)
    }

    @Test("Multi-frame GIF decodes to an animation with the right frame count + delays")
    func animatedGIFDecodesAnimated() throws {
        let data = GIFTestFixtures.gif(width: 8, height: 8, frameCount: 3, delay: 0.1)
        let asset = try #require(WorkshopAnimatedGIF.make(from: data))
        guard case .animatedGIF(let gif) = asset else {
            Issue.record("Expected .animatedGIF, got \(asset)")
            return
        }
        #expect(gif.frameCount == 3)
        #expect(gif.frameDelays.count == 3)
        #expect(gif.frame(at: 0) != nil)
        #expect(gif.frame(at: 2) != nil)
        #expect(gif.frame(at: 3) == nil)
        #expect(gif.frameDelays.allSatisfy { $0 >= WorkshopAnimatedGIF.minFrameDelay })
    }

    @Test("Frame delays are floored at the 30 FPS cap")
    func frameDelaysFloored() throws {
        let data = GIFTestFixtures.gif(width: 4, height: 4, frameCount: 2, delay: 0.005)
        let asset = try #require(WorkshopAnimatedGIF.make(from: data))
        guard case .animatedGIF(let gif) = asset else {
            Issue.record("Expected .animatedGIF")
            return
        }
        #expect(gif.frameDelays.allSatisfy { $0 >= WorkshopAnimatedGIF.minFrameDelay })
    }

    @Test("Data over the 32 MiB byte cap is rejected")
    func overByteCapRejected() {
        let oversized = Data(count: WorkshopAnimatedGIF.maxBytes + 1)
        #expect(WorkshopAnimatedGIF.make(from: oversized) == nil)
    }

    @Test("Garbage bytes fail to decode")
    func garbageRejected() {
        #expect(WorkshopAnimatedGIF.make(from: Data([0x00, 0x01, 0x02, 0x03])) == nil)
    }

    @Test("Animations over the 120-frame cap degrade to a static poster")
    func overFrameCapDegradesToPoster() throws {
        let data = GIFTestFixtures.gif(width: 2, height: 2, frameCount: WorkshopAnimatedGIF.maxFrameCount + 1, delay: 0.1)
        let asset = try #require(WorkshopAnimatedGIF.make(from: data))
        guard case .staticImage = asset else {
            Issue.record("Expected over-cap animation to degrade to .staticImage, got \(asset)")
            return
        }
        #expect(asset.isAnimated == false)
    }

    @Test("Decoded-pixel budget is overflow-safe and rejects oversized animations")
    func pixelBudget() {
        #expect(WorkshopAnimatedGIF.isWithinPixelBudget(width: 256, height: 256, frameCount: 10))
        #expect(!WorkshopAnimatedGIF.isWithinPixelBudget(width: 4000, height: 4000, frameCount: 100))
        #expect(!WorkshopAnimatedGIF.isWithinPixelBudget(width: 6000, height: 6000, frameCount: 1))
        #expect(WorkshopAnimatedGIF.isWithinPixelBudget(width: 4000, height: 4000, frameCount: 1))
        #expect(!WorkshopAnimatedGIF.isWithinPixelBudget(width: 0, height: 8, frameCount: 1))
        #expect(!WorkshopAnimatedGIF.isWithinPixelBudget(width: Int.max, height: Int.max, frameCount: Int.max))
    }
}

@Suite("GIFPlaybackCoordinator LRU", .serialized)
@MainActor
struct GIFPlaybackCoordinatorTests {

    @Test("Up to 8 concurrent clients play without eviction")
    func underCapNoEviction() {
        let coordinator = GIFPlaybackCoordinator()
        var frozen = Set<UUID>()
        let ids = (0..<8).map { _ in UUID() }
        for id in ids {
            coordinator.requestPlayback(id: id) { frozen.insert(id) }
        }
        #expect(frozen.isEmpty)
    }

    @Test("A 9th client evicts the least-recently-used one")
    func overCapEvictsLRU() {
        let coordinator = GIFPlaybackCoordinator()
        var frozen: [UUID] = []
        let ids = (0..<9).map { _ in UUID() }
        for id in ids {
            coordinator.requestPlayback(id: id) { frozen.append(id) }
        }
        #expect(frozen == [ids[0]])
    }

    @Test("touch protects a client from eviction")
    func touchProtects() {
        let coordinator = GIFPlaybackCoordinator()
        var frozen: [UUID] = []
        let ids = (0..<8).map { _ in UUID() }
        for id in ids {
            coordinator.requestPlayback(id: id) { frozen.append(id) }
        }
        coordinator.touch(id: ids[0])
        let newcomer = UUID()
        coordinator.requestPlayback(id: newcomer) { frozen.append(newcomer) }
        #expect(frozen == [ids[1]])
    }

    @Test("endPlayback frees a slot so no eviction occurs")
    func endPlaybackFreesSlot() {
        let coordinator = GIFPlaybackCoordinator()
        var frozen: [UUID] = []
        let ids = (0..<8).map { _ in UUID() }
        for id in ids {
            coordinator.requestPlayback(id: id) { frozen.append(id) }
        }
        coordinator.endPlayback(id: ids[3])
        let newcomer = UUID()
        coordinator.requestPlayback(id: newcomer) { frozen.append(newcomer) }
        #expect(frozen.isEmpty)
    }
}

@Suite("ThumbnailPlaybackGate")
struct ThumbnailPlaybackGateTests {

    @Test("Grid gate requires visibility, hover, motion, and unblurred content")
    func gridGateRequiresAllInputs() {
        var gate = ThumbnailPlaybackGate(
            isVisible: true,
            isHovered: true,
            reduceMotion: false,
            isBlurred: false,
            trigger: .hover
        )
        #expect(gate.allowsPlayback)

        gate.isVisible = false
        #expect(!gate.allowsPlayback)

        gate.isVisible = true
        gate.isHovered = false
        #expect(!gate.allowsPlayback)

        gate.isHovered = true
        gate.reduceMotion = true
        #expect(!gate.allowsPlayback)

        gate.reduceMotion = false
        gate.isBlurred = true
        #expect(!gate.allowsPlayback)
    }

    @Test("Detail gate auto-plays when visible, without hover")
    func detailGateAutoPlays() {
        var gate = ThumbnailPlaybackGate(
            isVisible: true,
            isHovered: false,
            reduceMotion: false,
            isBlurred: false,
            trigger: .auto
        )
        #expect(gate.allowsPlayback)

        gate.isVisible = false
        #expect(!gate.allowsPlayback)

        gate.isVisible = true
        gate.isBlurred = true
        #expect(!gate.allowsPlayback)
    }
}

@Suite("GIFAnimationController playback gating", .serialized)
@MainActor
struct GIFAnimationControllerTests {

    @Test("Installing an asset shows the poster and does not auto-animate")
    func posterByDefault() {
        let controller = GIFAnimationController()
        controller.setAsset(GIFTestFixtures.animatedAsset(frameCount: 3))
        #expect(controller.displayedFrame != nil)
        #expect(controller.isAnimating == false)
    }

    @Test("A static asset never animates even when asked to play")
    func staticNeverAnimates() async {
        let controller = GIFAnimationController()
        controller.setAsset(GIFTestFixtures.staticAsset())
        controller.play(debounced: false)
        try? await Task.sleep(nanoseconds: 40_000_000)
        #expect(controller.isAnimating == false)
    }

    @Test("An animated asset begins playing on an undebounced play")
    func animatedPlays() async {
        let controller = GIFAnimationController()
        controller.setAsset(GIFTestFixtures.animatedAsset(frameCount: 3))
        controller.play(debounced: false)
        await GIFTestFixtures.waitUntil { controller.isAnimating }
        #expect(controller.isAnimating == true)
        controller.stop()
        #expect(controller.isAnimating == false)
    }

    @Test("Stopping within the 250 ms debounce window starts no playback")
    func debounceCancellation() async {
        let controller = GIFAnimationController()
        controller.setAsset(GIFTestFixtures.animatedAsset(frameCount: 3))
        controller.play(debounced: true)
        controller.stop()
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(controller.isAnimating == false)
    }
}

// MARK: - Fixtures

enum GIFTestFixtures {
    static func cgImage(width: Int, height: Int, seed: Int = 0) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let r = Double((seed &* 53) % 256) / 255.0
        let g = Double((seed &* 97 &+ 40) % 256) / 255.0
        let b = Double((seed &* 29 &+ 80) % 256) / 255.0
        context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func png(width: Int, height: Int) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage(width: width, height: height), nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func gif(width: Int, height: Int, frameCount: Int, delay: Double) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frameCount, nil)!
        let frameProps = [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delay]
        ] as CFDictionary
        for index in 0..<frameCount {
            CGImageDestinationAddImage(dest, cgImage(width: width, height: height, seed: index + 1), frameProps)
        }
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func staticAsset() -> WorkshopPreviewAsset {
        WorkshopAnimatedGIF.make(from: png(width: 8, height: 8))!
    }

    static func animatedAsset(frameCount: Int) -> WorkshopPreviewAsset {
        WorkshopAnimatedGIF.make(from: gif(width: 8, height: 8, frameCount: frameCount, delay: 0.1))!
    }

    @MainActor
    static func waitUntil(timeout: Double = 5.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
#endif
