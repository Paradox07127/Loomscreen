import SwiftUI

public struct ContainerGroupBoxStyle: GroupBoxStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            configuration.label
            configuration.content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .adaptiveGlassSurface(.roundedRectangle(12))
    }
}
