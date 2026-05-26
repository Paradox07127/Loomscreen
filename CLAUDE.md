# CLAUDE.md — LiveWallpaper

Conventions for Claude Code sessions working on this repo. Loaded
automatically at session start. **If you disagree with a convention here,
open a separate PR (or surface the question to the user) to discuss — do
not silently diverge in feature work.**

## Project

macOS SwiftUI live-wallpaper manager. Swift 6 strict concurrency,
macOS 14+ target. Multi-display, video / HTML / WPE scene wallpapers.

Two SKUs share the same codebase:
- **Pro** (`LiveWallpaper` scheme) — full feature set.
- **Lite** (`LiveWallpaperLite` scheme, `LITE_BUILD` compile flag) — Pro
  features compiled out via `#if !LITE_BUILD`. Lite is a **lightweight
  runtime, not a UI castration**: video/HTML/Aerials UI fidelity must
  match Pro. Capability gates live in
  `Packages/LiveWallpaperCore/.../Capabilities/FeatureCatalog.swift`.

Core schema and capability layer live in the `LiveWallpaperCore` SPM
package (`Packages/LiveWallpaperCore/`). Shared UI components live in
`LiveWallpaperSharedUI`. New leaf types should land in Core where
practical so Lite can stay slim.

## Apple platform discipline

This is an Apple-platform app, not a generic codebase. Before reaching
for custom abstractions or third-party patterns:

1. **Check Apple's docs first.** SwiftUI / AVFoundation / Core Animation
   / AppKit interop / sandbox entitlements all have official guidance.
   Use `context7` MCP or `WebFetch` against `developer.apple.com` /
   WWDC sessions when uncertain — your training data may not reflect
   recent API changes.
2. **Prefer native API over hand-rolled.** If a SwiftUI / AppKit /
   Foundation API does the job, use it. Custom gesture / drawing /
   threading code is justified only when the native path fails (see
   the `PlaylistSection` drag-reorder rewrite history for an example —
   we exhausted `.draggable` and `NSItemProvider` paths before
   committing to manual `DragGesture`).
3. **Sample code + community implementations are reference, not
   prescription.** When borrowing from WWDC sample code or
   Stack Overflow / Swift Forums threads, restate the pattern in
   project style; don't paste verbatim.
4. **Respect macOS version gating.** `if #available(macOS XX, *)` blocks
   must always have a working fallback. See the AdaptiveGlass wrapper
   for the canonical pattern.

## Code style & verification discipline

- **No big comment blocks.** Code self-explains; reach for a comment
  only when *why* isn't obvious from the code (subtle invariant,
  workaround for a framework quirk, deliberate non-obvious choice).
  Don't pad files with section banners, restate-the-obvious headers,
  or paragraph-length prose. The convention sections in this CLAUDE.md
  are the place for long-form context, not source files.
- **Tests must earn their keep.** Write tests that catch real
  regressions — schema migrations, policy decisions, cross-actor
  invariants, security gates. Skip tests that only re-state what the
  type system already proves, that exercise getters / setters with no
  branches, or that lock in an arbitrary implementation detail you
  might want to change next week.
- **Never edit production code just to make a test pass.** If a test
  fails, decide whether the *behavior* is wrong or the *test* is wrong
  before changing anything. Tests that assert the wrong thing get
  rewritten (or deleted) — they don't drag the production model along.
  `PlaylistEntryIdentityTests.entryIDUsesStableBookmarkEncoding` was
  rewritten when we switched ID semantics; the right call there was to
  update the test to match the new contract, not to keep the prefixed
  ID format alive just to keep the test green.
- **Localization is non-optional.** Every new user-facing English
  string needs a `zh-Hans` translation in the same commit; the
  `LocalizationCoverageTests` test enforces this. Don't add an
  English-only key planning to translate later.

## Active conventions

§1–§9 trace back to PR #50 (commit `a22a926`); §10–§12 cover later
schema and runtime additions.

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

Runtime verification on real macOS 14 / 15 should be done on a local VM
(VirtualBuddy works well) or a spare physical Mac. There is no committed
test-environment doc — set up the VM, snapshot, and you're good.

### 10. Playlist schema — `combinedPlaylist` + `playlistPrimaryIndex`

`ScreenConfiguration` stores playlist contents as:
- `savedVideoBookmarkData` — the primary (starred) entry's bookmark
- `playlistBookmarks` — the rest (extras), order-preserving
- `playlistPrimaryIndex: Int?` — primary's position in the user-visible
  list (nil = legacy default of 0)

The user-facing combined list comes from
`ScreenConfiguration.combinedPlaylist`, which splices primary into
extras at `playlistPrimaryIndex`. **Always go through `combinedPlaylist`**
when computing the visible playlist order or cursor math — never reach
for `[savedVideoBookmarkData] + playlistBookmarks` inline. Drag-reorder
preserves primary identity (the star travels with the entry) by writing
the new `playlistPrimaryIndex`; it is not a primary swap.

### 11. Bookmark = complete plan, not just file pointer

