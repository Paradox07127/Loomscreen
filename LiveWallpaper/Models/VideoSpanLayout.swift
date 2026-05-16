import CoreGraphics

struct VideoSpanRenderConfiguration: Equatable, Sendable {
    let canvasFrame: CGRect
    let screenFrame: CGRect

    var canvasFrameInScreenCoordinates: CGRect {
        CGRect(
            x: canvasFrame.minX - screenFrame.minX,
            y: canvasFrame.minY - screenFrame.minY,
            width: canvasFrame.width,
            height: canvasFrame.height
        )
    }
}

enum VideoSpanLayout {
    struct Entry: Equatable, Sendable {
        let screenID: CGDirectDisplayID
        let frame: CGRect
    }

    static func renderConfigurations(
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
