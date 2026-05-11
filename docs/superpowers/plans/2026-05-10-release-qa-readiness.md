# Release QA Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a repeatable release-candidate QA process that can decide whether LiveWallpaper is ready for a formal 1.0 distribution.

**Architecture:** Keep product QA, compliance QA, packaging QA, and sign-off artifacts separate so each release candidate can be audited independently. The plan creates durable checklists under `docs/qa/`, adds one local verification script for repeatable gates, and defines manual test matrices for macOS desktop behaviors that unit tests cannot reliably cover.

**Tech Stack:** Xcode/xcodebuild, Swift Testing, macOS App Sandbox, Developer ID signing, Hardened Runtime, Apple notarization, shell scripts, Markdown QA artifacts.

---

## Release QA Scope

This plan targets a Developer ID notarized release first. Mac App Store submission can reuse most artifacts, but needs a separate App Store review pass after Developer ID RCs are stable.

Current known release blockers from repository inspection:

- Release build currently reports `ENABLE_HARDENED_RUNTIME = NO`.
- No `PrivacyInfo.xcprivacy` file is present.
- No repository-level Privacy Policy, Terms/EULA, LICENSE, or release checklist exists.
- No archive/export/notarization script exists.
- README test count and release requirements are stale.
- Manual QA coverage is not yet documented for multi-display wallpaper behavior, security-scoped bookmarks, sleep/wake, lock screen, HTML trust, weather networking, startup item behavior, and cache cleanup.

## File Structure

- Create: `docs/qa/release-qa-matrix.md` - master manual QA matrix with owner/status/result columns.
- Create: `docs/qa/release-blockers.md` - triage list for release-blocking defects and deferral decisions.
- Create: `docs/qa/privacy-data-map.md` - data collection, storage, and network disclosure map.
- Create: `docs/qa/packaging-notarization-checklist.md` - Developer ID packaging and notarization acceptance checklist.
- Create: `docs/qa/performance-stability-protocol.md` - reproducible performance and soak-test protocol.
- Create: `docs/qa/rc-signoff-template.md` - final release candidate sign-off template.
- Create: `scripts/release_candidate_check.sh` - repeatable local verification command for unit tests, i18n guard, static audit, whitespace, and build-settings checks.
- Modify: `README.md` - update test count, supported macOS target rationale, and release verification pointer.
- Later implementation may modify: `LiveWallpaper.xcodeproj/project.pbxproj`, `LiveWallpaper/LiveWallpaper.entitlements`, and app resources when packaging/compliance tasks begin. Those changes are out of scope for this planning task.

---

### Task 1: Create The Master QA Matrix

**Files:**
- Create: `docs/qa/release-qa-matrix.md`
- Test: manual review plus `markdownlint` if available

- [ ] **Step 1: Create the QA matrix document**

Create `docs/qa/release-qa-matrix.md` with these sections:

