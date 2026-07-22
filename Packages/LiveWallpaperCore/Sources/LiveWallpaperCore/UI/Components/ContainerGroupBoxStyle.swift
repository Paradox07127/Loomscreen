import SwiftUI

public struct ContainerGroupBoxStyle: GroupBoxStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
            configuration.content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .adaptiveGlassSurface(.roundedRectangle(12))
    }
}
