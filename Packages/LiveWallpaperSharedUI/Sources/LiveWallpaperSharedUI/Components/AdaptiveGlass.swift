import SwiftUI

public enum AdaptiveGlassShape: Equatable, Sendable {
    case circle
    case capsule
    case roundedRectangle(CGFloat)
}

public enum AdaptiveGlassProminence: Sendable {
    case regular
    case prominent
}

public struct AdaptiveGlassContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

public extension View {
    func adaptiveGlassSurface(
        _ shape: AdaptiveGlassShape = .roundedRectangle(12),
        tint: Color = .secondary,
        interactive: Bool = false
    ) -> some View {
        modifier(AdaptiveGlassSurfaceModifier(shape: shape, tint: tint, interactive: interactive))
    }

    func adaptiveGlassButton(_ prominence: AdaptiveGlassProminence = .regular) -> some View {
        modifier(AdaptiveGlassButtonModifier(prominence: prominence))
    }
}

private struct AdaptiveGlassSurfaceModifier: ViewModifier {
    let shape: AdaptiveGlassShape
    let tint: Color
    let interactive: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var tintOpacity: Double { colorScheme == .dark ? 0.20 : 0.11 }
    private var fallbackTintOpacity: Double { colorScheme == .dark ? 0.22 : 0.14 }
    private var fallbackStrokeOpacity: Double { colorScheme == .dark ? 0.32 : 0.22 }
    private var neutralStrokeOpacity: Double { colorScheme == .dark ? 0.18 : 0.13 }
    private var shadowOpacity: Double { colorScheme == .dark ? 0.22 : 0.08 }

    private var hasSemanticTint: Bool { tint != .secondary }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            nativeGlass(content)
        } else {
            fallbackMaterial(content)
        }
    }

    @available(macOS 26.0, *)
    @ViewBuilder
    private func nativeGlass(_ content: Content) -> some View {
        switch shape {
        case .circle:
            if interactive {
                content.glassEffect(.regular.tint(tint.opacity(tintOpacity)).interactive(), in: .circle)
            } else {
                content.glassEffect(.regular.tint(tint.opacity(tintOpacity)), in: .circle)
            }
        case .capsule:
            if interactive {
                content.glassEffect(.regular.tint(tint.opacity(tintOpacity)).interactive(), in: .capsule)
            } else {
                content.glassEffect(.regular.tint(tint.opacity(tintOpacity)), in: .capsule)
            }
        case .roundedRectangle(let radius):
            if interactive {
                content.glassEffect(.regular.tint(tint.opacity(tintOpacity)).interactive(), in: .rect(cornerRadius: radius))
            } else {
                content.glassEffect(.regular.tint(tint.opacity(tintOpacity)), in: .rect(cornerRadius: radius))
            }
        }
    }

    @ViewBuilder
    private func fallbackMaterial(_ content: Content) -> some View {
        switch shape {
        case .circle:
            decorate(content, shape: Circle())
        case .capsule:
            decorate(content, shape: Capsule())
        case .roundedRectangle(let radius):
            decorate(content, shape: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    private func decorate<S: InsettableShape>(_ content: Content, shape: S) -> some View {
        let strokeColor: Color = hasSemanticTint
            ? tint.opacity(fallbackStrokeOpacity)
            : Color.primary.opacity(neutralStrokeOpacity)

        return content
            .background {
                if hasSemanticTint {
                    shape.fill(tint.opacity(fallbackTintOpacity))
                }
            }
            .background(.regularMaterial, in: shape)
            .overlay {
                shape.strokeBorder(strokeColor, lineWidth: 0.6)
            }
            .shadow(color: Color.black.opacity(shadowOpacity), radius: 5, y: 1)
    }
}

private struct AdaptiveGlassButtonModifier: ViewModifier {
    let prominence: AdaptiveGlassProminence

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            switch prominence {
            case .regular:
                content.buttonStyle(.glass)
            case .prominent:
                content.buttonStyle(.glassProminent)
            }
        } else {
            switch prominence {
            case .regular:
                content
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .buttonBorderShape(.capsule)
            case .prominent:
                content
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .buttonBorderShape(.capsule)
            }
        }
    }
}
