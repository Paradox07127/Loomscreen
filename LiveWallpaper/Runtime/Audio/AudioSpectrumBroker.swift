import os

/// Transfers spectrum frames from realtime capture to renderer and web consumers.
/// Publishing drops on contention to prevent the audio callback from blocking.
final class AudioSpectrumBroker: Sendable {
    private struct State {
        var left: [Float]
        var right: [Float]
        var timestampNanos: UInt64
    }

    private let lock = OSAllocatedUnfairLock(
        initialState: State(
            left: [Float](repeating: 0, count: AudioSpectrumFrame.binCount),
            right: [Float](repeating: 0, count: AudioSpectrumFrame.binCount),
            timestampNanos: 0
        )
    )

    func publish(_ frame: AudioSpectrumFrame) {
        lock.withLockIfAvailable { state in
            Self.copyChannel(frame.left, into: &state.left)
            Self.copyChannel(frame.right, into: &state.right)
            state.timestampNanos = frame.timestampNanos
        }
    }

    func snapshot() -> AudioSpectrumFrame {
        lock.withLock { state in
            // Sanitizing init copies out of the locked storage so the returned
            // frame owns independent buffers (no shared ref → no publish-time COW).
            AudioSpectrumFrame(
                left: state.left,
                right: state.right,
                timestampNanos: state.timestampNanos
            )
        }
    }

    func resetToSilence() {
        lock.withLock { state in
            for index in state.left.indices { state.left[index] = 0 }
            for index in state.right.indices { state.right[index] = 0 }
            state.timestampNanos = 0
        }
    }

    private static func copyChannel(_ source: [Float], into target: inout [Float]) {
        for index in target.indices {
            let value = index < source.count ? source[index] : 0
            target[index] = AudioSpectrumFrame.clamp(value)
        }
    }
}
