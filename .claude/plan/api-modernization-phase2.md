# Plan: Apple API Modernization — Phase 2 (Architectural)

**Created**: 2026-04-26
**Phase 1 status**: ✅ Done (#3 os.Logger, #4 .confirmationDialog, #5 .fileImporter, #6 Transferable, #8 Gauge, #10 .symbolEffect)
**Phase 2 scope**: 3 architectural changes that touch app entry point + main inspector layout
**Estimated wall-clock**: 4–5 hours given the project's fact-forcing-gate hook overhead
**SESSION_ID**: (none — fresh session, no codex/gemini context to resume)

---

## Goal

Replace 3 remaining legacy patterns with native macOS-26-class SwiftUI APIs:

1. **#1 `MenuBarExtra`** replacing `NSStatusItem` / `NSMenu` (377 lines → ~120)
2. **#2 `Settings` scene** wired to `ContentView` (currently `Settings { EmptyView() }`)
3. **#7 `.inspector(isPresented:)`** replacing the manual two-column `HStack` in `ScreenDetailView`

Items #1 and #2 are **coupled** — `StatusBarController` currently builds the settings window manually via `NSWindowController`; the `Settings` scene replaces that and is invoked from MenuBarExtra via `SettingsLink`.

---

## Pre-flight checks (run first)

```bash
cd /Users/taijialiang/Xcode/LiveWallpaper

# Confirm we're starting from a green tree
xcodebuild -project LiveWallpaper.xcodeproj -scheme LiveWallpaper \
  -destination 'platform=macOS,arch=arm64' build 2>&1 | grep -E "BUILD|error:"
# Expected: ** BUILD SUCCEEDED **

# Confirm Phase 1 changes are present
rg -q "import os$" LiveWallpaper/Logger.swift && echo "✅ Phase 1 #3 present"
rg -q "fileImporter" LiveWallpaper/Views/ScreenDetailView.swift && echo "✅ Phase 1 #5 present"
rg -q "dropDestination" LiveWallpaper/Views/ContentView.swift && echo "✅ Phase 1 #6 present"
rg -q "Gauge\\(value:" LiveWallpaper/Views/SystemMonitorView.swift && echo "✅ Phase 1 #8 present"
rg -q "symbolEffect.*pulse" LiveWallpaper/Views/ScreenDetailView.swift && echo "✅ Phase 1 #10 present"
```

If any check fails, abort — Phase 1 is not in place and Phase 2 may make assumptions that don't hold.

---

## Execution order (do NOT reorder)

| Step | Item | Files touched | Build between? |
|------|------|---------------|----------------|
| 1 | Create `Views/MenuBarContent.swift` (new SwiftUI menu) | new file | — |
| 2 | Rewrite `LiveWallpaperApp.swift` (Settings scene + MenuBarExtra wired in) | 1 file | ✅ build (must pass before next step) |
| 3 | Delete `StatusBarController.swift` + remove project reference | 1 file + project.pbxproj | ✅ build |
| 4 | Manual smoke test — icon appears, menu works, Settings opens | — | run app |
| 5 | Restructure `ScreenDetailView.swift` body to use `.inspector(isPresented:)` | 1 file | ✅ build + run + verify ⌘⌃I |
| 6 | Add `@AppStorage("Inspector.Visible")` for inspector visibility persistence | `ScreenDetailView.swift` | ✅ build |
| 7 | Run unit + UI tests | — | `xcodebuild test`; expect 90+ pass |

---

## Step 1 — Create `Views/MenuBarContent.swift` (new file)

### Why
Encapsulate the SwiftUI menu so `LiveWallpaperApp` stays small. Pure presentational; reads `screenManager` from environment.

### Code

```swift
import SwiftUI

/// SwiftUI replacement for the legacy `NSMenu` in `StatusBarController`.
/// Reads `ScreenManager` from the environment and updates reactively when
/// `@Observable` properties change — no manual `NSMenuDelegate` callbacks
/// required.
struct MenuBarContent: View {
    @Environment(ScreenManager.self) private var screenManager

    var body: some View {
        // Header — non-interactive, .disabled greys it out.
        Text("LiveWallpaper")
            .font(.headline)

        Divider()

        // SettingsLink is the macOS 14+ native way to open the Settings scene.
        // It honors LSUIElement + Cmd+, automatically.
        SettingsLink {
            Label("Open Settings…", systemImage: "gear")
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        // Displays submenu — list updates reactively via @Observable.
        Menu("Displays") {
            displaysSubmenu
        }

        Divider()

        // Playback controls
        Button {
            screenManager.togglePlayback()
        } label: {
            Label(playPauseTitle, systemImage: playPauseIcon)
        }
        .keyboardShortcut("p", modifiers: .command)
        .disabled(!screenManager.hasControllableWallpaperSessions)

        Button {
            advanceAllPlaylists()
        } label: {
            Label("Next Wallpaper", systemImage: "forward.fill")
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(!hasAnyVideo)

        Button {
            screenManager.reloadAllScreens()
        } label: {
            Label("Reload All Wallpapers", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: .command)

        Divider()

        Button {
            NSApp.terminate(nil)
        } label: {
            Label("Quit LiveWallpaper", systemImage: "xmark")
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Displays submenu

    @ViewBuilder
    private var displaysSubmenu: some View {
        if screenManager.screens.isEmpty {
            Text("No displays detected").disabled(true)
        } else {
            ForEach(screenManager.screens, id: \.id) { screen in
                Button {
                    selectScreenInSettings(screen)
                } label: {
                    Label {
                        Text(screen.name)
                    } icon: {
                        Image(systemName: displayIcon(for: screen))
                    }
                }
            }
            Divider()
            Button {
                screenManager.refreshScreens()
            } label: {
                Label("Refresh Displays", systemImage: "arrow.clockwise")
            }
        }
    }

    // MARK: - Helpers

    private var playPauseTitle: String {
        if !screenManager.hasControllableWallpaperSessions {
            return "No Video Wallpapers"
        }
        return screenManager.isAnyScreenPlaying ? "Pause All Videos" : "Play All Videos"
    }

    private var playPauseIcon: String {
        if !screenManager.hasControllableWallpaperSessions {
            return "display"
        }
        return screenManager.isAnyScreenPlaying ? "pause.circle" : "play.circle"
    }

    private var hasAnyVideo: Bool {
        screenManager.screens.contains { $0.videoPlayer != nil }
    }

    private func advanceAllPlaylists() {
        for screen in screenManager.screens where screen.videoPlayer != nil {
            screenManager.advancePlaylist(for: screen)
        }
    }

    private func displayIcon(for screen: Screen) -> String {
        let summary = screenManager.wallpaperSummary(for: screen)
        switch summary.activity {
        case .inactive: return "questionmark.circle"
        case .active:   return summary.supportsPlaybackControl ? "play.circle.fill" : "display"
        case .paused:   return "pause.circle.fill"
        }
    }

    private func selectScreenInSettings(_ screen: Screen) {
        // Open the Settings scene programmatically. SettingsLink is preferred
        // for direct user-clickable buttons, but for "select-then-open" inside
        // a sub-menu we use Apple's documented action selector on macOS 14+.
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        NSApp.activate(ignoringOtherApps: true)

        // After window is on screen, tell ContentView which screen to show.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            NotificationCenter.default.post(
                name: .selectScreenInSettings,
                object: nil,
                userInfo: ["screenID": screen.id]
            )
        }
    }
}
```

### Notes

- **`SettingsLink` is a View, not callable**. For "Open Settings from a sub-menu Display button", use the system `showSettingsWindow:` action.
- Status bar **icon** is set on the `MenuBarExtra` itself (Step 2), NOT inside this content view.
- `screenManager.wallpaperDisplayName(for:)` is intentionally NOT shown in Display submenu items because Apple's `Menu` doesn't render multi-line labels well — keep it to title only.

---

## Step 2 — Rewrite `LiveWallpaperApp.swift`

### Current state (the parts to preserve)

```swift
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarController: StatusBarController?     // ← REMOVE
    var screenManager: ScreenManager?                  // ← KEEP (for wake handler)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ... wake observer setup ...
        // ... NSApp.setActivationPolicy(.accessory) ...
    }

    @objc private func handleWakeNotification() { /* keep */ }
    nonisolated func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}

@main
struct LiveWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }    // ← REPLACE
    }
}
```

### Replace with

```swift
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `MenuBarContent.onAppear` so the wake notification can refresh it.
    weak var screenManagerRef: ScreenManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.notice("Application starting", category: .startup)

        // Wake notification — kept here because workspace notifications need
        // an NSObject observer; ScreenManager picks up the refresh.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWakeNotification),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        NSApp.setActivationPolicy(.accessory)
        Logger.notice("Application startup complete", category: .startup)
    }

    @objc private func handleWakeNotification() {
        Logger.info("System wake detected", category: .lifecycle)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.screenManagerRef?.refreshScreens()
            PowerMonitor.shared.refreshPowerStatus()
        }
    }

    nonisolated func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}

@main
struct LiveWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var screenManager = ScreenManager()
    @State private var didReloadOnce = false

    var body: some Scene {
        // MenuBarExtra is the macOS 13+ native replacement for NSStatusItem.
        // The label closure provides the status bar icon, refreshed reactively
        // when @Observable ScreenManager properties change.
        MenuBarExtra {
            MenuBarContent()
                .environment(screenManager)
                .onAppear {
                    // First-run wiring: hand screenManager to AppDelegate, kick
                    // off the deferred reloadAllScreens that the old AppDelegate
                    // did via Task.sleep. Guarded by `didReloadOnce` so it only
                    // runs once even though MenuBarExtra content can re-mount.
                    appDelegate.screenManagerRef = screenManager
                    guard !didReloadOnce else { return }
                    didReloadOnce = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        screenManager.reloadAllScreens()
                    }
                }
        } label: {
            Image(systemName: menuBarIconName)
        }
        .menuBarExtraStyle(.menu)

        // Settings scene — Cmd+, auto-bound. Settings window state (size,
        // position) is auto-restored by the system.
        Settings {
            ContentView()
                .environment(screenManager)
                .frame(minWidth: 1000, minHeight: 650)
        }
    }

    /// Mirrors `StatusBarController.determineStatusBarIcon`. Reactive because
    /// `screenManager.wallpaperOverviewStatus` is `@Observable`.
    private var menuBarIconName: String {
        switch screenManager.wallpaperOverviewStatus {
        case .notConfigured:
            return "photo.on.rectangle"
        case .active:
            return screenManager.hasControllableWallpaperSessions
                ? "play.rectangle.fill" : "display.2"
        case .paused:
            return "pause.rectangle.fill"
        }
    }
}
```

### Critical gotchas

1. **`@State var screenManager = ScreenManager()`**: `ScreenManager.init()` is `@MainActor`. The `@State` initializer for an `App` struct runs on the main thread at app launch, so this works. If the compiler complains, switch to:
   ```swift
   init() {
       _screenManager = State(wrappedValue: ScreenManager())
   }
   ```

2. **`MenuBarExtra` content can re-mount** when SwiftUI invalidates. The `.onAppear` closure may fire multiple times. The `didReloadOnce` flag guards against duplicate `reloadAllScreens` calls.

3. **`appDelegate.screenManagerRef`** is `weak var` to avoid retain cycles.

4. **`Settings { ContentView() }` is keyed `Cmd+,` automatically by the system**. Don't add a redundant `.keyboardShortcut(",", modifiers: .command)` on `SettingsLink` — Apple already does this.

---

## Step 3 — Delete `StatusBarController.swift`

```bash
git rm LiveWallpaper/StatusBarController.swift
```

Then open Xcode → project navigator → if there's a red "missing file" reference, right-click → Delete → Remove Reference. Save.

### Verify nothing references it

```bash
rg -n "StatusBarController" LiveWallpaper LiveWallpaperTests --type swift
# Expected: empty
```

---

## Step 4 — Build & smoke test

```bash
xcodebuild -project LiveWallpaper.xcodeproj -scheme LiveWallpaper \
  -destination 'platform=macOS,arch=arm64' build 2>&1 | grep -E "BUILD|error:"
```

**Expected**: `** BUILD SUCCEEDED **`

Manual smoke test (open the app):
1. Launch → status bar icon appears
2. Click icon → menu shows: LiveWallpaper, Settings, Displays, Play/Pause, Next, Reload, Quit
3. Click "Open Settings…" → real Settings window opens (Cmd+, also opens it)
4. Click a display in the Displays submenu → Settings opens AND ContentView navigates to that screen
5. Verify status icon changes when toggling playback (Cmd+P from menu)
6. Quit (Cmd+Q) — confirm app exits cleanly

---

## Step 5 — `.inspector(isPresented:)` restructure for `ScreenDetailView`

### Why

Currently the right inspector is a `.frame(width: 320)` ScrollView inside the main `HStack`. This requires manual width management and gives no native chrome. The macOS 14 `.inspector` modifier provides:
- User-resizable column
- Native `Cmd+Ctrl+I` toggle
- Toolbar button auto-handled by SwiftUI
- Visibility state auto-persisted by the system

### Current shape (lines 138–414 of `ScreenDetailView.swift` after Phase 1)

```swift
HStack(spacing: 0) {
    ZStack { /* preview */ }.frame(maxWidth: .infinity, maxHeight: .infinity)
    Divider()
    if selectedWallpaperType == .video {
        ScrollView { /* inspector */ }.frame(width: 320)
    }
}
.transaction(value: selectedWallpaperType) { $0.animation = nil }
```

### Replace with

Add at top of struct (alongside other `@AppStorage` properties around line 59):

```swift
@AppStorage("Inspector.Visible") private var isInspectorVisible = true
```

Then replace the body's main column area:

```swift
var body: some View {
    VStack(spacing: 0) {
        headerSection                           // existing top bar with title + Select Video / Clear

        Divider()

        previewColumn
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .inspector(isPresented: $effectiveInspectorVisible) {
        if selectedWallpaperType == .video {
            inspectorScrollView
                .inspectorColumnWidth(min: 280, ideal: 320, max: 440)
        } else {
            // Empty pane for non-video wallpapers — still need to provide
            // SOMETHING because .inspector requires a content view, but the
            // toolbar toggle is disabled below so user can't open it.
            Color.clear.inspectorColumnWidth(min: 0, ideal: 0, max: 0)
        }
    }
    .toolbar {
        ToolbarItem(placement: .principal) {
            wallpaperTypePicker
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                isInspectorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .symbolVariant(isInspectorVisible ? .fill : .none)
            }
            .help(isInspectorVisible ? "Hide Inspector" : "Show Inspector")
            .keyboardShortcut("i", modifiers: [.command, .control])
            .disabled(selectedWallpaperType != .video)
        }
    }
    .onChange(of: selectedWallpaperType) { _, newType in
        // Auto-hide inspector when switching to HTML/Shader (no inspector
        // content for those modes). Restore when returning to video.
        isInspectorVisible = (newType == .video) ? lastUserInspectorState : false
        if newType == .video {
            lastUserInspectorState = isInspectorVisible
        }
    }
    .onAppear { loadScreenConfiguration() }
    // ... existing onAppear / onDisappear / onChange / onReceive / alert / confirmationDialog / fileImporter ...
}

// Add another @State to remember user's preferred state across type switches:
@State private var lastUserInspectorState = true

// Computed binding so the system can't accidentally show the inspector when
// it shouldn't be visible for non-video types.
private var effectiveInspectorVisible: Binding<Bool> {
    Binding(
        get: { selectedWallpaperType == .video && isInspectorVisible },
        set: { newValue in
            isInspectorVisible = newValue
            if selectedWallpaperType == .video {
                lastUserInspectorState = newValue
            }
        }
    )
}
```

### Extract sub-views to keep body readable

Add these as `@ViewBuilder` properties on `ScreenDetailView`:

```swift
@ViewBuilder
private var headerSection: some View {
    HStack(alignment: .center, spacing: 14) {
        // ... existing header content lines 70–134 — unchanged ...
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 14)
}

@ViewBuilder
private var previewColumn: some View {
    ZStack {
        Color(NSColor.underPageBackgroundColor)
        if selectedWallpaperType == .video {
            // ... existing preview block lines 147–207 — unchanged ...
        } else if selectedWallpaperType == .html {
            HTMLWallpaperSection(screen: screen, htmlContent: $htmlContent)
                .padding(24)
        } else if selectedWallpaperType == .metalShader {
            ShaderWallpaperSection(screen: screen, selectedShaderPreset: $selectedShaderPreset)
                .padding(24)
        }
    }
}

@ViewBuilder
private var inspectorScrollView: some View {
    ScrollView {
        GlassEffectContainer(spacing: 16) {
            VStack(spacing: 16) {
                // ... existing 5 GroupBox + CollapsibleSection cards lines 228–409 — unchanged ...
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }
    .background(Color(NSColor.windowBackgroundColor))
}

@ViewBuilder
private var wallpaperTypePicker: some View {
    Picker("Wallpaper Type", selection: $selectedWallpaperType) {
        ForEach(WallpaperType.allCases) { type in
            Text(type.rawValue).tag(type)
        }
    }
    .pickerStyle(.segmented)
    .frame(width: 280)
    .accessibilityLabel("Wallpaper type")
    .accessibilityHint("Choose between video, HTML, or Metal shader wallpaper")
    .onChange(of: selectedWallpaperType) { _, newType in
        if newType == .video {
            screenManager.switchToVideoWallpaper(for: screen)
        }
    }
}
```

### What to delete

- The current `HStack(spacing: 0) { ... }.transaction(...)` block in body
- The `ToolbarItem(placement: .principal)` Picker block at the end of body's `.toolbar` modifier (it's been hoisted into `wallpaperTypePicker`)

