import CoreGraphics

public struct VideoSpanRenderConfiguration: Equatable, Sendable {
    public let canvasFrame: CGRect
    public let screenFrame: CGRect

    public init(canvasFrame: CGRect, screenFrame: CGRect) {
        self.canvasFrame = canvasFrame
        self.screenFrame = screenFrame
    }

    public var canvasFrameInScreenCoordinates: CGRect {
        CGRect(
            x: canvasFrame.minX - screenFrame.minX,
            y: canvasFrame.minY - screenFrame.minY,
            width: canvasFrame.width,
            height: canvasFrame.height
        )
    }
}

public enum VideoSpanLayout {
    public struct Entry: Equatable, Sendable {
        public let screenID: CGDirectDisplayID
        public let frame: CGRect

        public init(screenID: CGDirectDisplayID, frame: CGRect) {
            self.screenID = screenID
            self.frame = frame
        }
    }

    public static func renderConfigurations(
        for entries: [Entry]
    ) -> [CGDirectDisplayID: VideoSpanRenderConfiguration] {
        let validEntries = entries.filter { !$0.frame.isEmpty }
        guard validEntries.count > 1 else { return [:] }

        let canvasFrame = validEntries
            .map(\.frame)
            .dropFirst()
            .reduce(validEntries[0].frame) { $0.union($1) }

        return Dictionary(uniqueKeysWithValues: validEntries.map { entry in
            (
                entry.screenID,
                VideoSpanRenderConfiguration(
                    canvasFrame: canvasFrame,
                    screenFrame: entry.frame
                )
            )
        })
    }
}
