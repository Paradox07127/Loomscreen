# LiveWallpaper Release QA Matrix

## Status Legend

- Not Started
- In Progress
- Passed
- Failed
- Blocked
- Deferred with Owner Approval

## Acceptance Rule

A release candidate can be signed off only when every P0 and P1 row is Passed or Deferred with Owner Approval. P2 rows may remain open only if they do not affect data loss, crash risk, security, privacy, installability, or first-run success.

## Test Environment Matrix

| ID | Environment | Required | Status | Notes |
|---|---|---:|---|---|
| ENV-01 | Clean macOS user account, Apple Silicon | Yes | In Progress | App defaults were cleared and onboarding was exercised in the existing macOS account; still needs a separate clean-user account pass |
| ENV-02 | Existing user account with old LiveWallpaper defaults | Yes | In Progress | Existing user defaults were backed up and restored; old-version migration still needs fixture |
| ENV-03 | Single display | Yes | Not Started | Laptop or desktop main display |
| ENV-04 | Two displays with different scale factors | Yes | Passed | Computer Use run on RZ39-0276 2560x1440 and MPG321CX OLED 1920x1080 |
| ENV-05 | Battery-powered MacBook | Yes | Not Started | Battery pause and power monitoring |
| ENV-06 | Offline network | Yes | Not Started | Weather and remote HTML failure behavior |
| ENV-07 | Light appearance | Yes | Passed | System appearance was Light on 2026-05-10 continued QA; settings sidebar, empty state, video detail, controls, and shader view rendered as Light |
| ENV-08 | Dark appearance | Yes | Passed | Settings UI, empty state, video, HTML, shader, and inspector controls covered in Dark |
| ENV-09 | macOS 14.0-14.x, Apple Silicon | Yes | Not Started | Compatibility floor: launch, settings, menu bar, video, HTML, shader smoke. Material-based AdaptiveGlass fallback path. Intel intentionally unsupported. Run via VirtualBuddy VM — see [`vm-test-environment.md`](vm-test-environment.md). |
| ENV-10 | macOS 15.x, Apple Silicon | Yes | Not Started | Middle release: adaptive material UI and runtime smoke. `.continuouslyRepeating` resolves to `.repeat(.continuous)` here. Run via VirtualBuddy VM — see [`vm-test-environment.md`](vm-test-environment.md). |
| ENV-11 | macOS 26.x, Apple Silicon | Yes | Not Started | Native Liquid Glass path and current release baseline. `AVCIImageFiltering*` applier path active. Host machine or VirtualBuddy VM — see [`vm-test-environment.md`](vm-test-environment.md). |

## Functional QA

