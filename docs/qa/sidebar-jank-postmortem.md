# Settings Window Sidebar Reveal Jank — Postmortem

## Symptom

Settings window's NavigationSplitView sidebar slide animation showed a
characteristic "smooth → halfway stall → snap to final" pattern on:

- First reveal after launch
- Sidebar width adjustment via divider drag
- Every reveal after the window was closed and reopened

Once the user had manually dragged the sidebar fully closed and dragged
it back open, all subsequent toggles within that window lifetime were
smooth — confirming a **one-time warmup cost** per window-show, not
continuous per-frame contention.

## What Did NOT Fix It (Disproved Hypotheses)

The investigation tried these in order. Each was based on a plausible
hypothesis that user testing then ruled out. They have all been
reverted; recording them here so future debuggers don't repeat the same
mistakes.

### 1. SystemMonitor first-sample timing

**Hypothesis**: SystemMonitor's first `sampleAndApply` fired at 350ms
mid-animation, triggering an `@Observable` cascade plus per-gauge
`.animation(value:)` that blew the SwiftUI frame budget.

**Change tried**: `MonitoringStartPolicy.initialSampleDelay` 350ms → 700ms.

**Result**: No effect. User confirmed jank persisted with same shape.

**Disproven by**: Same symptom appeared on Lite (which has no Dashboard
section), and at zero-config / no-wallpaper state where SystemMonitor
isn't even visible.

### 2. SystemMonitorView deferred mount

**Hypothesis**: Even with sampling delayed, the static first-render of
4 `MiniGaugeCard` ZStacks (Circle/trim/stroke + shadow + gradient) is
non-trivial and lined up with the slide animation.

**Change tried**: `dashboardReady` `@State` flag flipped to true 700ms
after sidebar `.task`; gated the entire `SystemMonitorView`.

**Result**: No effect. Same as #1: also janks on Lite / no Pro
SystemMonitor.

### 3. SF Symbol `symbolEffect` modifier overhead

**Hypothesis**: The sidebar Reload button's
`.symbolEffect(.rotate, ..., isActive: false)` modifier still registered
a per-frame CoreAnimation contributor even when inactive, competing
with the slide animation.

**Change tried**: Wrap the icon in a `@ViewBuilder` that only attaches
the `symbolEffect` modifier when `isReloading` is true.

**Result**: No effect.

### 4. ScreenRow `scheduleEffectBadgeRefresh` deferred tasks

**Hypothesis**: Each `ScreenRow.onAppear` fired
`DispatchQueue.main.async { Task { @MainActor in refreshEffectBadge() } }`,
queuing N tasks on first sidebar appearance and triggering secondary
reconciles mid-animation.

**Investigation**: Code path was confirmed real but user testing showed
the jank also occurred with zero displays configured (no rows to
refresh).

### 5. Detail pane resize cost

**Hypothesis**: Sidebar slide shrinks the detail column. If the detail
shows a video preview (`CustomVideoPlayer.AVPlayerLayer.frame =
bounds`) or HTML snapshot (`scaledToFill`), every animation frame
triggers expensive AppKit/CoreAnimation re-layout that shares the
budget with the sidebar slide. Sidebar would just be the visible
victim.

**Investigation**: User tested with no wallpaper / no preview — jank
still occurred. Ruled out.

### 6. `NSWindowController` release on window close

**Hypothesis**: `windowWillClose` was setting `settingsWindowController
= nil`, which let ARC release the `NSHostingController` and tear down
the entire SwiftUI hierarchy. Next `showSettings()` paid the full
`List(.sidebar)` / `NSOutlineView` materialization cost on the first
reveal frame.

**Change tried**: Remove `settingsWindowController = nil` from
`windowWillClose` so the controller is retained across close + reopen.

**Result**: No effect on its own. The window itself was still being
released (no `isReleasedWhenClosed = false`) AND AppKit was still
tearing down `NSSplitViewController` internal state on close even when
the SwiftUI tree survived.

**Status**: This change stayed, because it's a *necessary precondition*
for the eventual fix — see "Final Fix" below.

### 7. `NSHostingView` → `NSHostingController`

**Hypothesis**: Using the view-controller variant would give the
SwiftUI tree proper `viewWill/DidAppear` lifecycle callbacks, letting
the underlying `NSSplitViewController` realize its split state up
front.

**Change tried**: `window.contentView = NSHostingView(rootView:)` →
`window.contentViewController = NSHostingController(rootView:)`.

**Result**: No effect. Codex agent independently predicted this would
be low-probability ahead of testing because both variants are still
*outside* SwiftUI's `Scene` system.

**Status**: Reverted to `NSHostingView` to minimize churn.