```markdown
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
| ENV-01 | Clean macOS user account, Apple Silicon | Yes | Not Started | First-run and permissions baseline |
| ENV-02 | Existing user account with old LiveWallpaper defaults | Yes | Not Started | Upgrade and migration baseline |
| ENV-03 | Single display | Yes | Not Started | Laptop or desktop main display |
| ENV-04 | Two displays with different scale factors | Yes | Not Started | Multi-screen persistence and window frame behavior |
| ENV-05 | Battery-powered MacBook | Yes | Not Started | Battery pause and power monitoring |
| ENV-06 | Offline network | Yes | Not Started | Weather and remote HTML failure behavior |
| ENV-07 | Light appearance | Yes | Not Started | Theme regression |
| ENV-08 | Dark appearance | Yes | Not Started | Theme regression |

## Functional QA

| ID | Priority | Area | Scenario | Expected Result | Status | Evidence |
|---|---|---|---|---|---|---|
| F-001 | P0 | First Run | Launch app after deleting user defaults | Onboarding appears, no crash, no unexpected permission prompt | Not Started | |
| F-002 | P0 | Video | Add MP4 via picker | Wallpaper applies, configuration persists after relaunch | Not Started | |
| F-003 | P0 | Video | Add same MP4 twice after scoped bookmark failure fallback | Only one app-owned imported copy is reused | Not Started | |
| F-004 | P0 | Video | Add video via drag/drop | Same persistence and playback behavior as picker | Not Started | |
| F-005 | P0 | Multi-display | Apply different wallpapers to two displays | Each display keeps independent wallpaper after relaunch | Not Started | |
| F-006 | P0 | Playlist | Add multiple videos, enable shuffle, relaunch | Playlist order/settings persist and rotation works | Not Started | |
| F-007 | P0 | Schedule | Create two time slots and force current hour coverage | Correct scheduled video activates and restores primary outside slot | Not Started | |
| F-008 | P0 | HTML Local | Add local HTML file and folder | Local assets load, relaunch restores access | Not Started | |
| F-009 | P1 | HTML Remote | Add untrusted remote URL | JavaScript is disabled until user trusts origin | Not Started | |
| F-010 | P1 | HTML Remote | Trust one origin and load subdomain/port variant | Trust does not leak to different origin | Not Started | |
| F-011 | P0 | Shader | Apply built-in shader | Shader renders, persists, and respects frame-rate limit | Not Started | |
| F-012 | P0 | WPE Import | Import supported package | Package extracts safely, scene/video applies, cache path persists | Not Started | |
| F-013 | P1 | WPE Import | Import unsupported Windows-plugin scene | User sees actionable unsupported state, no crash | Not Started | |
| F-014 | P1 | Apple Aerials | Grant aerials folder and apply asset | Bookmark persists and playback starts | Not Started | |
| F-015 | P0 | Settings | Change playback speed, fit mode, mute, color effects | Controls persist and hot-apply without full rebuild where expected | Not Started | |
| F-016 | P1 | Weather | Use manual weather location | Weather effects update without CoreLocation prompt | Not Started | |
| F-017 | P1 | Weather | Use IP geolocation with network offline | App reports unavailable weather and keeps wallpaper running | Not Started | |
| F-018 | P1 | Weather | Use CoreLocation and deny permission | App falls back or shows clear error, no repeated prompt loop | Not Started | |
| F-019 | P0 | Power | Enable pause on battery | Wallpaper pauses/resumes according to power policy | Not Started | |
| F-020 | P0 | Full Screen | Enable pause on full-screen app | Wallpaper pauses behind full-screen app and resumes after exit | Not Started | |
| F-021 | P1 | Lock Screen | Enable desktop picture snapshot behavior | Current frame is written and set without blocking playback | Not Started | |
| F-022 | P0 | Window Chrome | Drag only title/top area | Sliders, split view resizing, and inspector controls remain interactive | Not Started | |
| F-023 | P0 | Theme | Switch Light/Dark appearance | Window backgrounds and text contrast match system appearance | Not Started | |
| F-024 | P1 | Menu Bar | Hide Dock icon and use menu bar app | App remains discoverable and settings can reopen | Not Started | |
| F-025 | P1 | Shortcuts | Configure global shortcuts | Hotkeys trigger actions and can be cleared/reassigned | Not Started | |

## Install, Upgrade, And Removal QA

| ID | Priority | Scenario | Expected Result | Status | Evidence |
|---|---|---|---|---|---|
| I-001 | P0 | Install notarized build on clean user | Gatekeeper accepts app, app launches | Not Started | |
| I-002 | P0 | Replace older app build with RC | Existing configuration migrates and wallpapers restore | Not Started | |
| I-003 | P1 | Remove app-owned imported videos manually | App reports missing resource and lets user reselect | Not Started | |
| I-004 | P1 | Delete app and Application Support cache | No privileged helper or background service remains | Not Started | |
| I-005 | P1 | Toggle launch at login | Login item appears/disappears according to setting | Not Started | |

## Security And Privacy QA

| ID | Priority | Scenario | Expected Result | Status | Evidence |
|---|---|---|---|---|---|
| S-001 | P0 | Inspect final entitlements | Only required entitlements are present | Not Started | |
| S-002 | P0 | Inspect final signature | Developer ID signature is valid and strict verification passes | Not Started | |
| S-003 | P0 | Notarization | Notary service accepts artifact and ticket is stapled | Not Started | |
| S-004 | P0 | Remote HTML external link | Link opens externally or stays constrained according to policy | Not Started | |
| S-005 | P0 | Local folder URL scheme | Path traversal outside selected folder fails | Not Started | |
| S-006 | P1 | Logs | Logs do not expose full sensitive URLs or precise location unexpectedly | Not Started | |
| S-007 | P1 | Privacy prompt copy | Permission prompt strings are accurate and localized | Not Started | |
```

