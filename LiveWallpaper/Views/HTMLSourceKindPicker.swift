import SwiftUI

struct HTMLSourceKindPicker: View {
    @Binding var selection: HTMLSourceKind

    var body: some View {
        Picker("Source", selection: $selection) {
            ForEach(HTMLSourceKind.allCases) { kind in
                Label(kind.labelKey, systemImage: kind.icon).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