## What Actually Fixed It

Two coordinated changes in commit `18b05a8`:

### Fix A — Programmatic `columnVisibility` prewarm

The user's manual workaround was "drag the sidebar closed to width 0,
then drag it back open" — after which all toggles were smooth. This
strongly suggested the cost was in *first realization of the collapsed
state* in the underlying `NSSplitView`.

We bound `NavigationSplitView.columnVisibility` to a `@State` and ran a
one-shot, animation-suppressed cycle (`.all → .detailOnly → .all`) on
`onAppear`:

```swift
@State private var columnVisibility: NavigationSplitViewVisibility = .all
@State private var didPrewarmSidebar = false

// in body:
NavigationSplitView(columnVisibility: $columnVisibility) { ... } detail: { ... }
.onAppear { prewarmSidebarIfNeeded() }

private func prewarmSidebarIfNeeded() {
    guard !didPrewarmSidebar else { return }
    didPrewarmSidebar = true
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(50))
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { columnVisibility = .detailOnly }
        try? await Task.sleep(for: .milliseconds(30))
        withTransaction(transaction) { columnVisibility = .all }
    }
}
```

This is the programmatic equivalent of the manual drag warmup — without
the visible flash because the transition uses
`Transaction.disablesAnimations = true`.

### Fix B — `windowShouldClose` returns false + `orderOut`

Even with the controller retained and the SwiftUI tree surviving,
testing showed the jank cycle restarted after window close + reopen.
AppKit was tearing down enough internal `NSSplitViewController` state
on the *real* close path that the prewarm gain didn't survive.

The fix is to never actually close the settings window — intercept the
close request, hide the window with `orderOut`, and return `false` so
AppKit treats it as still-open:

```swift
func windowShouldClose(_ sender: NSWindow) -> Bool {
    if sender == settingsWindowController?.window {
        sender.orderOut(nil)
        return false
    }
    return true
}
```

The onboarding window keeps the regular close-and-release semantics.

### Supporting infrastructure (kept from earlier exploration)

- `windowWillClose` no longer sets `settingsWindowController = nil`
  (kept from the disproved hypothesis #6) — required for the orderOut
  path to find the same window object across opens.
- `window.isReleasedWhenClosed = false` on the settings window —
  defensive against any non-`windowShouldClose` close path (e.g.,
  app quit), and incidentally fixed a real bug where the comment in
  `windowWillClose` claimed this flag was set but it wasn't.

## Lessons

1. **"Smooth → halfway stall → snap" is not always a content cost.**
   It can be a single one-time realization cost in the underlying
   AppKit bridge that lands mid-animation.

2. **NSHostingView wrapped in manual NSWindow != SwiftUI Scene.** When
   `NavigationSplitView` lives outside SwiftUI's `Window`/`WindowGroup`
   scene system, its sidebar behavior diverges from the documented
   smooth case. Apple's
   [NavigationSplitViewVisibility docs](https://developer.apple.com/documentation/swiftui/navigationsplitviewvisibility)
   and community references
   ([nilcoalescing](https://nilcoalescing.com/blog/ScenesTypesInASwiftUIMacApp/),
   [Ice's SettingsWindow.swift](https://github.com/jordanbaird/Ice/blob/main/Ice/Settings/SettingsWindow.swift))
   both point at the Scene path as canonical.

3. **The user's "this gesture warms it up" observation is gold.** It
   pointed at exactly what state needed to be realized up front, and
   let us synthesize a programmatic equivalent without guessing.

4. **Listen when a hypothesis test fails.** Six hypotheses were tried
   and discarded. The fix only became visible after we stopped
   defending the current theory and re-examined the symptom literally
   ("drag warms it up → simulate the drag").

## Long-Term Direction (Not in Scope)

The canonical macOS SwiftUI menu bar app pattern is to declare the
settings window as a SwiftUI `Window` scene:

```swift
@main
struct LiveWallpaperApp: App {
    var body: some Scene {
        MenuBarExtra { ... } label: { ... }

        Window("LiveWallpaper Settings", id: "settings") {
            ContentView()
                .environment(...)
        }
    }
}
```

And open it via `@Environment(\.openWindow)`. Ice ships this pattern.

Migrating LiveWallpaper to it would replace the manual `NSWindow +
NSHostingView` plumbing in `LiveWallpaperApp.swift` and remove the
need for the prewarm + hide-on-close pair entirely. It is a ~150 LOC
refactor across multiple call sites (menu bar entry, initial
navigation, AppDelegate) and was deemed out of scope for this fix.

Track this as a follow-up if the settings window grows or starts
acquiring more lifecycle issues.