- [ ] **Step 2: Review the matrix against current features**

Run:

```bash
rg -n "setVideo|setHTMLWallpaper|setShaderWallpaper|updateScheduleSlots|updatePlaylistBookmarks|WeatherReactiveService|GlobalShortcutManager|SMAppService|setDesktopImageURL" LiveWallpaper
```

Expected: Every major feature entry in the QA matrix has at least one matching implementation surface.

- [ ] **Step 3: Commit**

```bash
git add docs/qa/release-qa-matrix.md
git commit -m "docs: add release QA matrix"
```

### Task 2: Create The Release Blocker Triage Log

**Files:**
- Create: `docs/qa/release-blockers.md`

- [ ] **Step 1: Create the blocker log**

Create `docs/qa/release-blockers.md`:

```markdown
# LiveWallpaper Release Blockers

## Severity Definitions

- P0: Blocks release. Crash, data loss, install failure, privacy/security issue, broken first-run, or core wallpaper cannot persist.
- P1: Should block release unless explicitly deferred. Major feature broken, severe UX regression, high battery/performance risk.
- P2: Can ship with release note or follow-up issue. Non-core visual or convenience issue.

## Open Blockers

| ID | Severity | Area | Issue | Repro | Owner | Decision | Status |
|---|---|---|---|---|---|---|---|
| RB-001 | P0 | Packaging | Release Hardened Runtime is disabled | `xcodebuild -showBuildSettings -configuration Release` reports `ENABLE_HARDENED_RUNTIME = NO` | Engineering | Fix before notarized RC | Open |
| RB-002 | P0 | Privacy | No `PrivacyInfo.xcprivacy` exists | `find LiveWallpaper -name '*.xcprivacy'` returns no files | Engineering | Add before RC | Open |
| RB-003 | P0 | Legal | No Privacy Policy or Terms/EULA document exists | `find . -iname '*privacy*' -o -iname '*terms*' -o -iname '*license*'` returns no policy docs | Product/Legal | Add before public release | Open |
| RB-004 | P1 | Documentation | README test count is stale | README says 193 tests; current suite reports 553 tests | Engineering | Update before RC | Open |
| RB-005 | P1 | Security | Source of NSSecureCoding allowed-classes warning is not identified | Runtime log includes `allowed classes list contains [NSObject class]` | Engineering | Investigate before RC | Open |

## Deferred Issues

| ID | Severity | Area | Issue | Why Deferrable | Owner Approval | Follow-up |
|---|---|---|---|---|---|---|
```

- [ ] **Step 2: Add issues discovered during QA**

For every failed P0/P1 matrix row, add a row with:

```text
ID, Severity, Area, Issue, Repro, Owner, Decision, Status
```

Expected: No failed P0/P1 test exists only in chat or memory.

- [ ] **Step 3: Commit**

```bash
git add docs/qa/release-blockers.md
git commit -m "docs: add release blocker triage log"
```

### Task 3: Build The Privacy And Data Map

**Files:**
- Create: `docs/qa/privacy-data-map.md`
- Later create: `LiveWallpaper/Resources/PrivacyInfo.xcprivacy`

- [ ] **Step 1: Create the privacy data map**

Create `docs/qa/privacy-data-map.md`:

