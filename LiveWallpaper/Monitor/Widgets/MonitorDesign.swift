import SwiftUI

/// Shared visual language for the Monitor v2 widget board — "Ambient Instrument":
/// a matte warm-graphite panel with restrained OKLCH signal colours. Every token
/// here is ported 1:1 from `.claude/plan/monitor-design/index.html` `:root`; the
/// arc/gauge geometry and band thresholds come from that file's render JS.
///
/// Colours are produced from their source OKLCH values through the real
/// OKLCH→OKLab→linear-sRGB(D65) transform, then handed to SwiftUI as a
/// `.sRGBLinear` colour so SwiftUI applies the sRGB transfer curve itself. This
/// keeps the palette anchored to the design source instead of hand-copied hex.
enum MonitorDesign {

    // MARK: - Colour space

    /// OKLCH → sRGB (gamma-encoded 0…1 components). Matrices are Björn Ottosson's
    /// reference OKLab constants (bottosson.github.io/posts/oklab). `clampGamut`
    /// clips negative/over-range linear components before encoding — the design
    /// palette stays inside sRGB, so clipping only guards rounding at the edges.
    static func oklch(_ l: Double, _ c: Double, _ h: Double, alpha: Double = 1) -> Color {
        let (r, g, b) = linearSRGB(l: l, c: c, h: h)
        return Color(.sRGBLinear, red: r, green: g, blue: b, opacity: alpha)
    }

    /// Linear-sRGB (D65) components for an OKLCH triple, gamut-clamped to 0…1.
    /// Exposed for the unit tests, which compare against gamma-encoded references.
    static func linearSRGB(l: Double, c: Double, h: Double) -> (Double, Double, Double) {
        let hr = h * .pi / 180
        let a = c * cos(hr)
        let bb = c * sin(hr)

        // OKLab → LMS' (nonlinear), cube → LMS
        let lp = l + 0.3963377774 * a + 0.2158037573 * bb
        let mp = l - 0.1055613458 * a - 0.0638541728 * bb
        let sp = l - 0.0894841775 * a - 1.2914855480 * bb
        let lc = lp * lp * lp
        let mc = mp * mp * mp
        let sc = sp * sp * sp

        // LMS → linear sRGB
        let r =  4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
        let g = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
        let b = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc
        return (clampUnit(r), clampUnit(g), clampUnit(b))
    }

    /// Gamma-encoded sRGB components — the values the linear pipeline resolves to
    /// on screen. Pure helper so tests can assert against published hex.
    static func gammaSRGB(l: Double, c: Double, h: Double) -> (Double, Double, Double) {
        let (r, g, b) = linearSRGB(l: l, c: c, h: h)
        return (encodeGamma(r), encodeGamma(g), encodeGamma(b))
    }

    private static func clampUnit(_ x: Double) -> Double { min(1, max(0, x)) }

