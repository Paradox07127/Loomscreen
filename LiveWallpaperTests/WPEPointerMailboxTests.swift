#if !LITE_BUILD
import AppKit
import CoreGraphics
import Testing
import simd
@testable import LiveWallpaper

@Suite("WPE pointer mailbox")
struct WPEPointerMailboxTests {
    private static let frame = CGRect(x: 100, y: 200, width: 800, height: 600)

    @Test("Default read is inactive / neutral")
    func defaultRead() {
        let reading = WPEPointerMailbox().read()

        #expect(reading.pointerSample == .inactive)
        #expect(reading.pointerFrame == .neutral)
        #expect(reading.clickCaptureEnabled == false)
        #expect(reading.mouseTimestampNanos == 0)
    }

    @Test("Screen location inside geometry maps to top-left-origin UV")
    func mapInside() {
        let geo = WPEPointerMailbox.Geometry(viewFrameInScreen: Self.frame)

        let center = WPEPointerMailbox.pointerSample(
            forScreenLocation: CGPoint(x: 500, y: 500), geometry: geo
        )
        #expect(center.isInsideView)
        #expect(center.position.x == 0.5)
        #expect(center.position.y == 0.5)

        let bottomLeft = WPEPointerMailbox.pointerSample(
            forScreenLocation: CGPoint(x: 100, y: 200), geometry: geo
        )
        #expect(bottomLeft.isInsideView)
        #expect(bottomLeft.position.x == 0)
        #expect(bottomLeft.position.y == 1)
    }

    @Test("Screen location outside geometry is inactive")
    func mapOutside() {
        let geo = WPEPointerMailbox.Geometry(viewFrameInScreen: Self.frame)
        let outside = WPEPointerMailbox.pointerSample(
            forScreenLocation: CGPoint(x: 50, y: 50), geometry: geo
        )
        #expect(outside == .inactive)
    }

    @Test("Zero geometry is always inactive")
    func zeroGeometry() {
        let outside = WPEPointerMailbox.pointerSample(
            forScreenLocation: CGPoint(x: 500, y: 500), geometry: .none
        )
        #expect(outside == .inactive)
    }