```markdown
# LiveWallpaper Privacy And Data Map

## Product Position

LiveWallpaper has no account system, no advertising SDK, and no analytics SDK in the repository. The app uses local settings, user-selected local files, optional weather networking, optional CoreLocation, remote HTML chosen by the user, and app-owned caches.

## Local Storage

| Data | Storage | Purpose | User Visible | Removal |
|---|---|---|---|---|
| Screen wallpaper configuration | `UserDefaults.screenConfigurations` | Restore wallpapers across launches | Yes | Reset settings or delete app defaults |
| Global settings | `UserDefaults.globalSettings` | Restore app preferences | Yes | Reset settings or delete app defaults |
| Security-scoped bookmarks | UserDefaults encoded data | Persist access to selected videos/HTML/folders | Indirectly | Remove wallpaper/bookmark or reset settings |
| App-owned imported videos | `~/Library/Application Support/LiveWallpaper/ImportedVideos/` | Fallback when macOS cannot create app-scope bookmark | Yes | Cache cleanup UI or manual removal |
| WPE cache | `~/Library/Application Support/LiveWallpaper/wpe-cache/` | Extracted Wallpaper Engine packages | Yes | Cache management UI or manual removal |
| Trusted HTML hosts | `UserDefaults.TrustedHTMLHosts.v1` | Allow JavaScript for trusted origins | Yes | Remove trusted host/reset settings |
| WKWebView website data | WebKit data store or non-persistent store based on setting | Remote/local HTML wallpaper functionality | Yes | Enable private mode or clear website data |

## Network Requests

| Destination | Trigger | Data Sent | Data Received | User Control | Disclosure |
|---|---|---|---|---|---|
| `https://api.open-meteo.com` | Weather-reactive effects enabled | Latitude/longitude in query | Weather code, temperature, cloud cover | Disable weather or use manual/IP/CoreLocation settings | Weather functionality |
| `https://ipapi.co/json/` | Weather source set to IP geolocation or fallback | IP address as part of HTTPS request | Coarse latitude/longitude, city, country | Choose manual or CoreLocation source, disable weather | Coarse location via IP |
| User-entered remote HTML URL | User chooses remote HTML wallpaper | Normal WebKit request data for that URL | Web content | User controls URL; JS disabled until trusted | User-directed web content |

## Permission Prompts

| Permission | Info.plist Key | Trigger | Required For |
|---|---|---|---|
| Location | `NSLocationWhenInUseUsageDescription` | Weather source set to CoreLocation | Weather-reactive effects |
| User-selected files | Sandbox user-selected files/bookmarks | Video/HTML/WPE folder pickers | Wallpaper playback and persistence |
| Downloads/Movies folder read-only | Sandbox entitlement | User selects files from these folders | File playback |
| Startup items | `com.apple.security.automation.startup-items` | Launch at login toggle | Start app at login |

## Privacy Manifest Decisions To Verify

| Item | Expected Decision | Evidence Needed |
|---|---|---|
| Tracking | No tracking | No ad SDK, no analytics SDK, no data broker sharing |
| Crash analytics | Not collected by app | No crash reporting SDK present |
| Precise location | Only if CoreLocation weather source is used and sent to Open-Meteo | Confirm user-facing setting and policy copy |
| Coarse location | IP geolocation weather source sends IP to ipapi.co and receives coarse coordinate | Confirm policy copy |
| User content | User-selected local files stay local unless remote HTML itself loads network content | Confirm policy copy |
```

- [ ] **Step 2: Verify source references**

Run:

```bash
rg -n "api.open-meteo.com|ipapi.co|URLSession|UserDefaults|WKWebsiteDataStore|bookmarkData|Application Support|NSLocationWhenInUseUsageDescription|SMAppService" LiveWallpaper LiveWallpaperInfo.plist
```

Expected: Every privacy data-map row has a matching code or plist reference.

- [ ] **Step 3: Commit**

```bash
git add docs/qa/privacy-data-map.md
git commit -m "docs: map release privacy data flows"
```

### Task 4: Define Packaging And Notarization QA

**Files:**
- Create: `docs/qa/packaging-notarization-checklist.md`

- [ ] **Step 1: Create the packaging checklist**

Create `docs/qa/packaging-notarization-checklist.md`:

```markdown
# LiveWallpaper Packaging And Notarization Checklist

## Current Project Findings

- Release configuration uses `LiveWallpaper/LiveWallpaper.entitlements`.
- Release configuration has `ENABLE_APP_SANDBOX = YES`.
- Release build settings currently report `ENABLE_HARDENED_RUNTIME = NO`; this must be fixed before notarization.
- Release bundle identifier is `Taijia.LiveWallpaper`.
- Current marketing version is `1.0`, build number is `1`.

## Archive Gate

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild archive \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaper \
  -configuration Release \
  -archivePath /tmp/LiveWallpaper-RC.xcarchive