| ID | Priority | Area | Scenario | Expected Result | Status | Evidence |
|---|---|---|---|---|---|---|
| F-001 | P0 | First Run | Launch app after deleting user defaults | Onboarding appears, no crash, no unexpected permission prompt | Passed | Cleared `Taijia.LiveWallpaper` defaults, launched Debug app, completed onboarding with `qa-1080p-30fps.mp4`; no permission prompt appeared |
| F-002 | P0 | Video | Add MP4 via picker | Wallpaper applies, configuration persists after relaunch | Passed | `/tmp/LiveWallpaperQAAssets/qa-1080p-30fps.mp4`; relaunch restored video on RZ39-0276 |
| F-003 | P0 | Video | Add same MP4 twice after scoped bookmark failure fallback | Only one app-owned imported copy is reused | Passed | Unit coverage: bookmark fallback, dedupe, app-owned non-scoped validation in 560-test suite |
| F-004 | P0 | Video | Add video via drag/drop | Same persistence and playback behavior as picker | In Progress | Code now shares picker/drop video type validation through `ResourceUtilities` and rejects unsupported non-HTML drops before creating bookmarks; still needs live drag/drop pass |
| F-005 | P0 | Multi-display | Apply different wallpapers to two displays | Each display keeps independent wallpaper after relaunch | Passed | Applied video to both displays, then set second display to HTML; relaunch restored independent video/HTML states |
| F-006 | P0 | Playlist | Add multiple videos, enable shuffle, relaunch | Playlist order/settings persist and rotation works | Not Started | |
| F-007 | P0 | Schedule | Create two time slots and force current hour coverage | Correct scheduled video activates and restores primary outside slot | Not Started | |
| F-008 | P0 | HTML Local | Add local HTML file and folder | Local assets load, relaunch restores access | Passed | `/tmp/LiveWallpaperQAAssets/qa-local-html/index.html`; relaunch restored HTML access. Follow-up unit test confirms File mode remains `.file`; Folder mode is reserved for pages with sibling assets |
| F-009 | P1 | HTML Remote | Add untrusted remote URL | JavaScript is disabled until user trusts origin | Not Started | |
| F-010 | P1 | HTML Remote | Trust one origin and load subdomain/port variant | Trust does not leak to different origin | Not Started | |
| F-011 | P0 | Shader | Apply built-in shader | Shader renders, persists, and respects frame-rate limit | In Progress | Plasma selection persisted after relaunch and UI restored Shader mode; frame-rate-limit behavior still needs explicit measurement |
| F-012 | P0 | WPE Import | Import supported package | Package extracts safely, scene/video applies, cache path persists | Not Started | |
| F-013 | P1 | WPE Import | Import unsupported Windows-plugin scene | User sees actionable unsupported state, no crash | Not Started | |
| F-014 | P1 | Apple Aerials | Grant aerials folder and apply asset | Bookmark persists and playback starts | Not Started | |
| F-015 | P0 | Settings | Change playback speed, fit mode, mute, color effects | Controls persist and hot-apply without full rebuild where expected | Passed | Changed Fit, 1.5x speed, and Brightness +0.10 in Light mode; `screenConfigurations` persisted `fitMode=Fit`, `playbackSpeed=1.5`, and `brightness=0.09999999999999998` |
| F-016 | P1 | Weather | Use manual weather location | Weather effects update without CoreLocation prompt | Not Started | |
| F-017 | P1 | Weather | Use IP geolocation with network offline | App reports unavailable weather and keeps wallpaper running | Not Started | |
| F-018 | P1 | Weather | Use CoreLocation and deny permission | App falls back or shows clear error, no repeated prompt loop | Not Started | |
| F-019 | P0 | Power | Enable pause on battery | Wallpaper pauses/resumes according to power policy | Not Started | |
| F-020 | P0 | Full Screen | Enable pause on full-screen app | Wallpaper pauses behind full-screen app and resumes after exit | Not Started | |
| F-021 | P1 | Lock Screen | Enable desktop picture snapshot behavior | Current frame is written and set without blocking playback | Not Started | |
| F-022 | P0 | Window Chrome | Drag only title/top area | Sliders, split view resizing, and inspector controls remain interactive | Passed | Inspector divider resize worked without moving the window; accidental whole-window drag was not reproduced |
| F-023 | P0 | Theme | Switch Light/Dark appearance | Window backgrounds and text contrast match system appearance | Passed | Light and Dark settings views passed visual inspection; prior dark smoke and 2026-05-10 continued Light pass both showed readable contrast |
| F-024 | P1 | Menu Bar | Hide Dock icon and use menu bar app | App remains discoverable and settings can reopen | In Progress | General settings show `Show in Dock` off by default and settings can reopen through app delegate/UI-test path; status-item click path still needs direct menu bar verification |
| F-025 | P1 | Shortcuts | Configure global shortcuts | Hotkeys trigger actions and can be cleared/reassigned | In Progress | Shortcuts settings UI rendered defaults and unit tests cover binding persistence/default rendering; live global-hotkey trigger still needs manual OS-level pass |

## Install, Upgrade, And Removal QA

| ID | Priority | Scenario | Expected Result | Status | Evidence |
|---|---|---|---|---|---|
| I-001 | P0 | Install notarized build on clean user | Gatekeeper accepts app, app launches | Failed | Archive app is Apple Development signed and `spctl -a -vv --type execute` rejects it |
| I-002 | P0 | Replace older app build with RC | Existing configuration migrates and wallpapers restore | Not Started | |
| I-003 | P1 | Remove app-owned imported videos manually | App reports missing resource and lets user reselect | Not Started | |
| I-004 | P1 | Delete app and Application Support cache | No privileged helper or background service remains | Not Started | |
| I-005 | P1 | Toggle launch at login | Login item appears/disappears according to setting | Not Started | |

## Security And Privacy QA

| ID | Priority | Scenario | Expected Result | Status | Evidence |
|---|---|---|---|---|---|
| S-001 | P0 | Inspect final entitlements | Only required entitlements are present | In Progress | `scripts/release_candidate_check.sh` confirms Release build settings include sandbox entitlements and Hardened Runtime; final Developer ID export still needs entitlements inspection |
| S-002 | P0 | Inspect final signature | Developer ID signature is valid and strict verification passes | Failed | Release app CodeDirectory flags include `0x10000(runtime)`, but signature authority is still Apple Development; `REQUIRE_DEVELOPER_ID=1 scripts/release_candidate_check.sh` can now enforce the signing-machine gate |
| S-003 | P0 | Notarization | Notary service accepts artifact and ticket is stapled | Blocked | Blocked by missing Developer ID Application signing identity on this Mac |
| S-004 | P0 | Remote HTML external link | Link opens externally or stays constrained according to policy | Not Started | |
| S-005 | P0 | Local folder URL scheme | Path traversal outside selected folder fails | Not Started | |
| S-006 | P1 | Logs | Logs do not expose full sensitive URLs or precise location unexpectedly | In Progress | Runtime log sample reviewed; no bookmark failure in current import path. Static audit now fails broad `NSObject` NSSecureCoding decode allow-lists; full sensitive-data audit remains open |
| S-007 | P1 | Privacy prompt copy | Permission prompt strings are accurate and localized | Not Started | |
| S-008 | P0 | Privacy manifest | Required-reason APIs and collected data are declared in bundled manifest | Passed | `LiveWallpaper/PrivacyInfo.xcprivacy` lints cleanly and is present in `LiveWallpaper.app/Contents/Resources` |