    @Test("Mailbox mapping equals WPEMetalPointerSampler.sampleSceneUV")
    @MainActor
    func matchesLiveSampler() {
        let window = NSWindow(
            contentRect: Self.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let view = NSView(frame: NSRect(origin: .zero, size: Self.frame.size))
        window.contentView = view

        let geo = WPEPointerPublisher.geometry(of: view)
        let probes = [
            CGPoint(x: 500, y: 500),
            CGPoint(x: 120, y: 780),
            CGPoint(x: 899, y: 200),
            CGPoint(x: 50, y: 50),
            CGPoint(x: 1000, y: 900)
        ]
        for probe in probes {
            let live = WPEMetalPointerSampler.sampleSceneUV(mouseLocation: probe, in: view)
            let boxed = WPEPointerMailbox.pointerSample(forScreenLocation: probe, geometry: geo)
            #expect(boxed == live, "probe \(probe): \(boxed) vs \(live)")
        }
    }

    @Test("Mouse writes are last-write-wins")
    func mouseLastWriteWins() {
        let mailbox = WPEPointerMailbox()
        mailbox.publishGeometry(WPEPointerMailbox.Geometry(viewFrameInScreen: Self.frame))

        mailbox.publishMouseLocation(CGPoint(x: 300, y: 300), timestampNanos: 1)
        mailbox.publishMouseLocation(CGPoint(x: 500, y: 500), timestampNanos: 2)

        let reading = mailbox.read()
        #expect(reading.mouseTimestampNanos == 2)
        #expect(reading.pointerSample.position.x == 0.5)
        #expect(reading.pointerSample.position.y == 0.5)
    }

    @Test("Geometry updates are visible on the next read")
    func geometryUpdateVisible() {
        let mailbox = WPEPointerMailbox()
        mailbox.publishMouseLocation(CGPoint(x: 500, y: 500), timestampNanos: 1)

        mailbox.publishGeometry(WPEPointerMailbox.Geometry(viewFrameInScreen: Self.frame))
        #expect(mailbox.read().pointerSample.isInsideView)

        mailbox.publishGeometry(
            WPEPointerMailbox.Geometry(
                viewFrameInScreen: CGRect(x: 2000, y: 2000, width: 100, height: 100)
            )
        )
        #expect(mailbox.read().pointerSample == .inactive)
    }

    @Test("PointerFrame and clickCapture slots are last-write-wins")
    func frameAndClickSlots() {
        let mailbox = WPEPointerMailbox()
        let down = WPEPointerFrame(
            position: SIMD2<Double>(0.2, 0.3),
            clickPosition: SIMD2<Double>(0.2, 0.3),
            isDown: true,
            isRightDown: false
        )

        mailbox.publishPointerFrame(down)
        mailbox.setClickCaptureEnabled(true)

        var reading = mailbox.read()
        #expect(reading.pointerFrame == down)
        #expect(reading.clickCaptureEnabled)

        mailbox.publishPointerFrame(.neutral)
        mailbox.setClickCaptureEnabled(false)
        reading = mailbox.read()
        #expect(reading.pointerFrame == .neutral)
        #expect(reading.clickCaptureEnabled == false)
    }

    @Test("Concurrent read/write stays torn-free")
    func concurrentTornFree() async {
        let mailbox = WPEPointerMailbox()
        let down = WPEPointerFrame(
            position: SIMD2<Double>(0.1, 0.9),
            clickPosition: SIMD2<Double>(0.1, 0.9),
            isDown: true,
            isRightDown: true
        )

        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for index in 0..<5000 {
                    if index.isMultiple(of: 2) {
                        mailbox.publishPointerFrame(down)
                    } else {
                        mailbox.publishPointerFrame(.neutral)
                    }
                }
                return true
            }
            group.addTask {
                for index in 0..<5000 {
                    mailbox.setClickCaptureEnabled(index.isMultiple(of: 2))
                    mailbox.publishGeometry(
                        WPEPointerMailbox.Geometry(viewFrameInScreen: Self.frame)
                    )
                    mailbox.publishMouseLocation(
                        CGPoint(x: 300 + Double(index % 200), y: 300),
                        timestampNanos: UInt64(index)
                    )
                }
                return true
            }
            group.addTask {
                var ok = true
                for _ in 0..<5000 {
                    let reading = mailbox.read()
                    let frameOK = reading.pointerFrame == down || reading.pointerFrame == .neutral
                    let sampleOK: Bool
                    if reading.pointerSample.isInsideView {
                        let p = reading.pointerSample.position
                        sampleOK = p.x >= 0 && p.x <= 1 && p.y >= 0 && p.y <= 1
                    } else {
                        sampleOK = reading.pointerSample == .inactive
                    }
                    ok = ok && frameOK && sampleOK
                }
                return ok
            }

            var allOK = true
            for await result in group { allOK = allOK && result }
            #expect(allOK)
        }
    }
}

@Suite("WPE pointer publisher")
@MainActor
struct WPEPointerPublisherTests {
    @Test("geometry(of:) is none without a window")
    func geometryWithoutWindow() {
        #expect(WPEPointerPublisher.geometry(of: nil) == .none)
        let orphan = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        #expect(WPEPointerPublisher.geometry(of: orphan) == .none)
    }

    @Test("start/stop is idempotent")
    func startStopIdempotent() {
        let publisher = WPEPointerPublisher(mailbox: WPEPointerMailbox(), view: nil)

        #expect(publisher.isRunning == false)
        publisher.start()
        let runningAfterFirstStart = publisher.isRunning
        publisher.start()
        #expect(publisher.isRunning == runningAfterFirstStart)

        publisher.stop()
        #expect(publisher.isRunning == false)
        publisher.stop()
        #expect(publisher.isRunning == false)
    }

    @Test("start seeds geometry into the mailbox")
    func startSeedsGeometry() {
        let mailbox = WPEPointerMailbox()
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 200, width: 800, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let view = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        window.contentView = view

        let publisher = WPEPointerPublisher(mailbox: mailbox, view: view)
        publisher.start()
        defer { publisher.stop() }

        mailbox.publishMouseLocation(CGPoint(x: 500, y: 500), timestampNanos: 1)
        #expect(mailbox.read().pointerSample.isInsideView)
    }
}
#endif
