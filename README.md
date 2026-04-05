# LiveWallpaper

A macOS menu bar application that plays video files as animated desktop wallpapers across multiple displays.

## Features

- **Video Wallpaper** — MP4, MOV, AVI, MPEG, QuickTime as desktop background
- **Multi-Display** — Independent configuration per screen
- **Power Aware** — Auto-pause on battery, configurable threshold, smart resume
- **Playback Control** — Speed (0.5x-2.0x), frame rate limiting, fit modes (Fill/Fit/Stretch)
- **Menu Bar** — Quick controls, per-screen status, keyboard shortcuts
- **Zero Dependencies** — Pure Apple-native frameworks

## Requirements

- macOS 15.2 (Sequoia) or later
- Xcode 16.2+ (for building)

## Getting Started

1. Open `LiveWallpaper.xcodeproj` in Xcode
2. Build and run (Cmd+R)
3. Click the menu bar icon → select a display → choose a video

## Documentation

- [Architecture](docs/architecture.md) — System design, project structure, frameworks, technical details
- [Competitive Analysis](docs/competitive-analysis.md) — Market landscape, feature gaps, technical approaches
- [Tech Research](docs/tech-research.md) — macOS new APIs, 20+ open-source projects, visual effects integration
- [Feature Adoption Report](docs/feature-adoption-report.md) — 22 features from 30+ projects, prioritized with effort estimates
- [Roadmap](docs/roadmap.md) — Feature status, planned improvements, prioritized backlog
