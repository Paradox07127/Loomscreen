import Testing
@testable import LiveWallpaper

@Suite("Audio spectrum broker")
struct AudioSpectrumBrokerTests {
    @Test("Default snapshot is silence")
    func defaultSnapshotIsSilence() {
        let broker = AudioSpectrumBroker()

        let snapshot = broker.snapshot()

        #expect(snapshot == .silence)
    }

    @Test("Publish then snapshot returns published normalized frame")
    func publishThenSnapshotReturnsPublishedFrame() {
        let broker = AudioSpectrumBroker()
        let frame = AudioSpectrumFrame(
            left: [0.25, 0.5],
            right: [0.75],
            timestampNanos: 42
        )

        broker.publish(frame)
        let snapshot = broker.snapshot()

        #expect(snapshot == frame)
        #expect(snapshot.left.count == AudioSpectrumFrame.binCount)
        #expect(snapshot.right.count == AudioSpectrumFrame.binCount)
        #expect(snapshot.left[0] == 0.25)
        #expect(snapshot.left[1] == 0.5)
        #expect(snapshot.left[2] == 0)
        #expect(snapshot.right[0] == 0.75)
        #expect(snapshot.right[1] == 0)
    }

    @Test("Reset to silence clears latest frame")
    func resetToSilenceClearsLatestFrame() {
        let broker = AudioSpectrumBroker()
        broker.publish(AudioSpectrumFrame(left: [0.4], right: [0.6], timestampNanos: 99))

        broker.resetToSilence()

        #expect(broker.snapshot() == .silence)
    }

    @Test("Payload has exactly 128 finite values in left then right order")
    func payloadHasExactly128FiniteValuesInLeftThenRightOrder() {
        var left = (0..<70).map { Float($0) / 128 }
        var right = (0..<70).map { Float($0 + 80) / 256 }
        left[2] = .nan
        right[3] = .infinity
        left[4] = -1
        right[4] = 2
        let frame = AudioSpectrumFrame(left: left, right: right, timestampNanos: 123)

        let payload = frame.wpeWebPayload128
        let allInRange = payload.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }

        #expect(payload.count == 128)
        #expect(allInRange)
        #expect(payload[0] == left[0])
        #expect(payload[1] == left[1])
        #expect(payload[2] == 0)
        #expect(payload[4] == 0)
        #expect(payload[63] == Float(63) / 128)
        #expect(payload[64] == right[0])
        #expect(payload[65] == right[1])
        #expect(payload[67] == 0)
        #expect(payload[68] == 1)
        #expect(payload[127] == Float(143) / 256)
    }

    @Test("Concurrent publish and snapshot stay memory-safe")
    func concurrentPublishAndSnapshot() async {
        let broker = AudioSpectrumBroker()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<1000 {
                    let value = Float(index % 2)
                    broker.publish(
                        AudioSpectrumFrame(
                            left: [value],
                            right: [value],
                            timestampNanos: UInt64(index)
                        )
                    )
                }
            }
            group.addTask {
                for _ in 0..<1000 {
                    _ = broker.snapshot()
                }
            }
        }

        #expect(broker.snapshot().left.count == AudioSpectrumFrame.binCount)
    }
}
