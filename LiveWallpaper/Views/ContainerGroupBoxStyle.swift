import SwiftUI

struct ContainerGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
            configuration.content
        }
        .padding(4)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}
