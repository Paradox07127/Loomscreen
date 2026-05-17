# CLAUDE.md — LiveWallpaper

Conventions for Claude Code sessions working on this repo. Loaded
automatically at session start. **If you disagree with a convention here,
open a separate PR (or surface the question to the user) to discuss — do
not silently diverge in feature work.**

## Project

macOS SwiftUI live-wallpaper manager. Swift 6 strict concurrency,
macOS 14+ target. Multi-display, video / HTML / WPE scene wallpapers.

## Active conventions (as of PR #50 — commit `a22a926`)

### 1. Persistence

All `ScreenConfiguration` writes go through
[`WallpaperPersistenceActor`](LiveWallpaper/Infrastructure/WallpaperPersistenceActor.swift).
Callers use `SettingsManager.persistConfigurations(_:)`:

- In-memory cache is updated synchronously on MainActor.
- Disk encode + fsync + rename is dispatched to the actor and returns
  immediately — UI bindings do not block on I/O.
- A monotonic `configurationWriteGeneration` token drops superseded
  writes inside the actor; out-of-order task scheduling cannot revert
  state.
- Failed writes only clear the cache if the generation is still current.
- App termination calls `SettingsManager.flushPendingConfigurationWrites()`
  via `applicationShouldTerminate` (`.terminateLater` + reply).

Do not introduce a new synchronous `screenConfigStore.write(...)` call
on MainActor. New high-frequency persistence should follow the same
actor pattern.

### 2. Session-state aggregation

Cross-screen derived state (summary cache, playback aggregate, version
counter) lives in `WallpaperSessionState` (Equatable struct, declared
in [`ScreenManager.swift`](LiveWallpaper/ScreenManager.swift)). The only
writer is `commitWallpaperSessionState(_:)`:

- Compute next snapshot off the side, compare for diff, assign once.
- Version increments only on a real diff (no phantom pulses).
- `wallpaperSessionStateVersion` / `wallpaperSessionSummaryCache` are
  backwards-compatible computed accessors — do not turn them back into
  stored properties.

When adding new derived state that fans out across screens, extend
`WallpaperSessionState`. Do not add a new `@Observable var` on
`ScreenManager` that mutates independently.

### 3. NotificationCenter timing

Notifications posted from a save / binding-set path MUST be wrapped in
`Task { @MainActor in NotificationCenter.default.post(...) }` so they
fire outside the SwiftUI reconcile pass that triggered the save.
Synchronous post from a binding chain is the root cause of
"Modifying state during view update" warnings.

Canonical examples:
- [`WallpaperPersistenceCoordinator.postChange(for:)`](LiveWallpaper/Runtime/Coordinators/WallpaperPersistenceCoordinator.swift)
- [`PlaybackCoordinator.save(_:)`](LiveWallpaper/Runtime/Coordinators/PlaybackCoordinator.swift)

### 4. withObservationTracking generation guards

Any recursive `withObservationTracking { … } onChange: { … }` that
re-registers itself MUST capture a monotonic generation and verify it
matches inside the onChange closure. Without the guard, double-starts
stack callbacks indefinitely.

Canonical examples:
- `ScreenManager.scheduleConsoleKeyTracking()`
- `ScreenManager.observeFullScreenChanges()`
- `WallpaperEffectsCoordinator.observeWeatherChanges()`

### 5. Background sampling

Mach / IOKit / VM-stat / `task_info` calls go inside
`Task.detached(priority: .utility)`; results are re-applied on
MainActor through per-property material-change epsilons.

Canonical example: [`SystemMonitor.sampleAndApply()`](LiveWallpaper/SystemMonitor.swift).
After the await, gate the apply with `guard !Task.isCancelled` so a
late sample doesn't revive published properties after `stopMonitoring()`.

### 6. Sendable conformance

Codable models that cross actor boundaries (incl. the persistence
actor) must declare `Sendable` explicitly. `AtomicFileStore` is
conditionally `@unchecked Sendable where Value: Sendable` — keep that
constraint narrow, do not relax it.

### 7. Schedule helpers — DELIBERATELY DOUBLE-LAYERED

The view-side `scheduleX()` helpers in
[`ContentView.swift`](LiveWallpaper/Views/ContentView.swift),
[`PlaylistSection.swift`](LiveWallpaper/Views/PlaylistSection.swift),
[`HTMLSourceSection.swift`](LiveWallpaper/Views/ScreenDetail/HTMLSourceSection.swift),
[`ScreenDetailView.swift`](LiveWallpaper/Views/ScreenDetailView.swift)
use:

```swift
DispatchQueue.main.async {
    Task { @MainActor in
        ...
    }
}
```

This is reviewed and intentionally retained. Whether the inner
`Task { @MainActor in }` alone is sufficient is a known open question —
**do not unilaterally flatten it to a single layer**. That discussion
belongs in its own PR after the WPE engine-assets work has settled.

### 8. UI-binding equality guards