`WallpaperBookmark.playbackSettings: BookmarkPlaybackSettings?` carries
the full playback / effect snapshot at save time (playback speed,
fit mode, frame-rate limit, particle effect, full `VideoEffectConfig`,
mute / volume, set-as-lock-screen). Applying a bookmark restores the
**whole plan**, not just content.

Apply order matters: `ScreenManager+Bookmarks.applyBookmark` **must**
write the settings via the public update setters **before** triggering
the content swap. `PlaybackCoordinator.setupVideoPlayback` reads the
stored config at player-creation time and applies effects via
`applyConfigurationWhenAssetReady`, so the new player must see the
restored settings already in place. Reversing the order leaves the new
player initialized from the prior screen's effects.

Dedup is content-only (`BookmarkStore.equivalentBookmark(content:)`):
one bookmark per source. To change a bookmark's settings, delete and
re-save from the current screen state. Legacy bookmarks decode with
`playbackSettings == nil` — they apply as before (content-only).

### 12. Video playback — in-memory cache for sub-budget files

`WallpaperVideoPlayer` switches between disk-streaming and
`AVAssetResourceLoaderDelegate`-backed in-memory playback based on the
per-screen budget `GlobalSettings.videoCacheMaxBytesPerScreen` (0 =
streaming only; default 150 MB; max 1 GB). When a video fits, the file
is loaded with `Data(contentsOf:options: .mappedIfSafe)` and served via
the custom `lwmem://wallpaper/<filename>` scheme so AVFoundation never
re-reads disk during loop playback.

Strict `AVURLAsset` options are required for in-memory load:
`AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue`,
plus all `AllowsCellular / Expensive / ConstrainedNetworkAccessKey`
set to `false`. The entitlements include a mach-lookup exception for
`com.apple.audioanalyticsd` to silence the AVFoundation precondition
failure that hits on every sandboxed `AVPlayer` init.

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

## Build + test gates

Before opening a PR, all three must pass:

```bash
# Pro test suite (671 tests as of this writing)
xcodebuild -scheme LiveWallpaper -configuration Debug \
  test -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:LiveWallpaperTests

# Lite build (Pro-only sources gated by #if !LITE_BUILD)
xcodebuild -scheme LiveWallpaperLite -configuration Debug \
  build -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -skipMacroValidation
```

**Do not run the two schemes in parallel against the same DerivedData
build database** — they collide on `XCBuildData/build.db` and one
fails to attach. Run sequentially or in separate DerivedData paths.

`LocalizationCoverageTests.catalogsIncludeSimplifiedChineseTranslations`
fails when any string-catalog key lacks a `zh-Hans` translation — add
the translation in the same commit that introduces the English string.

## File layout cheatsheet

App target (main):
- `LiveWallpaper/ScreenManager.swift` — central `@Observable` facade, lazy-init coordinators
- `LiveWallpaper/SettingsManager.swift` — persistence + cache facade
- `LiveWallpaper/Infrastructure/WallpaperPersistenceActor.swift` — disk writes
- `LiveWallpaper/Infrastructure/AtomicFileStore.swift` — generic atomic write (fsync + rotate)
- `LiveWallpaper/Runtime/Coordinators/` — domain coordinators (Effects, Playback, HTML, WPE Import, Persistence, Automation)
- `LiveWallpaper/Runtime/ScreenManager+Bookmarks.swift` — bookmark apply path (content + playback settings)
- `LiveWallpaper/VideoPlayback/WallpaperVideoPlayer.swift` — AVPlayer + effects + in-memory loader
- `LiveWallpaper/VideoPlayback/InMemoryVideoAssetLoader.swift` — `AVAssetResourceLoaderDelegate` for `lwmem://` scheme
- `LiveWallpaper/SystemMonitor.swift` — CPU/GPU/RAM/energy/FPS
- `LiveWallpaper/Views/` — SwiftUI views (Settings window, menu bar, screen detail)
- `LiveWallpaper/Resources/Localizable.xcstrings` — string catalog (zh-Hans required for every entry)
- `LiveWallpaper/LiveWallpaper.entitlements` — sandbox + mach-lookup exceptions

SPM packages:
- `Packages/LiveWallpaperCore/` — schemas, capabilities, persistence stores (no UI)
  - `Schema/ScreenConfiguration.swift` — per-screen state including `combinedPlaylist`
  - `Schema/WallpaperBookmark.swift` + `BookmarkPlaybackSettings.swift` — bookmark = complete plan
  - `Capabilities/FeatureCatalog.swift` + `ProductCapabilities.swift` — Lite/Pro gating
  - `Persistence/BookmarkStore.swift` + `WallpaperConfigurationStore.swift`
- `Packages/LiveWallpaperSharedUI/` — adaptive components shared by Pro + Lite UI
  - `Components/AdaptiveGlass.swift` — sole entry point for macOS 26 Liquid Glass
  - `Components/CollapsibleSection.swift`, `ContainerGroupBoxStyle.swift`, etc.