```

Expected:

- Command exits 0.
- Archive exists at `/tmp/LiveWallpaper-RC.xcarchive`.
- Archive contains `Products/Applications/LiveWallpaper.app`.

## Signing Gate

Run:

```bash
codesign -dvvv --entitlements :- /tmp/LiveWallpaper-RC.xcarchive/Products/Applications/LiveWallpaper.app
codesign --verify --deep --strict --verbose=4 /tmp/LiveWallpaper-RC.xcarchive/Products/Applications/LiveWallpaper.app
```

Expected:

- Final signature uses Developer ID Application for public distribution.
- `com.apple.security.get-task-allow` is absent or false.
- Hardened Runtime is enabled.
- Only required entitlements are present.
- Strict verification exits 0.

## Notarization Gate

Package:

```bash
ditto -c -k --keepParent \
  /tmp/LiveWallpaper-RC.xcarchive/Products/Applications/LiveWallpaper.app \
  /tmp/LiveWallpaper-RC.zip
```

Submit:

```bash
xcrun notarytool submit /tmp/LiveWallpaper-RC.zip \
  --keychain-profile "LiveWallpaper-notarytool" \
  --wait
```

Staple:

```bash
xcrun stapler staple /tmp/LiveWallpaper-RC.xcarchive/Products/Applications/LiveWallpaper.app
xcrun stapler validate /tmp/LiveWallpaper-RC.xcarchive/Products/Applications/LiveWallpaper.app
spctl -a -vv --type execute /tmp/LiveWallpaper-RC.xcarchive/Products/Applications/LiveWallpaper.app
```

Expected:

- Notary status is Accepted.
- Stapler validate exits 0.
- `spctl` accepts the app.

## Distribution Artifact Gate

If distributing a ZIP:

- ZIP must preserve app bundle.
- Downloaded ZIP must expand to a stapled app.
- App must launch from Downloads without bypassing Gatekeeper.

If distributing a DMG:

- DMG must be signed or generated after app signing.
- DMG must be notarized or contain a stapled notarized app.
- Drag-to-Applications flow must work.
```

- [ ] **Step 2: Commit**

```bash
git add docs/qa/packaging-notarization-checklist.md
git commit -m "docs: add packaging notarization checklist"
```

### Task 5: Define Performance And Stability Protocol

**Files:**
- Create: `docs/qa/performance-stability-protocol.md`

- [ ] **Step 1: Create the performance protocol**

Create `docs/qa/performance-stability-protocol.md`:

```markdown
# LiveWallpaper Performance And Stability Protocol

## Baseline Capture

Record for every RC:

| Metric | Source | Pass Target |
|---|---|---|
| Idle CPU with one 1080p video | Activity Monitor plus in-app monitor | No sustained runaway CPU after 5 minutes |
| Idle CPU with two displays | Activity Monitor plus in-app monitor | Stable after 5 minutes |
| Memory after 30 minutes | Activity Monitor | No unbounded growth trend |
| Energy impact on battery | Activity Monitor | No unexpected spike when paused |
| FPS estimate | In-app monitor | Stable under configured frame-rate limit |
| Thermal state | In-app monitor | Does not climb under normal 1080p single-display playback |

## Test Assets

Use local files with these names so reports are comparable:

| Asset | Requirement |
|---|---|
| `qa-1080p-30fps.mp4` | H.264 or HEVC, 3 minutes or longer |
| `qa-4k-60fps.mp4` | 4K, 60 fps, 3 minutes or longer |
| `qa-alpha-or-high-bitrate.mov` | MOV stress case |
| `qa-local-html/index.html` | HTML with CSS, JS, image, and video sibling assets |
| `qa-remote-html-url.txt` | User-chosen HTTPS page for remote HTML smoke test |
| `qa-wpe-supported` | Supported Wallpaper Engine package/folder |
| `qa-wpe-unsupported` | Known unsupported Windows-plugin scene |

## Soak Tests

| ID | Duration | Scenario | Pass Criteria |
|---|---:|---|---|
| SOAK-01 | 2 hours | One 1080p video, effects disabled | No crash, no memory growth trend, no window reposition drift |
| SOAK-02 | 2 hours | Two displays, different wallpapers | No cross-display config swap, no runaway CPU |
| SOAK-03 | 1 hour | 4K video with effects and particles | App remains responsive, thermal/energy behavior documented |
| SOAK-04 | 1 hour | HTML wallpaper with private mode enabled | Web content remains isolated, no crash on reload |
| SOAK-05 | Overnight | Playlist rotation and schedule enabled | Correct active item in morning, no dead playback session |

## Required Evidence

For each soak:

- RC build identifier.
- macOS version.
- Mac model and chip.
- Display count and resolutions.
- Test asset names.
- Start/end time.
- CPU/memory/energy screenshots or notes.
- Any runtime logs around warnings/errors.
```

