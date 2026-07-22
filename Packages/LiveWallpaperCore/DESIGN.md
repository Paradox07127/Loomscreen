# LiveWallpaper — Design System Contract

The visual contract for every SwiftUI view in the app (Pro + Lite SKUs). All
tokens live in `DesignTokens` (`LiveWallpaperCore/UI/Tokens`). New views
**must** use tokens — no inline magic numbers, fonts, or colors.

## Visual language (locked 2026-06-05)

- **Content cards** (wallpaper / library tiles) → flat (`GalleryTileChrome`). No glass: the card is content, not chrome.
- **Floating chrome** (toolbars, filter ribbon, inspector, sheets, toasts, menu-bar dropdown) → glass (`AdaptiveGlass`).
- **Small accents** (type pills, badges, selection, segmented controls) → liquid-glass (`TypeBadge`, `thumbnailBadgeGlass`).
- Apple-HIG aligned, modern, restrained. Default SF font design (no `.rounded`) to sit cleanly next to native chrome.

## Typography — `DesignTokens.Typography`

24 ad-hoc sizes collapse into 7 roles (+3 emphasized variants). Dynamic-Type
styles auto-scale with accessibility; `badge` is the only fixed size.

| Token | Font | ≈pt | Use | Absorbs |
| --- | --- | --- | --- | --- |
| `badge` | `.caption2.semibold` | 10 | type pills, corner/thumbnail badges, status chips | 6, 8, 9, 10 |
| `caption` | `.caption` | 10 | metadata, helper text | 11 |
| `captionEmphasized` | `.caption.semibold` | 10 | emphasized metadata | — |
| `body` | `.body` | 13 | body copy, form labels | 12, 13 |
| `bodyEmphasized` | `.body.semibold` | 13 | card / list-row titles | 13 (semibold) |
| `sectionTitle` | `.title3.semibold` | 15 | group & inspector headers | 14, 15, 16 |
| `pageTitle` | `.title2` | 17 | page / nav / sheet titles | 17, 18, 20, 22 |
| `hero` | `.largeTitle` | 26 | empty-state / onboarding | 24–56 |
| `metric` | `.caption.monospacedDigit()` | 10 | inline numeric readouts: slider %, fps, gauges | numeric readouts |
| `metricEmphasized` | `.callout.monospaced.semibold.monospacedDigit()` | 12 | compact headline metrics in menu/status chrome | 12 (semibold monospaced) |
| `code` | `.body.monospaced` | 13 | paths, commands, IDs, technical text | monospaced text |
| `codeCaption` | `.caption.monospaced` | 10 | dense technical text: log lines, paths, IDs | caption-sized monospaced |

> ≈pt = measured macOS text-style metrics at default size (caption1/caption2 = 10, subheadline = 11, callout = 12, body = 13). Lint tooling and exact-equivalence judgments must use these measured values.

## Color — `DesignTokens.Colors`

System `NSColor`-backed → automatic light/dark + Increase Contrast.

| Token | Source | Use |
| --- | --- | --- |
| `pageBackground` | `.windowBackgroundColor` | window canvas |
| `surfaceRaised` | `.controlBackgroundColor` | cards, fields, raised controls |
| `surfaceSunken` | `.underPageBackgroundColor` | sidebars, wells |
| `textPrimary` | `.labelColor` | titles, primary content |
| `textSecondary` | `.secondaryLabelColor` | captions, metadata |
| `textTertiary` | `.tertiaryLabelColor` | placeholders, disabled — never body copy (low contrast) |
| `separator` | `.separatorColor` | dividers, hairlines |
| `accent` | `.controlAccentColor` | selection, highlights |
| `Status.active` | `.systemGreen` | "in use" / running |
| `Status.warning` | `.systemOrange` | "won't run" blockers |
| `Status.caution` | `.systemYellow` | "needs deps" / pending |
| `Status.danger` | `.systemRed` | errors, destructive |
| `Gauge.low/medium/high` | muted green/amber/red | ring-gauge dashboards (calmer than Status) |

## Spacing & corners (existing)

`Spacing` xxs 2 · xs 4 · sm 8 · md 12 · lg 16 · xl 24 · xxl 32
`Corner` sm 6 · md 10 · lg 14 (content cards) · xl 18 (floating chrome)

## Hard rules

1. **No inline fonts** for text. Never `.font(.system(size:))` / `.font(.custom())` on `Text`/`Label` — use `DesignTokens.Typography`. (SF Symbol glyph sizing is exempt: a standalone `Image(systemName:)` may use `.font(.system(size:))` for precise sizing, or adopt a Typography token when it sits inline with text so the two scale together.)
2. **No literal colors** for semantic elements. No `.orange` / `.yellow` / `.white` / `Color(red:…)` — use `DesignTokens.Colors`.
3. **Tabular digits** for live-updating numbers — use `Typography.metric` (or `.monospacedDigit()`) so columns don't jitter.
4. **Adaptive surfaces.** Use `AdaptiveGlass` / `GalleryTileChrome`, never hardcoded `.ultraThinMaterial`; it honors Reduce Transparency.
5. **Align to the grid.** Paddings/offsets come from `Spacing.*`, radii from `Corner.*` — no stray numbers.
6. **No color-only status.** A `Status.*` color must always be paired with text or a distinct glyph — never carry meaning by hue alone (WCAG 1.4.1).
7. **Glass contrast.** Don't put light text directly on a raw high-luminance `Status.*` fill; let `thumbnailBadgeGlass` / `AdaptiveGlass` manage the tint so text stays ≥4.5:1.
