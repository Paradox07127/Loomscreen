import SwiftUI

struct ScreenDetailLoadingView: View {
    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
                .padding(.bottom, 8)
            Text("Loading video...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct ScreenDetailEmptyStateView: View {
    let isDraggingOver: Bool
    let selectVideo: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: isDraggingOver ? "arrow.down.doc.fill" : "film")
                .font(.system(size: 60))
                .foregroundStyle(isDraggingOver ? Color.green : Color.accentColor)
                .padding(.bottom, 10)
                .contentTransition(.symbolEffect(.replace))

            Text(isDraggingOver ? "Drop Video Here" : "No Video Selected")
                .font(.title2)
                .fontWeight(.medium)
                .contentTransition(.opacity)

            if !isDraggingOver {
                Button(action: selectVideo) {
                    Label("Select Video File", systemImage: "plus.circle.fill")
                        .font(.headline)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.top, 10)
                .accessibilityLabel(Text("Select video file"))
                .accessibilityHint(Text("Opens a file picker to choose a wallpaper video"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(NSColor.windowBackgroundColor).opacity(isDraggingOver ? 0.8 : 0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isDraggingOver ? Color.green : Color.clear,
                    style: StrokeStyle(lineWidth: 3, dash: isDraggingOver ? [] : [8])
                )
        )
        .animation(.smooth(duration: 0.25), value: isDraggingOver)
    }
}
