# LiveWallpaper — Architecture

One-page reference for new contributors.

## Layered structure

```
Views/         SwiftUI screens — never own state, always read via Environment
  └─ Onboarding/, ScreenDetail/, BookmarksLibraryView, AppleAerialsLibraryView, MenuBarContent

Runtime/       Live wallpaper sessions + per-screen lifecycle
  └─ WallpaperRuntimeSession protocol, VideoWallpaperSession, AmbientWallpaperSession
  └─ AmbientWallpaperSessionBuilder, WallpaperAssetReadinessWork
  └─ VideoEffectsApplicationService (per-screen CIFilter composition cache)

Policies/      Pure functions — "given X, decide Y" — fully unit-tested
  └─ WallpaperPolicyEngine, SchedulePolicy, PlaylistPolicy, WeatherReactivePolicy,
     WallpaperAutomationCoordinator, PowerPolicyController, LockScreenSnapshotCoordinator

Infrastructure/ Persistence, OS bridges, sandbox bookmarks
  └─ DisplayRegistry, WallpaperConfigurationStore, BookmarkStore, TrustedHostStore,
     AppleAerialsLibrary, PlayableVideoLoader, DesktopPictureFrameExtractor

Models/        Plain values (Codable + Equatable + Hashable)
  └─ ScreenConfiguration, WallpaperContent, HTMLSource, HTMLConfig, HTMLTrust,
     WallpaperBookmark, ScheduleSlot, VideoEffectConfig, ParticleEffect,
     MetalShaderPreset, WallpaperMode, FrameRateLimit, GlobalSettings

VideoPlayback/ NSView subclasses + AVKit/Metal/WebKit hosts
  └─ WallpaperVideoPlayer, VideoContainerView, HTMLWallpaperView,
     MetalWallpaperView, ParticleOverlayView, VideoWallpaperWindow

Top-level/     Cross-cutting singletons
  └─ ScreenManager (the orchestrator), SettingsManager, Logger, SystemMonitor,
     PowerMonitor, FullScreenDetector, WeatherReactiveService
```

## Layer responsibility (one sentence each)

| Layer | Owns | Touches |
|---|---|---|
| Models | Codable values, no I/O | nothing |
| Policies | Pure decisions (`shouldPause`, `nextCursor`, `decision(for:hour:)`) | Models only |
| Infrastructure | UserDefaults, FileManager, security-scoped bookmarks, IOKit | Models + Foundation |
| Runtime | One `WallpaperRuntimeSession` per screen, lifecycle + cleanup | Models + Infrastructure + Apple media frameworks |
| VideoPlayback | NSView/Layer composition for video / HTML / shader | AVFoundation, WebKit, Metal |
| Views | SwiftUI; reads `ScreenManager` via `@Environment` | Models (read), ScreenManager (write) |
| ScreenManager | Multi-screen orchestrator + side effects | All layers above |

## Critical flows

### Apply video wallpaper
```
User picks file in inspector
  → ScreenManager.setVideo(url:bookmarkData:for:)
  → bumpTransitionGeneration[screenID]
  → Task: PlayableVideoLoader.validatePlayableVideo
  → MainActor.run: setupVideoPlayback
       → releaseRuntimeSession(screen)        // tears down old player + WallpaperAssetReadinessWork
       → WallpaperVideoPlayer(url:frame:)
       → screen.installRuntimeSession(VideoWallpaperSession(player:))
       → applyConfigurationWhenAssetReady     // waits for nominalFrameRate>0 then particles + effects + frame-rate limit
       → applyStartupPlaybackPolicy           // power + full-screen pause check, else schedulePolicyAwarePlaybackStart (200ms delayed [weak player] play)
```

### HTML→video→HTML restoration
- `ScreenConfiguration.savedHTMLSource` + `savedHTMLConfig` mirror the video pattern.
- Type swap calls `screenManager.switchToHTMLWallpaper(for:)` which calls
  `config.activateSavedHTMLWallpaper()` — restores last URL/file/folder + toggles.

