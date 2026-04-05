# LiveWallpaper

A macOS menu bar application that plays video, HTML, and Metal shader content as animated desktop wallpapers across multiple displays.

## Features

- **Multi-Type Wallpapers** — Video (MP4/MOV/AVI), HTML/Web (WKWebView), Metal shader (procedural GPU art)
- **Multi-Display** — Independent configuration per screen
- **Real-Time Effects** — CIFilter pipeline: blur, saturation, brightness, color temperature, vignette
- **Particle Overlays** — SpriteKit: snow, rain, bokeh, fireflies, falling leaves
- **Power Aware** — Auto-pause on battery, resolution scaling, full-screen app detection
- **Playback Control** — Speed (0.5x-2.0x), frame rate limiting, fit modes (Fill/Fit/Stretch)
- **System Monitoring** — CPU, GPU, memory, thermal state, render FPS
- **Liquid Glass UI** — macOS 26 native design system
- **Zero Dependencies** — Pure Apple-native frameworks

## Requirements

- macOS 26.0 (Tahoe) or later
- Apple Silicon recommended
- Xcode 16.2+ (for building)

## Getting Started

1. Open `LiveWallpaper.xcodeproj` in Xcode
2. Build and run (Cmd+R)
3. Click the menu bar icon → select a display → choose a video

## Documentation

- [Architecture](docs/architecture.md) — System design, project structure, frameworks
- [Competitive Analysis](docs/competitive-analysis.md) — Market landscape, feature gaps
- [Tech Research](docs/tech-research.md) — macOS APIs, 20+ open-source projects, visual effects
- [Feature Adoption Report](docs/feature-adoption-report.md) — 22 features from 30+ projects
- [Roadmap](docs/roadmap.md) — Feature status, planned improvements