- [ ] **Step 2: Commit**

```bash
git add docs/qa/performance-stability-protocol.md
git commit -m "docs: add performance stability protocol"
```

### Task 6: Add A Repeatable RC Verification Script

**Files:**
- Create: `scripts/release_candidate_check.sh`

- [ ] **Step 1: Write the script**

Create `scripts/release_candidate_check.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DERIVED_DATA="${DERIVED_DATA:-/tmp/LiveWallpaperReleaseCandidateCheck}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

echo "== Release build settings =="
xcodebuild -showBuildSettings \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaper \
  -configuration Release \
  | tee /tmp/livewallpaper-release-build-settings.txt \
  | rg "PRODUCT_BUNDLE_IDENTIFIER|MARKETING_VERSION|CURRENT_PROJECT_VERSION|MACOSX_DEPLOYMENT_TARGET|ENABLE_HARDENED_RUNTIME|CODE_SIGN|DEVELOPMENT_TEAM|ENABLE_APP_SANDBOX|ENABLE_USER_SELECTED_FILES|ENTITLEMENTS"

if ! rg -q "ENABLE_HARDENED_RUNTIME = YES" /tmp/livewallpaper-release-build-settings.txt; then
  echo "ERROR: Release Hardened Runtime is not enabled." >&2
  exit 1
fi

echo "== Unit tests =="
xcodebuild test \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaper \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -only-testing:LiveWallpaperTests

echo "== i18n guard =="
I18N_GUARD_SCOPE=all scripts/i18n_guard.sh

echo "== Static audit =="
scripts/audit.sh static

echo "== Diff whitespace check =="
git diff --check

echo "Release candidate checks passed."
```

- [ ] **Step 2: Make the script executable**

Run:

```bash
chmod +x scripts/release_candidate_check.sh
```

- [ ] **Step 3: Run it and record current expected failure**

Run:

```bash
scripts/release_candidate_check.sh
```

Expected before packaging work: FAIL with `ERROR: Release Hardened Runtime is not enabled.`

- [ ] **Step 4: Commit**

```bash
git add scripts/release_candidate_check.sh
git commit -m "chore: add release candidate verification script"
```

### Task 7: Create The RC Sign-Off Template

**Files:**
- Create: `docs/qa/rc-signoff-template.md`

- [ ] **Step 1: Create sign-off template**

Create `docs/qa/rc-signoff-template.md`:

```markdown
# LiveWallpaper RC Sign-Off

## Candidate

| Field | Value |
|---|---|
| Version | 1.0 |
| Build | 1 |
| Git commit | |
| Archive path | |
| Distribution artifact | |
| Notarization request ID | |
| macOS SDK | |
| Xcode version | |

## Automated Gates

| Gate | Command | Result | Evidence |
|---|---|---|---|
| Unit tests | `xcodebuild test -only-testing:LiveWallpaperTests` | | |
| i18n guard | `I18N_GUARD_SCOPE=all scripts/i18n_guard.sh` | | |
| Static audit | `scripts/audit.sh static` | | |
| Whitespace | `git diff --check` | | |
| Archive | `xcodebuild archive ...` | | |
| Codesign verify | `codesign --verify --deep --strict --verbose=4 ...` | | |
| Notarization | `xcrun notarytool submit ... --wait` | | |
| Gatekeeper | `spctl -a -vv --type execute ...` | | |

## Manual Gates

| Area | Matrix Rows | Result | Evidence |
|---|---|---|---|
| First run | F-001 | | |
| Core video persistence | F-002, F-003, F-004 | | |
| Multi-display | F-005 | | |
| Playlist and schedule | F-006, F-007 | | |
| HTML | F-008, F-009, F-010 | | |
| Shader and WPE | F-011, F-012, F-013 | | |
| Weather and power | F-016, F-017, F-018, F-019, F-020 | | |
| Theme and window behavior | F-022, F-023 | | |
| Install/upgrade/removal | I-001 through I-005 | | |
| Security/privacy | S-001 through S-007 | | |

## Open Issues

| ID | Severity | Decision |
|---|---|---|

## Sign-Off

| Role | Name | Decision | Date |
|---|---|---|---|
| Engineering | | | |
| Product | | | |
| Legal/Privacy | | | |
| Release Owner | | | |
```