    private static func encodeGamma(_ x: Double) -> Double {
        let c = clampUnit(x)
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    // MARK: - Neutrals (warm graphite — not blue-black)

    static let bg0 = oklch(0.15, 0.011, 74)
    static let bg1 = oklch(0.185, 0.012, 74)
    static let bg2 = oklch(0.225, 0.014, 74)
    static let bg3 = oklch(0.265, 0.015, 74)

    static let hairline = oklch(0.34, 0.016, 74)      // --line
    static let hairlineHi = oklch(0.46, 0.02, 74)     // --line-hi

    static let inkPrimary = oklch(0.93, 0.012, 84)    // --ink
    static let inkMuted = oklch(0.68, 0.015, 78)      // --ink-dim
    static let inkFaint = oklch(0.505, 0.014, 76)     // --ink-faint

    static let track = oklch(0.30, 0.01, 74)          // --track
    static let track2 = oklch(0.285, 0.01, 74)        // --track-2

    // MARK: - Signal colours (the only saturated hues — reserved for state)

    static let signalAmber = oklch(0.80, 0.128, 78)   // --run  : running / load
    static let signalCoral = oklch(0.705, 0.165, 34)  // --need : needs you / critical
    static let signalSage = oklch(0.76, 0.10, 158)    // --done : completed / healthy
    static let signalRed = oklch(0.62, 0.19, 26)      // --err  : error
    static let signalIdle = oklch(0.56, 0.010, 76)    // --idle : idle / neutral
    static let signalSteel = oklch(0.68, 0.05, 235)   // --cool : secondary metric

    /// The steel used specifically as the *low* load band — a touch deeper/cooler
    /// than `signalSteel` (from `loadBandColor` in the mock JS).
    static let loadSteel = oklch(0.62, 0.045, 250)

    // MARK: - Panel material

    /// Matte instrument-surface fill. The HTML uses a 178° gradient between two
    /// translucent graphites; the native panel paints this as a top→bottom fill.
    static let panelFillTop = oklch(0.212, 0.013, 74, alpha: 0.72)
    static let panelFillBottom = oklch(0.176, 0.012, 74, alpha: 0.60)
    static let panelStroke = oklch(0.40, 0.018, 74, alpha: 0.55)      // --panel-line
    /// Faint top-edge highlight (`--panel-hi` = white @ 5.5%).
    static let panelTopHighlight = Color.white.opacity(0.055)
    /// Board wash the panels sit on (page background under a widget).
    static let boardWash = oklch(0.135, 0.010, 74)

    // MARK: - Load band mapping

    /// Utilisation → colour band, the ONE shared mapping every gauge/sparkline
    /// uses (mock JS `loadBandColor`): steel <0.4, amber 0.4…0.8, coral >0.8.
    /// `pct` is a fraction 0…1.
    static func loadBandColor(_ pct: Double) -> Color {
        if pct > 0.8 { return signalCoral }
        if pct >= 0.4 { return signalAmber }
        return loadSteel
    }

    /// Same thresholds as `loadBandColor` but returns the band identity — handy
    /// for tests and callers that need the semantic name, not just the colour.
    enum LoadBand { case low, mid, high }
    static func loadBand(_ pct: Double) -> LoadBand {
        if pct > 0.8 { return .high }
        if pct >= 0.4 { return .mid }
        return .low
    }

    /// Cool→warm temperature ramp (sage 158° → amber 78° → coral 30°), a scale
    /// deliberately distinct from the load-amber so "hot" never reads as "busy".
    /// `celsius` maps 34 °C (cool) … 70 °C (hot). Mirrors mock JS `tempColor`.
    static func temperatureColor(_ celsius: Double) -> Color {
        let t = min(1, max(0, (celsius - 34) / (70 - 34)))
        let l: Double, c: Double, h: Double
        if t < 0.5 {
            let k = t / 0.5
            l = 0.74 - 0.02 * k; c = 0.09 + 0.03 * k; h = 158 - 80 * k
        } else {
            let j = (t - 0.5) / 0.5
            l = 0.72 - 0.02 * j; c = 0.12 + 0.045 * j; h = 78 - 48 * j
        }
        return oklch(l, c, h)
    }

    // MARK: - Typography
    //
    // SPEC §3.0: at most three type sizes per widget, driven by a cell-height
    // base. Hero numerals are SF Rounded, semibold, tabular. Callers compose the
    // hero with `.monospacedDigit()` so readouts don't jitter.
    //
    //   hero  = clamp(24, cellH*0.36, 46)
    //   sub   = 0.52 × hero
    //   label = clamp(9,  cellH*0.10, 12)   (uppercase, tracked)
    //   cap   = clamp(10, cellH*0.11, 13)

    static func heroFont(size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    static func subFont(size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    /// Whisper label — uppercase, tracked; use `.tracking(labelTracking)` at call site.
    static func labelFont(size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    static func captionFont(size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .rounded)
    }

    static func microFont(size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    /// Tracking (letter-spacing) for the uppercase whisper labels — 0.12em in the
    /// mock, expressed here in points relative to the label size.
    static func labelTracking(size: CGFloat) -> CGFloat { size * 0.12 }

    // MARK: - Type scale

    /// Resolve the ≤3 type sizes from a cell height, matching the mock's clamps.
    struct TypeScale {
        let hero: CGFloat
        let sub: CGFloat
        let label: CGFloat
        let caption: CGFloat

        init(cellHeight: CGFloat) {
            hero = min(46, max(24, cellHeight * 0.36))
            sub = hero * 0.52
            label = min(12, max(9, cellHeight * 0.10))
            caption = min(13, max(10, cellHeight * 0.11))
        }
    }

    // MARK: - Metrics

    /// HIG-derived content inset (16-pt-equiv), used for text/content.
    static let contentInsetH: CGFloat = 16
    static let contentInsetV: CGFloat = 11
    /// 11-pt-equiv inset for graphical shapes sitting inside the panel.
    static let graphicalInset: CGFloat = 10

    static let hairlineWidth: CGFloat = 1

    /// Radius floor for the small inner elements inside a widget (Fleet's session
    /// cards, chips). The OUTER panel radius is the board's fixed Apple
    /// desktop-widget radius (`MonitorBoardGeometry.appleCornerRadius`), threaded
    /// down per render.
    static let cornerRadiusMin: CGFloat = 9
}

// MARK: - Annotation chip (shared board-wide aesthetic)

extension View {
    /// A faint capsule "chip" (matte fill + hairline) that contains a small
    /// annotation — a peak tag, status pill, legend, sensor readout, or floating
    /// micro-label. The board-wide convention (established on CPU): little
    /// annotations read as contained tags rather than loose text. Padding is
    /// deliberately tiny so applying it doesn't reflow the surrounding layout.
    func monitorChip(_ scale: MonitorDesign.TypeScale) -> some View {
        self
            .padding(.horizontal, scale.label * 0.5)
            .padding(.vertical, scale.label * 0.24)
            .background(
                Capsule(style: .continuous)
                    .fill(MonitorDesign.bg2.opacity(0.55))
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder(MonitorDesign.hairlineHi.opacity(0.5), lineWidth: 1))
            )
    }
}
