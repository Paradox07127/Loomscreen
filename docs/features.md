# Feature Guide (Detailed)

This guide maps feature blocks to the actual UI and the current implementation behavior in the repository.

Authoritative feature gate: [ProductCapabilities.swift](../Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift).

## 0) App surfaces at a glance

- **Menu bar quick controls** (`LiveWallpaper/Views/MenuBarContent.swift`)
  - Open menu, add wallpaper for active/default display.
  - Global on/off toggle.
  - Per-display quick status, previous/next for playlist, play/pause per display.
  - Reload all wallpapers.
  - Live usage strip (CPU / GPU / RAM / TEMP).
- **Settings window** (`LiveWallpaper/Views/ContentView.swift`)
  - Sidebar entries by feature surface and hardware/runtime capability.
  - `Displays` + per-display config pages.
  - `Bookmarks`, `Apple Aerials`, and optional `Steam Workshop`.
  - `System Monitor` panel in sidebar footer (runtime status).

## 1) Per-display workflow

Entry path: `Settings` → sidebar `Displays` → choose a display row → detail page.

### Wallpaper type switcher

- `Video`, `Web`, `Metal Shader`, `Wallpaper Engine Scene` options are shown per SKU.
- Switching type triggers runtime migration and resets draft UI to match target type.
- In Lite, shader/scene types are not exposed.

### Preview and assignment

In the main detail area (`ScreenDetailPreviewArea`), each type provides a source entry path:

- **Video**: file picker (`NSOpenPanel`) accepts supported video files.
- **Web**: file picker for webpage file or folder, with folder index auto-detection.
- **Scene** (`Pro`): import scene folder when choosing **Scene** in type picker.
- **Drag & drop** onto a screen row also maps supported source types directly.
- One-tap actions for reload/clear/re-apply to all displays are available from the header controls.

### Runtime metadata shown in header

The header shows:

- Resolution and refresh of selected screen
- Wallpaper activity state (active/paused/error/inactive)
- Bookmark toggle (for bookmarkable content)

## 2) Playback and source-specific controls

## 2.1 Playback controls (`ScreenDetail/ScreenDetailInspectorPanel`)

- Master playback controls are shared across types:
  - mute + volume
  - frame rate limit (video/shader/scene)
  - video display mode: per-display vs span-all-displays
  - scene fit mode
  - lock-screen sync toggle (video only)
- Scene-specific controls:
  - cursor-follow/parallax
  - click-capture with one-time warning

## 2.2 Video controls in practice

- Loop source and cache strategy:
  - RAM preload budget per screen (`MB`) with max budget displayed.
  - Slider and fit mode stored in screen config.
- Playback speed and fit mode are exposed in preview controls as well.
- Per-screen status is fed from runtime summary and used for status icons.

## 3) Playlists (视频列表)

Entry path: screen detail → video inspector (`PlaylistSection.swift`).

- Built-in list of saved video bookmarks for that display.
- Reorder by drag handles.
- Controls:
  - Add files
  - Remove entry
  - Previous / Next
  - Shuffle
  - Auto-rotate interval (`minutes`) with persistence and auto-play
- Apply behavior:
  - apply to current display
  - apply to all displays (if multiple exist)

## 4) Time-of-day scheduling

Entry path: screen detail → schedule section in inspector.

- 24-hour slot timeline + list editor.
- Add slot from presets or custom free-range picker.
- Slot conflict detection prevents overlap; conflicted slots are highlighted.
- Each slot holds a selected bookmark + time range.
- If none are matched at a given hour, runtime restores default primary wallpaper.

Implementation entry:

- `ScheduleSection.swift` (editor / conflict handling)
- `SchedulePolicy.swift` (time-range overlap and active-slot decision logic)
- `WallpaperAutomationCoordinator.swift` (minute-based periodic evaluation)

## 5) Effects and scene content

### Particles and environment (`ScreenDetailInspectorPanel`)

- Particle preset and density.
- Weather-reactive switch + live weather badge.
- Weather data source from settings:
  - off / system location / manual location.

### Color / scene properties

- Color adjustment controls (temperature/brightness/contrast/saturation/gain/etc., where available) in inspector panel.
- Scene custom settings cards for supported imported projects (schema-driven) and scene assets.

### Pro-only rendering pipeline

- Metal shader gallery + custom import (`.lwshader`/`.metal`).
- Wallpaper Engine scene renderer and project import flow.
- Workshop preview/download and online browse (direct-distribution Pro only).

## 6) Libraries and collections

### Bookmarks (`BookmarksLibraryView.swift`)

- Grid with type filter + search.
- Apply bookmark to one display or all displays.
- Rename/delete saved bookmarks.
- Bookmarks persist in local store (`BookmarkStore`).

### Apple Aerials (`AppleAerialsLibraryView.swift`)

- Connects local Apple Aerials library.
- Search/filter/refresh.
- Grid apply to one / all displays.
- Handles unauthorized/missing library states with guided actions.

### Workshop (Pro + Direct Distribution only)

- Library + online browser (`WorkshopPaneView.swift`).
- Install by:
  - linking SteamCMD/Steam account for online download flow, or
  - local folder import flow from scene library.
- Browse filters, pagination, API key requirement, age tags, maturity blur.
- Per-item inspect panel + deep-link aware.
- Settings:
  - API key
  - SteamCMD readiness
  - Engine asset link/download/updates
  - downloaded filter toggles

## 7) Global settings and shortcuts

Entry path: Settings `General / Shortcuts` tabs.

- Behavior toggles:
  - pause in fullscreen
  - pause in game/low power
  - pause on battery
  - pause on window occlusion
  - pause on launch etc.
- Performance options:
  - RAM preload budget
  - adaptive frame rate (`Pro`)
  - lock screen snapshot
- App exceptions list (pause set excludes).
- Weather location preference.
- Global shortcuts tab:
  - per-action capture, clear, reset
  - master enable switch
- About/Utility:
- Export/import configuration bundles (`.lwconfig`)
- Logs, bug report generation
- Start-at-login and menu-bar dock visibility

## 8) System behavior and performance model

- Global on/off in menu bar keeps app resident.
- Wallpaper automation runs schedule/playlist rotation in minute cadence.
- Full-screen/game-window/battery behavior controls are centralized in manager/policy layers.
- Lite update check:
  - launch-time GitHub Releases check + manual check in About tab.
  - no background polling service and no public auto-install updater yet.
- Pro currently has no in-app updater.

## 9) Security and privacy

- No telemetry.
- Workshop API key stored in local Keychain only (no iCloud sync).
- Web content rendered in sandboxed source contexts.
- Apple Aerials/files access uses scoped bookmark/security model.

## 10) Known constraints (implementation-aligned)

- Wallpaper Engine scenes require scene support availability and are omitted in Lite builds.
- Weather effects and workshop browsing are gated by runtime feature flags.
- Full-screen pause and occlusion detection reduce power but can pause visual continuity.
- Configuration backups keep references to source files, not media copies.

## 11) Where to start reading by code

- Core capability gating:  
  `Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift`
- Screen orchestration / runtime model:  
  `LiveWallpaper/ScreenManager.swift`
- Screen detail UI composition:  
  `LiveWallpaper/Views/ScreenDetail*`
- Menu bar host and controls:  
  `LiveWallpaper/Views/MenuBarContent.swift`
- Settings surfaces:
  `LiveWallpaper/Views/GeneralSettingsView.swift`
  `LiveWallpaper/Views/Settings/*.swift`
- Workshop stack:
  `LiveWallpaper/Views/Workshop/*.swift`