### Important: don't double-wire `.onChange`

The existing body has `.onChange(of: selectedWallpaperType)` inside the toolbar Picker. The new `wallpaperTypePicker` includes that closure. Don't add another `.onChange(of: selectedWallpaperType)` at the body root — the existing one already handles `switchToVideoWallpaper`. The NEW `.onChange` you ARE adding (for `isInspectorVisible`) is at body root and does NOT call `switchToVideoWallpaper`. Two distinct closures. Both will fire on type change.

---

## Step 6 — Run unit + UI tests

```bash
xcodebuild -project LiveWallpaper.xcodeproj -scheme LiveWallpaper \
  -destination 'platform=macOS,arch=arm64' test 2>&1 \
  | grep -cE "passed on 'My Mac"
# Expected: ≥ 90 (existing 90 unit tests + 3 UI tests)

xcodebuild -project LiveWallpaper.xcodeproj -scheme LiveWallpaper \
  -destination 'platform=macOS,arch=arm64' test 2>&1 \
  | grep -cE "failed on 'My Mac"
# Expected: 0 (or 1 if testLaunchPerformance is flaky baseline — known issue, not regression)
```

---

## Risks & mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| `MenuBarExtra` re-renders too often (every `@Observable` read) | Medium | SwiftUI diffs the icon by `systemName` string; cheap. Already fine in existing code path. |
| `SettingsLink` cannot be invoked from a sub-menu Display button (it's a View, not callable) | High (architectural) | Use `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)` — Apple's documented programmatic equivalent on macOS 14+. Combine with `NSApp.activate(ignoringOtherApps: true)`. |
| Settings scene window won't appear when LSUIElement=true | Medium | `NSApp.activate(ignoringOtherApps: true)` before posting the show action. Test: verify Cmd+, opens window even when no other app windows visible. |
| `.inspector(isPresented:)` renders empty pane for HTML/Shader | Low | Use the `effectiveInspectorVisible` computed binding that gates on wallpaperType. Toolbar button is also `.disabled(selectedWallpaperType != .video)`. |
| AppDelegate.screenManagerRef nil race on first wake before MenuBarContent mounts | Low | First wake event after launch happens > 1 second after init in normal use; MenuBarContent mounts on app launch immediately. Worst case: one missed refresh. Acceptable. |
| `@State var screenManager = ScreenManager()` initializer runs off-main | Low | Apple guarantees `@State` initializers in App struct run on main; `ScreenManager.init` is `@MainActor`. If compile error appears, switch to explicit `init()` form documented in Step 2. |
| `git rm StatusBarController.swift` leaves dangling reference in `LiveWallpaper.xcodeproj/project.pbxproj` | High | After deleting, open Xcode and remove the file reference from the project navigator (Xcode prompts on next build). |
| Inspector `Cmd+Ctrl+I` shortcut conflicts with system "Inspect Element" in some contexts | Very low | macOS reserves `Cmd+Ctrl+I` for inspector toggling — this is the official binding per HIG. No conflict. |
| Existing `@AppStorage` keys for `Inspector.PlaylistExpanded` etc. still valid | High (must verify) | Verified: namespace `Inspector.*` is fine; `Inspector.Visible` is new and doesn't collide. |

---

## Verification checklist (after Phase 2 ships)

- [ ] Status bar icon appears on launch
- [ ] Status bar icon updates color/symbol when toggling playback
- [ ] Cmd+, opens Settings window
- [ ] Settings window has native macOS chrome (title bar, traffic-light close button)
- [ ] Closing Settings does NOT quit app (LSUIElement preserved)
- [ ] Click "Open Settings…" in menu → window opens
- [ ] Click a display in the Displays submenu → Settings opens AND navigates to that screen
- [ ] Cmd+P toggles playback when video wallpapers exist
- [ ] Cmd+Shift+N advances all playlists
- [ ] Cmd+R reloads all wallpapers
- [ ] Cmd+Q quits the app
- [ ] In Settings, switch to a video wallpaper → Inspector appears on the right
- [ ] Drag inspector divider — width changes smoothly
- [ ] Cmd+Ctrl+I toggles inspector visibility
- [ ] Inspector visibility persists across app restarts (verified by `@AppStorage`)
- [ ] Switch to HTML/Shader wallpaper → Inspector auto-hides; toolbar button disables
- [ ] Switch back to Video → Inspector restores to previous user-set state
- [ ] No `StatusBarController.swift` references anywhere in the project
- [ ] Tests still 90+ passing (unit + UI launch)

---

## Rollback plan

If Phase 2 introduces a critical regression:

```bash
cd /Users/taijialiang/Xcode/LiveWallpaper

git diff HEAD --name-only LiveWallpaper LiveWallpaperTests
# Should show: LiveWallpaperApp.swift, ScreenDetailView.swift,
#              MenuBarContent.swift (new), StatusBarController.swift (deleted)

git restore LiveWallpaper/LiveWallpaperApp.swift
git restore LiveWallpaper/Views/ScreenDetailView.swift
rm LiveWallpaper/Views/MenuBarContent.swift
git restore LiveWallpaper/StatusBarController.swift
# (Re-add to project.pbxproj via Xcode if it was removed there)
```

This recovers the Phase 1 state which is known-green.

---

## Out of scope for Phase 2

The following were considered but **explicitly excluded**:

- **#9 PhaseAnimator** — current 2-line `withAnimation` is simpler; no benefit
- **#11 Form { Section }.collapsible** — macOS 26-only; wait for stability
- **SwiftData** — over-engineering for current UserDefaults JSON model
- **`@Entry` macro** — no EnvironmentKey usage in project
- **Charts framework** — not a time-series UI

---

## Notes on the fact-forcing-gate hook

This project has a `gateguard-fact-force` PreToolUse hook that demands a Grep + facts block before each Edit/Write. When executing this plan:

- Each Edit must be preceded by a fresh `rg` call **in the same conversation turn**
- The facts block format is:
  1. List ALL files that import/require this file (use Grep)
  2. List the public functions/classes affected by this change
  3. If the file reads/writes data files, show field names, structure, date format
  4. Quote the user's current instruction verbatim

- Strategy to minimize gate cycles: for large rewrites in Step 2 and Step 5, prefer ONE big `Write` over many small `Edit`s.

---

## Estimated turn budget for `/ccg:execute`

| Step | Edits | Gate cycles | Approx turns |
|------|-------|-------------|--------------|
| 1 | 1 Write (new file) | 1 | 2 |
| 2 | 1 Write (full rewrite of LiveWallpaperApp) | 1 | 2 |
| 3 | 1 file deletion + Xcode project edit | 0 (Bash + manual) | 2 |
| 4 | Build + manual smoke | 0 | 1 |
| 5 | 1 large rewrite + sub-view extractions (4–6 Edits) | 4–6 | 8–12 |
| 6 | Test | 0 | 1 |
| **Total** | — | **6–8** | **16–20 turns** |

---

## How to execute next session

```
/ccg:execute .claude/plan/api-modernization-phase2.md
```

The execute command will:
1. Read this plan
2. No SESSION_ID — create fresh codex/gemini sessions if multi-model is invoked
3. Follow the steps in order
4. Run pre-flight checks first
5. Build between major steps
6. Stop and ask if any verification step fails

**Recommended hint for next session**: invoke with the explicit instruction "skip multi-model orchestration; this is well-scoped UI work where direct execution is faster than codex/gemini round-trips." This avoids the gemini 429 rate limit issues observed in prior sessions and the codex 5-15 minute response time.