For high-frequency controls (Pickers / Sliders / Toggles), prefer
`Binding(get:set:)` with an identity-set guard over `.onChange(of:)`:

```swift
private var someBinding: Binding<T> {
    Binding(
        get: { state },
        set: { newValue in
            guard state != newValue else { return }
            state = newValue
            // side effect here
        }
    )
}
```

Same for coordinator update methods — early-return on identity sets so
a noisy binding can't cascade into `save → fsync → post → onReceive →
reload N @State`.

When mirroring config into many local `@State` props, prefer the
`assignIfChanged` helper from
[`ScreenDetailView.swift`](LiveWallpaper/Views/ScreenDetailView.swift)
over unconditional assignment.

### 9. Adaptive Liquid Glass — wrapper-only

macOS 26 Liquid Glass APIs (`GlassEffectContainer`, `.glassEffect(...)`,
`.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`, bare `Glass`
literals such as `.regular.tint(...).interactive()`) **must stay
centralized in
[`AdaptiveGlass.swift`](Packages/LiveWallpaperSharedUI/Sources/LiveWallpaperSharedUI/Components/AdaptiveGlass.swift)**.
App views call:

- `AdaptiveGlassContainer(spacing:)`
- `.adaptiveGlassSurface(shape, tint:, interactive:)`
- `.adaptiveGlassButton(prominence)`

The wrapper places `if #available(macOS 26.0, *)` first so the native
Liquid Glass path is the default; macOS 14/15 fall through to a tinted
material + stroke + `contentShape` fallback that carries the semantic
tint forward and honors `accessibilityReduceTransparency` /
`colorSchemeContrast`. `MacOSCompatibilityPolicyTests` enforces the
"wrapper-only" rule and fails the build on any direct Liquid Glass
reference outside `AdaptiveGlass.swift`.

For macOS 15+ symbol-effect cadence, use
`SymbolEffectOptions.continuouslyRepeating` (in
[`SymbolEffectOptions+Compatibility.swift`](Packages/LiveWallpaperSharedUI/Sources/LiveWallpaperSharedUI/Components/SymbolEffectOptions+Compatibility.swift))
instead of `.repeating` so users on Sequoia and later keep the smoother
`repeat(.continuous)` behavior — `.repeating` alone maps to a periodic
cadence on macOS 15+.

Runtime verification on real macOS 14 / 15 uses the local VirtualBuddy VM
matrix. See [`docs/qa/vm-test-environment.md`](docs/qa/vm-test-environment.md)
for the connection, shared-folder bridge, build-push, crash-log and
debugging workflow; do not re-derive any of those paths in feature code.

## Parallel-session coordination

Multiple Claude sessions run on different worktrees under
`.claude/worktrees/`. Before adding new code on an existing worktree
branch:

```bash
git fetch origin
git rebase origin/main
```

PR #50 (commit `a22a926`) introduced the conventions above. Worktree
branches that diverged before that commit will see merge conflicts on
`ScreenManager.swift`, `SettingsManager.swift`, `SystemMonitor.swift`,
`LiveWallpaperApp.swift`, the view schedule helpers, and
`Localizable.xcstrings`.

## Disagreement protocol

If a convention above blocks or worsens your feature work, **raise it
explicitly** — do not silently change the pattern in feature code:

- **Wrong convention** → open a PR that touches only this file (plus the
  smallest possible code change) so the discussion lives in one place.
- **Should not apply here** → document the exception inline in your new
  code (`// CONVENTION EXCEPTION: …`) and update this file in the same PR.
- **Ambiguous** → ask the user before committing.

Silent divergence between sessions costs more than a single coordination
exchange. If you spot two sessions writing incompatible patterns, flag it.

## Tests

```bash
xcodebuild -scheme LiveWallpaper -configuration Debug \
  test -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:LiveWallpaperTests
```

Must pass before opening a PR. `LocalizationCoverageTests.catalogsIncludeSimplifiedChineseTranslations`
fails if any string-catalog key lacks a `zh-Hans` translation — when
you add a new English string, add the zh-Hans value in the same commit.

## File layout cheatsheet

- `LiveWallpaper/ScreenManager.swift` — central `@Observable` facade (1300+ lines, lazy-init coordinators)
- `LiveWallpaper/SettingsManager.swift` — persistence + cache facade
- `LiveWallpaper/Infrastructure/WallpaperPersistenceActor.swift` — disk writes
- `LiveWallpaper/Infrastructure/AtomicFileStore.swift` — generic atomic write (fsync + rotate)
- `LiveWallpaper/Runtime/Coordinators/` — domain coordinators (Effects, Playback, HTML, WPE Import, Persistence, Automation)
- `LiveWallpaper/SystemMonitor.swift` — CPU/GPU/RAM/energy/FPS
- `LiveWallpaper/Views/` — SwiftUI views (Settings window, menu bar)
- `LiveWallpaper/Resources/Localizable.xcstrings` — string catalog (zh-Hans required for every entry)
