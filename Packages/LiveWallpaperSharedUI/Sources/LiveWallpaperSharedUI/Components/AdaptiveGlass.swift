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

/// Border shape for `adaptiveGlassButton`. `capsule` is the default (labeled
/// buttons); `circle` is for single-glyph icon buttons, which read as a clean
/// equal-size cluster and match the macOS 26 Liquid Glass icon-control look.
public enum AdaptiveGlassButtonShape: Sendable {
    case capsule
    case circle
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
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(AdaptiveGlassSurfaceModifier(shape: shape, tint: tint, interactive: interactive))
    }

    func adaptiveGlassButton(
        _ prominence: AdaptiveGlassProminence = .regular,
        shape: AdaptiveGlassButtonShape = .capsule
    ) -> some View {
        modifier(AdaptiveGlassButtonModifier(prominence: prominence, shape: shape))
    }

    /// Liquid-glass chrome for a small badge floating over a thumbnail/preview
    /// (Playing, Experimental, Update, resolution, In Library …). macOS 26 uses
    /// native `glassEffect` with a legibility-preserving tint so white/coloured
    /// glyphs survive bright previews; older systems fall back to a tinted scrim
    /// with a specular top edge. Reduce Transparency forces an opaque fill.
    ///
    /// Capsule-shaped and zero-padding-adding, so it never changes a badge's
    /// footprint — only its backing.
    func thumbnailBadgeGlass(tint: Color = .black, opacity: Double = 0.6) -> some View {
        modifier(ThumbnailBadgeGlassModifier(tint: tint, opacity: opacity))
    }
}

private struct ThumbnailBadgeGlassModifier: ViewModifier {
    let tint: Color
    let opacity: Double

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Capsule().fill(tint.opacity(1)))
        } else if #available(macOS 26.0, *) {
            // Native glass already blurs + refracts; a lighter tint than the
            // fallback keeps the badge legible without going muddy.
            content.glassEffect(.regular.tint(tint.opacity(opacity * 0.6)), in: .capsule)
        } else {
            content.background {
                Capsule()
                    .fill(tint.opacity(opacity))
                    .overlay(
                        Capsule().strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.35), .white.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                    )
            }
        }
    }
}

private struct AdaptiveGlassSurfaceModifier: ViewModifier {
    let shape: AdaptiveGlassShape
    let tint: Color?
    let interactive: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var increaseContrast: Bool { colorSchemeContrast == .increased }

    private var tintOpacity: Double { colorScheme == .dark ? 0.20 : 0.11 }

    /// Boost the fallback tint opacity for interactive surfaces so that small
    /// circular / capsule selection targets (40-44pt) read clearly even against
    /// a busy wallpaper backdrop. Non-interactive surfaces keep the calmer value.
    private var fallbackTintOpacity: Double {
        if interactive {
            return colorScheme == .dark ? 0.30 : 0.20
        }
        return colorScheme == .dark ? 0.22 : 0.14
    }

    private var baseStrokeOpacity: Double {
        let base = colorScheme == .dark ? 0.32 : 0.22
        return increaseContrast ? min(base + 0.20, 0.6) : base
    }
    private var neutralStrokeOpacity: Double {
        let base = colorScheme == .dark ? 0.18 : 0.13
        return increaseContrast ? min(base + 0.20, 0.5) : base
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            // Honor Reduce Transparency on every OS — fallbackMaterial renders an
            // opaque window-background fill rather than native Liquid Glass.
            fallbackMaterial(content)
        } else if #available(macOS 26.0, *) {
            nativeGlass(content)
        } else {
            fallbackMaterial(content)
        }
    }

    @available(macOS 26.0, *)
    @ViewBuilder
    private func nativeGlass(_ content: Content) -> some View {
        let baseGlass: Glass = tint.map { .regular.tint($0.opacity(tintOpacity)) } ?? .regular
        let glass: Glass = interactive ? baseGlass.interactive() : baseGlass

        switch shape {
        case .circle:
            content
                .glassEffect(glass, in: .circle)
                .overlay { interactiveOutline(Circle()) }
        case .capsule:
            content
                .glassEffect(glass, in: .capsule)
                .overlay { interactiveOutline(Capsule()) }
        case .roundedRectangle(let radius):
            content
                .glassEffect(glass, in: .rect(cornerRadius: radius))
                .overlay { interactiveOutline(RoundedRectangle(cornerRadius: radius, style: .continuous)) }
        }
    }

    /// Thin contrast stroke layered on top of the native Liquid Glass on macOS 26+.
    /// Liquid Glass's intrinsic edge highlight is subtle; for interactive surfaces
    /// (buttons, tappable plates) we add a faint 0.5pt outline so users with low
    /// vision can locate hit areas. Non-interactive surfaces (decorative shells)
    /// stay unmodified to preserve the native refraction feel.
    @available(macOS 26.0, *)
    @ViewBuilder
    private func interactiveOutline<S: InsettableShape>(_ shape: S) -> some View {
        if interactive {
            shape
                .strokeBorder(
                    Color.primary.opacity(increaseContrast ? 0.20 : 0.10),
                    lineWidth: increaseContrast ? 0.75 : 0.5
                )
                .accessibilityHidden(true)
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
        let strokeColor: Color = tint?.opacity(baseStrokeOpacity)
            ?? Color.primary.opacity(neutralStrokeOpacity)
        let strokeWidth: CGFloat = increaseContrast ? 1.0 : 0.6

        return content
            .background {
                ZStack {
                    if reduceTransparency {
                        shape.fill(Color(nsColor: .windowBackgroundColor))
                        if let tint {
                            shape.fill(tint.opacity(fallbackTintOpacity))
                        }
                    } else {
                        if let tint {
                            shape.fill(tint.opacity(fallbackTintOpacity))
                        }
                        shape.fill(.regularMaterial)
                    }
                }
            }
            .overlay {
                shape.strokeBorder(strokeColor, lineWidth: strokeWidth)
            }
            .contentShape(shape)
    }
}

private struct AdaptiveGlassButtonModifier: ViewModifier {
    let prominence: AdaptiveGlassProminence
    let shape: AdaptiveGlassButtonShape

    private var borderShape: ButtonBorderShape {
        switch shape {
        case .capsule: return .capsule
        case .circle:  return .circle
        }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            switch prominence {
            case .regular:
                content.buttonStyle(.glass).buttonBorderShape(borderShape)
            case .prominent:
                content.buttonStyle(.glassProminent).buttonBorderShape(borderShape)
            }
        } else {
            switch prominence {
            case .regular:
                content
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .buttonBorderShape(borderShape)
            case .prominent:
                content
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .buttonBorderShape(borderShape)
            }
        }
    }
}