- [ ] **Step 2: Commit**

```bash
git add docs/qa/rc-signoff-template.md
git commit -m "docs: add RC signoff template"
```

### Task 8: Update README Release Readiness Notes

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update stale test count and release pointer**

Change the README feature list so the test-count line reads:

```markdown
- **553 Unit Tests** — Policies, decoders, bookmarks, HTML trust, schedule, playlist, WPE import/rendering, and release regressions
```

Add this section after `## Documentation`:

```markdown
## Release Readiness

- `docs/qa/release-qa-matrix.md` — Manual release-candidate QA matrix.
- `docs/qa/release-blockers.md` — P0/P1 blocker triage.
- `docs/qa/privacy-data-map.md` — Privacy and data-flow review source.
- `docs/qa/packaging-notarization-checklist.md` — Developer ID signing and notarization gate.
- `docs/qa/performance-stability-protocol.md` — Performance and soak-test protocol.
- `docs/qa/rc-signoff-template.md` — Final release candidate sign-off template.
- `scripts/release_candidate_check.sh` — Automated local release-candidate checks.
```

- [ ] **Step 2: Verify README references exist**

Run:

```bash
for path in \
  docs/qa/release-qa-matrix.md \
  docs/qa/release-blockers.md \
  docs/qa/privacy-data-map.md \
  docs/qa/packaging-notarization-checklist.md \
  docs/qa/performance-stability-protocol.md \
  docs/qa/rc-signoff-template.md \
  scripts/release_candidate_check.sh
do
  test -e "$path"
done
```

Expected: command exits 0.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document release readiness workflow"
```

### Task 9: Run Plan-Level Verification

**Files:**
- Verify all files created by Tasks 1-8

- [ ] **Step 1: Verify required QA files exist**

Run:

```bash
test -f docs/qa/release-qa-matrix.md
test -f docs/qa/release-blockers.md
test -f docs/qa/privacy-data-map.md
test -f docs/qa/packaging-notarization-checklist.md
test -f docs/qa/performance-stability-protocol.md
test -f docs/qa/rc-signoff-template.md
test -x scripts/release_candidate_check.sh
```

Expected: command exits 0.

- [ ] **Step 2: Verify automated QA script reaches the known release blocker**

Run:

```bash
scripts/release_candidate_check.sh
```

Expected before packaging fixes: command fails with `ERROR: Release Hardened Runtime is not enabled.`

- [ ] **Step 3: Verify current test suite still passes independently**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaper \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/LiveWallpaperReleaseQAPlan \
  -only-testing:LiveWallpaperTests
```

Expected: `Test run with 553 tests in 87 suites passed`.

- [ ] **Step 4: Commit**

```bash
git status --short
git add docs/qa README.md scripts/release_candidate_check.sh
git commit -m "docs: complete release QA readiness plan artifacts"
```

---

## Execution Notes

- Do not start packaging fixes until Task 1 through Task 7 exist; otherwise release evidence will be scattered.
- Do not mark RB-001 closed until a Release build shows `ENABLE_HARDENED_RUNTIME = YES` and `codesign` confirms Hardened Runtime on the exported app.
- Do not mark privacy tasks complete until the app has both a privacy data map and a bundled `PrivacyInfo.xcprivacy`.
- Do not sign off an RC from a dirty working tree unless the sign-off explicitly records the dirty files and why they are included.
- Do not distribute an artifact that has not passed `spctl -a -vv --type execute`.

## References

- Apple Developer ID certificates: https://developer.apple.com/help/account/certificates/create-developer-id-certificates/
- Apple notarization workflow: https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
- Apple Hardened Runtime: https://developer.apple.com/documentation/security/hardened-runtime
- Apple App Privacy Details: https://developer.apple.com/app-store/app-privacy-details/