### Bookmarks
- `BookmarkStore` holds `[WallpaperBookmark]` (id + label + `WallpaperContent` + createdAt) in UserDefaults.
- Three entry points:
  1. Sidebar → `Library → Bookmarks` → full-page `BookmarksLibraryView` with per-display Apply menu
  2. Inspector header `Bookmarks` button → `BookmarksPopover` to save current
  3. Menu bar `ADD WALLPAPER` row → quick popover targeting first display
- Apply path: dispatches to `setVideo` / `setHTMLWallpaper` / `setShaderWallpaper`.

### HTML trust
- `TrustedHostStore` holds an allowlist of remote hosts (lowercased, exact match — no subdomain inheritance).
- `AmbientWallpaperSessionBuilder.makeHTMLSession` evaluates `HTMLTrust` and forces `allowJavaScript = false` when the source is `untrustedRemote`.
- `HTMLSourceSection` shows banner: green (trusted), orange (untrusted, "Trust this site" button), or hidden (local file/folder/inline).

## Concurrency model

- Almost everything is `@MainActor`. Background work happens in `Task.detached` (Aerials scan) or anonymous `Task` (asset metadata load).
- Generation tokens (`transitionGeneration`, `WallpaperAssetReadinessWork`, `VideoEffectsApplicationService.generations`) prevent stale async results from clobbering newer state.
- All `[weak self]` + `[weak player]` on long-lived Tasks so teardown can reclaim resources.

## Persistence keys (UserDefaults)

| Key | Owner | Codable type |
|---|---|---|
| `screenConfigurations` | SettingsManager | `[ScreenConfiguration]` (JSON) |
| `globalSettings` | SettingsManager | `GlobalSettings` (JSON) |
| `lastUsedDirectory` | SettingsManager | `String` (path) |
| `AerialsLibrary.DirectoryBookmark` | SettingsManager | `Data` (security-scoped bookmark) |
| `WallpaperBookmarks.v1` | SettingsManager → BookmarkStore | `[WallpaperBookmark]` (JSON) |
| `TrustedHTMLHosts.v1` | SettingsManager → TrustedHostStore | `[String]` (UserDefaults stringArray) |
| `Onboarding.Completed` | OnboardingFlow (`@AppStorage`) | `Bool` |
| `Inspector.*Expanded` | ScreenDetailView (`@AppStorage`) | `Bool` |
| `Dashboard.RAMScope` | MenuBarContent (`@AppStorage`) | `String` |

## Test boundaries

- **Pure** (no environment): `Policies/`, `Models/`, decoder migrations, `HTMLTrust`, `EstimatedFrameTickPolicy`.
- **Persistence-isolated** (DI): `BookmarkStore` / `TrustedHostStore` accept `Persisting` protocol; tests inject in-memory stub.
- **Lifecycle**: `ScreenRuntimeOwnership`, `MonitoringReferenceCounter`, `RainGlassTexturePool` — exercise concrete classes.
- **Skipped**: Anything that needs a real `WKWebView` / `AVPlayer` / multi-display stack — covered by manual UI audit (see D9 in roadmap).

## Performance contracts

- Startup: each screen's wallpaper session is created **exactly once** (no `reloadAllScreens` storm — see commit `19ca421`).
- Effect slider drag: skip rebuild via `VideoEffectsApplicationService.AppliedFingerprint`.
- HTML config no-op: `HTMLWallpaperView.apply` short-circuits when `lastAppliedConfig == config`.
- Logger: `@autoclosure` defers string interpolation; `Logger.debug` body removed in release.

## Known limitations

- macOS does not provide per-process GPU%; `SystemMonitor.gpuUsage` is **system-wide**.
- HTML trust is exact-host only — no wildcard `*.example.com` yet.
- `RainGlassFilter` calls `commandBuffer.waitUntilCompleted()` per frame (only when glass-rain effect is active).
- Bookmarks have no iCloud sync.
