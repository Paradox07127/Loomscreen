# macOS Compatibility VM — Test Environment Guide

Operational guide for the local macOS-14 (and future macOS-15 / macOS-26) virtual
machines used to verify the project's multi-version compatibility floor (see
`CLAUDE.md` §9, [PR #79](https://github.com/Paradox07127/LiveWallpaper/pull/79)).

**Audience**: anyone — including future Claude sessions — who needs to launch a
build inside the macOS-14 VM, inspect crashes, or extend the VM matrix.

**Status**: production. Active VM at the time of writing: `lw-vm-14` (macOS
14.6.1 ARM, hosted via [VirtualBuddy](https://github.com/insidegui/VirtualBuddy)
on macOS 26 host).

---

## 1. Why we have this

Apple does **not** ship a macOS Simulator (see [Apple devices-and-simulator
docs](https://developer.apple.com/documentation/xcode/devices-and-simulator) —
only iOS / iPadOS / watchOS / tvOS / visionOS have simulators). The supported
way to exercise `if #available(macOS 14, *)` / `if #available(macOS 15, *)`
fallback paths without owning multiple Macs is **Apple's own
[Virtualization.framework](https://developer.apple.com/documentation/virtualization)**,
wrapped here by VirtualBuddy.

The project's macOS-14 compatibility floor (`Packages/*/Package.swift` →
`.macOS(.v14)`, `MACOSX_DEPLOYMENT_TARGET = 14.0` in `project.pbxproj`) is
enforced statically by `LiveWallpaperTests/MacOSCompatibilityPolicyTests.swift`,
but **runtime-path verification on real macOS 14 only happens in the VM**.

---

## 2. Canonical reference — paths & names

These are the only values you should hard-code in scripts. Anything else is
derived.

| Concept                | Value                                                                 |
|------------------------|-----------------------------------------------------------------------|
| SSH alias              | `lw-vm-14`                                                            |
| Guest IP (DHCP)        | `192.168.64.2` (current; reservable in VirtualBuddy)                  |
| Guest user             | `taijial`                                                             |
| Host SSH key           | `~/.ssh/lw_vm` (ed25519, no passphrase)                               |
| Host bridge dir        | `/Users/dev/Xcode/LiveWallpaper/.vm-bridge/` (gitignored)         |
| Guest bridge mount     | `/Users/dev/Desktop/VirtualBuddyShared/.vm-bridge/`               |
| Bridge sub-folders     | `builds/  dsyms/  crashes/  logs/  samples/`                          |
| Wallpaper library (host)  | `/Users/dev/Documents/Live Wallpapers/` (15 GB, user-owned)    |
| Wallpaper library (guest) | `/Users/dev/Desktop/VirtualBuddyShared/Live Wallpapers/` **(read-only)** |
| Bundle ID              | `Taijia.LiveWallpaper`                                                |
| Team ID                | `FWJP4B62U7`                                                          |

**Bridge naming rule**: anything you put in the host dir is *immediately*
visible in the guest dir. No `rsync`/`scp` needed for files that fit the bridge
purpose.

---

## 3. One-time host + guest setup

Follow this once per new VM. Most steps are idempotent.

### 3.1 Install the tooling on host

```bash
brew install --cask virtualbuddy        # GUI VM manager
xcode-select --install                  # nm / otool / atos / xcrun
```

### 3.2 Create the macOS 14 guest

In VirtualBuddy:

1. **+** → **Restore Image** → pick **macOS 14.x** from the catalog.
2. CPU 4, RAM 8 GB, disk 60 GB.
3. After install completes, run macOS Setup Assistant (Apple ID **optional** —
   it does not affect compatibility testing).

### 3.3 Install `VirtualBuddyGuest.app` inside the guest

Required for clipboard share + auto-mount of shared folders.

1. Guest's Finder sidebar → **Guest** disk → double-click
   `VirtualBuddyGuest.app`.
2. Right-click → **Open** to pass Gatekeeper. The app self-installs to
   `/Applications/` and registers a LaunchAgent.

Verify in guest:

```bash
ls /Applications/VirtualBuddyGuest.app
launchctl list | grep -i virtualbuddy
```

The menu-bar icon should be present whenever the VM is running.

### 3.4 Configure shared folders

**The VM must be off** to change shared-folder configuration.

VirtualBuddy → select the VM → **Edit Virtual Machine** → **Sharing** tab.

Add two entries (each: **+** → pick folder → set name → set permission):

| # | Host folder                                          | Name in VirtualBuddy | Permission     | Purpose                                |
|---|------------------------------------------------------|----------------------|----------------|----------------------------------------|
| 1 | `/Users/dev/Xcode/LiveWallpaper/.vm-bridge`      | `vm-bridge`          | **Read & Write** | Build artifacts, crash logs, samples |
| 2 | `/Users/dev/Documents/Live Wallpapers`           | (uses folder name)   | **Read only**  | User wallpaper library (15 GB)         |

After boot, VirtualBuddyGuest mounts both under
`/Users/dev/Desktop/VirtualBuddyShared/`:

```
/Users/dev/Desktop/VirtualBuddyShared/
├── .vm-bridge/            ← read-write debug bridge
└── Live Wallpapers/       ← read-only wallpaper library (note the space)
```

Each shared folder is an independent VirtioFS export — symlinks crossing the
boundary do **not** resolve in the guest, so always declare a real shared
folder rather than symlinking through `vm-bridge`.

If VirtualBuddyGuest isn't installed yet, mount manually each boot:
```bash
mkdir -p ~/Desktop/VirtualBuddyShared/.vm-bridge ~/Desktop/VirtualBuddyShared/Live\ Wallpapers
mount_virtiofs vm-bridge ~/Desktop/VirtualBuddyShared/.vm-bridge
mount_virtiofs 'Live Wallpapers' ~/Desktop/VirtualBuddyShared/Live\ Wallpapers
```

### 3.5 Enable SSH in guest

```bash
# Inside the guest
sudo systemsetup -setremotelogin on
# Or: System Settings → General → Sharing → Remote Login ✅
```

### 3.6 Generate SSH key and copy to guest (host side)

```bash
ssh-keygen -t ed25519 -f ~/.ssh/lw_vm -N ""
ssh-copy-id -i ~/.ssh/lw_vm.pub taijial@192.168.64.2
```

### 3.7 Register the `lw-vm-14` alias

Append to `~/.ssh/config`:

```
Host lw-vm-14
  HostName 192.168.64.2
  User taijial
  IdentityFile ~/.ssh/lw_vm
  StrictHostKeyChecking accept-new
```

Sanity check:
```bash
ssh lw-vm-14 'sw_vers && uname -m'
# Expect: macOS 14.x ARM → arm64
```

### 3.8 (Optional) Install CLI symbol tools in the guest

For in-VM `nm` / `otool` / `atos` / `sample` / `spindump`, install the CLT:
```bash
ssh lw-vm-14 'xcode-select --install'   # GUI dialog appears in guest
```

This is **already done on `lw-vm-14`** (verified May 2026).

---

## 4. Daily workflow

### 4.1 Build → push → run

Run from host repo root.

```bash
# 1. Build Debug for ARM macOS
xcodebuild \
  -scheme LiveWallpaper \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build \
  -skipPackagePluginValidation -skipMacroValidation \
  build

# 2. Locate the real .app — Xcode may place a 1-MB SwiftUI-preview stub in
#    ./build/Build/Products/Debug/. Use DerivedData if the build is too small:
APP_LOCAL=build/Build/Products/Debug/LiveWallpaper.app
if [ "$(du -sm "$APP_LOCAL" | cut -f1)" -lt 50 ]; then
  APP_LOCAL=$(ls -dt ~/Library/Developer/Xcode/DerivedData/LiveWallpaper-*/Build/Products/Debug/LiveWallpaper.app \
              | grep -v Index.noindex | head -1)
fi
echo "Using: $APP_LOCAL ($(du -sh "$APP_LOCAL" | cut -f1))"

# 3. Stage into bridge (VirtioFS makes it instantly visible in guest)
rsync -a --delete "$APP_LOCAL" .vm-bridge/builds/

# 4. Launch in guest (strip quarantine first — VirtioFS files inherit
#    com.apple.provenance / com.apple.quarantine)
ssh lw-vm-14 '
  APP="/Users/dev/Desktop/VirtualBuddyShared/.vm-bridge/builds/LiveWallpaper.app"
  pkill LiveWallpaper 2>/dev/null || true
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  open "$APP"
'
```

> **Why DerivedData**: Xcode's "Make Build Debugging Faster" places the real
> code in `LiveWallpaper.debug.dylib` (~40 MB) inside `Contents/MacOS/`. The
> shim binary in `./build` is sometimes a stub used for SwiftUI previews. A
> healthy Debug build is ~85 MB.

### 4.2 Watch it run

```bash
# Process state
ssh lw-vm-14 'ps -o pid,etime,pcpu,pmem,rss -p $(pgrep LiveWallpaper)'

# Live unified-log stream (project Logger output)
ssh lw-vm-14 'log stream --process LiveWallpaper --level debug --info'
```

If the project still lacks `os.Logger` subsystem hooks, system-level messages
about the app are still capturable via:
```bash
ssh lw-vm-14 'log stream --predicate "sender == \"LiveWallpaper\" OR
                                       eventMessage CONTAINS \"LiveWallpaper\""'
```

### 4.3 Capture a stack snapshot

```bash
ssh lw-vm-14 '
  PID=$(pgrep LiveWallpaper)
  sample $PID 5 -file "/Users/dev/Desktop/VirtualBuddyShared/.vm-bridge/samples/sample-$(date +%Y%m%d-%H%M%S).txt"
'
ls -lt .vm-bridge/samples/ | head -3
```

### 4.4 Clean shutdown

```bash
ssh lw-vm-14 'osascript -e "tell application id \"Taijia.LiveWallpaper\" to quit"'
# Force fallback:
ssh lw-vm-14 'pkill LiveWallpaper 2>/dev/null || true'
```

---

## 5. Crash log workflow

`.ips` (Apple JSON crash format, macOS 12+) lands in
`~/Library/Logs/DiagnosticReports/` in the guest. The simplest route is to
bridge them automatically.

### 5.1 One-time bridge agent in guest

Install a `launchd` watcher so new `.ips` files are mirrored to the bridge as
soon as they appear:

```bash
ssh lw-vm-14 'mkdir -p ~/Library/LaunchAgents'
ssh lw-vm-14 'cat > ~/Library/LaunchAgents/io.taijial.livewallpaper.crash-bridge.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>io.taijial.livewallpaper.crash-bridge</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string><string>-c</string>
    <string>cp -n ~/Library/Logs/DiagnosticReports/LiveWallpaper-*.ips
            "/Users/dev/Desktop/VirtualBuddyShared/.vm-bridge/crashes/"
            2>/dev/null || true</string>
  </array>
  <key>WatchPaths</key>
  <array><string>/Users/dev/Library/Logs/DiagnosticReports</string></array>
  <key>ThrottleInterval</key><integer>2</integer>
</dict></plist>
PLIST'
ssh lw-vm-14 'launchctl load ~/Library/LaunchAgents/io.taijial.livewallpaper.crash-bridge.plist'
```

### 5.2 On-demand pull

```bash
ssh lw-vm-14 'ls -t ~/Library/Logs/DiagnosticReports/LiveWallpaper-*.ips' \
  | head -1 \
  | xargs -I{} scp lw-vm-14:'{}' .vm-bridge/crashes/
```

### 5.3 Symbolicate

Debug builds embed DWARF in the binary, so the `.app` itself serves as its own
dSYM. Run on **host**:

```bash
# Get LiveWallpaper image's load address & target frame from the .ips JSON
# (search for "LiveWallpaper" in the file)

atos -arch arm64 \
  -o .vm-bridge/builds/LiveWallpaper.app/Contents/MacOS/LiveWallpaper.debug.dylib \
  -l 0x100000000   <crash_address>
```

Or drop the `.ips` file onto Xcode — Organizer's auto-symbolication picks up
the matching binary from Spotlight if `.vm-bridge/builds/` is indexed.

---

## 6. Verifying compatibility fallbacks engaged

The whole point of the VM. Two complementary techniques.

### 6.1 Static — symbol audit

After PR #79, every Liquid Glass site routes through `AdaptiveGlass*` in
`Packages/LiveWallpaperSharedUI`. The mangled symbols must appear in the Debug
dylib:

```bash
DYLIB=.vm-bridge/builds/LiveWallpaper.app/Contents/MacOS/LiveWallpaper.debug.dylib

# AdaptiveGlassContainer / adaptiveGlassSurface / adaptiveGlassButton must exist
nm "$DYLIB" 2>/dev/null | grep -E "AdaptiveGlass" | wc -l   # expect > 0
```

If 0 → wrapper layer was bypassed → static `MacOSCompatibilityPolicyTests`
would have already caught it before reaching here. Cross-check with:
```bash
xcodebuild test -scheme LiveWallpaper \
  -only-testing:LiveWallpaperTests/MacOSCompatibilityPolicyTests \
  -destination 'platform=macOS,arch=arm64'
```

### 6.2 Dynamic — link audit on the running process

If the app links any macOS-26 Liquid Glass weak symbol that the runtime
resolves to `NULL`, you may see `dyld` warnings or, worse, a silent
no-op render. Confirm process is healthy and didn't fall back to a stub:

```bash
ssh lw-vm-14 '
  PID=$(pgrep LiveWallpaper)
  # Glass / GlassEffect symbols must NOT appear as called functions
  sample $PID 2 -file /tmp/s.txt 2>/dev/null
  grep -iE "GlassEffect|GlassEffectContainer" /tmp/s.txt | head
'
```

Expected: no output. Any hit indicates a missed wrapper site.

### 6.3 Importing wallpapers from the host library

The user wallpaper library is mounted **read-only** into the guest. In the
running app, use **Add Wallpaper** → file picker → navigate to:

```
/Users/dev/Desktop/VirtualBuddyShared/Live Wallpapers/
```

Pick any `.mp4` / `.mov` / Steam Workshop subdirectory. The app's scoped
bookmark will resolve to the VirtioFS path; this **works inside this VM
instance** but is **not portable** to another VM or back to the host (each
VM has its own VirtioFS namespace). Re-import is required after deleting the
VM.

Because the mount is read-only, the app's "manage / delete imported asset"
flows should be tested using the `.vm-bridge/` writable area instead — drop
test assets into `.vm-bridge/builds/test-assets/` (or any writable
sub-folder) and point the picker there.

### 6.4 Visual — GUI smoke (requires Screen Sharing)

Enable in guest: System Settings → General → Sharing → **Screen Sharing**.
From host:
```bash
open vnc://lw-vm-14
```

Smoke list (run each, watch for UI glitches):

| # | Action                                 | Expected                                                  |
|---|----------------------------------------|-----------------------------------------------------------|
| 1 | Launch                                 | Main window opens, no crash dialog                        |
| 2 | Open Settings                          | Glass surfaces show tinted material fallback, no flicker  |
| 3 | Toggle a SymbolEffect-decorated button | `.pulse` instead of `.rotate` / `.bounce` on macOS 14     |
| 4 | Drop a video → set as wallpaper        | Plays on desktop, no AV pipeline error                    |
| 5 | Apply a CIFilter to that video         | `applyingCIFiltersWithHandler` path (not `applier`)       |
| 6 | Workshop screen, scroll capsule chips  | Capsule chips render with stroke fallback                 |
| 7 | Quit + relaunch                        | Persisted config restored intact                          |

Record results in `docs/qa/runtime-reports/macos14-YYYYMMDD.md` (template at
the end of this doc).

---

## 7. Tool reference

### Useful one-liners

```bash
# === Connectivity ===
ssh lw-vm-14 'sw_vers; uname -m'                     # confirm 14.x ARM
ping -c 2 lw-vm-14                                   # IP reachability

# === Bridge ===
ls -la .vm-bridge/builds/                            # host view
ssh lw-vm-14 'ls -la /Users/dev/Desktop/VirtualBuddyShared/.vm-bridge/'

# === Process ===
ssh lw-vm-14 'pgrep -l LiveWallpaper'
ssh lw-vm-14 'ps -o pid,etime,pcpu,pmem,rss -p $(pgrep LiveWallpaper)'

# === Logs ===
ssh lw-vm-14 'log stream --process LiveWallpaper --level debug --info'
ssh lw-vm-14 'log show --process LiveWallpaper --last 5m'

# === Crashes ===
ssh lw-vm-14 'ls -lt ~/Library/Logs/DiagnosticReports/LiveWallpaper-*.ips 2>/dev/null | head'

# === Stack samples ===
ssh lw-vm-14 'sample $(pgrep LiveWallpaper) 5 -file /tmp/sample.txt; cat /tmp/sample.txt' \
  > .vm-bridge/samples/$(date +%H%M%S).txt
ssh lw-vm-14 'spindump $(pgrep LiveWallpaper) 5 -file /tmp/spindump.txt; cat /tmp/spindump.txt' \
  > .vm-bridge/samples/spindump-$(date +%H%M%S).txt

# === Symbols ===
nm     .vm-bridge/builds/LiveWallpaper.app/Contents/MacOS/LiveWallpaper.debug.dylib | grep AdaptiveGlass
otool -L .vm-bridge/builds/LiveWallpaper.app/Contents/MacOS/LiveWallpaper.debug.dylib | grep SwiftUI

# === Demangle a symbol ===
echo '_$s13LiveWallpaper...' | xargs xcrun swift-demangle
```

### Remote LLDB (for breakpoint-level debugging)

```bash
# 1. Copy debugserver from host's Xcode into the bridge (one-time)
cp /Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Resources/debugserver \
   .vm-bridge/builds/

# 2. Re-sign in guest with debugger entitlement (one-time)
ssh lw-vm-14 'cat > /tmp/dbg.entitlements <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.debugger</key><true/>
</dict></plist>
XML
codesign --force --sign - --entitlements /tmp/dbg.entitlements \
  /Users/dev/Desktop/VirtualBuddyShared/.vm-bridge/builds/debugserver'

# 3. Per-session: start debugserver in guest, attach lldb from host
ssh lw-vm-14 '/Users/dev/Desktop/VirtualBuddyShared/.vm-bridge/builds/debugserver \
              *:9999 --attach=$(pgrep LiveWallpaper)' &
lldb -o "process connect connect://lw-vm-14:9999"
```

---

## 8. Troubleshooting matrix

| Symptom                                                | Diagnosis                            | Fix                                                                                                |
|--------------------------------------------------------|--------------------------------------|----------------------------------------------------------------------------------------------------|
| `ssh: connect to host ... port 22: No route to host`   | sshd died / network race after boot  | Wait 5 s, retry. If persistent, `ssh lw-vm-14 'sudo launchctl kickstart -k system/com.openssh.sshd'` after recovery |
| `ssh ... port 22: Connection refused`                  | Remote Login disabled in guest       | Guest System Settings → Sharing → **Remote Login** ✅                                              |
| IP changed after reboot                                | DHCP reassignment                    | VirtualBuddy → VM → Edit → Network → set **DHCP Reservation**, or update `~/.ssh/config`           |
| Build appears in `build/...` but is < 5 MB             | SwiftUI preview stub                 | Use the latest `~/Library/Developer/Xcode/DerivedData/LiveWallpaper-*/Build/Products/Debug/` build |
| `open` succeeds but app vanishes immediately           | Gatekeeper quarantine on VirtioFS    | `ssh lw-vm-14 'xattr -dr com.apple.quarantine ...path/to/LiveWallpaper.app'`                       |
| Guest doesn't see new file on bridge                   | VirtualBuddyGuest not running        | Guest: `open /Applications/VirtualBuddyGuest.app`                                                  |
| `mount_virtiofs: No such file or directory`            | Guest is macOS < 13                  | Upgrade guest; macOS 12 lacks VirtioFS support                                                     |
| `nm` / `otool` not found in guest                      | Command Line Tools missing           | `ssh lw-vm-14 'xcode-select --install'`                                                            |
| `.ips` not appearing in `.vm-bridge/crashes/`          | crash-bridge launchd agent unloaded  | `ssh lw-vm-14 'launchctl load ~/Library/LaunchAgents/io.taijial.livewallpaper.crash-bridge.plist'` |
| Symbolicated stack shows raw addresses                 | `.debug.dylib` path mismatch         | atos `-o` must point at the **`.debug.dylib`**, not the thin `LiveWallpaper` shim                  |
| Clipboard between host ↔ guest doesn't sync            | VirtualBuddyGuest not in menu bar    | Re-open `/Applications/VirtualBuddyGuest.app` (also see [Discussion #607](https://github.com/insidegui/VirtualBuddy/discussions/607) for macOS-26 guest only) |
| `xcodebuild test` on guest takes forever               | Compilation in VM is slow            | Don't compile in VM. Build on host, ship `.app` via bridge                                         |
| `Live Wallpapers/` folder missing in guest             | Second shared folder not configured  | VM off → Edit VM → Sharing → add `~/Documents/Live Wallpapers` (Read only). See §3.4                |
| "Operation not permitted" when saving inside `Live Wallpapers/` | Mount is intentionally read-only | Use `.vm-bridge/` for writable test assets, or change permission in VirtualBuddy (not recommended) |
| Symlink inside `.vm-bridge/` pointing outside doesn't resolve in guest | VirtioFS does not translate cross-boundary absolute paths | Add the target as a separate shared folder in VirtualBuddy instead — see §3.4   |

---

## 9. Extending to macOS 15 / macOS 26 VMs

Repeat §3 with these substitutions:

| Token        | macOS 15                                        | macOS 26                                        |
|--------------|------------------------------------------------|------------------------------------------------|
| SSH alias    | `lw-vm-15`                                      | `lw-vm-26`                                      |
| IP           | (assign during config)                          | (assign during config)                          |
| Restore img  | macOS 15.x IPSW from VirtualBuddy catalog       | macOS 26.x IPSW from VirtualBuddy catalog       |
| Bridge path  | same `.vm-bridge/` on host; guest path may vary | same `.vm-bridge/` on host; guest path may vary |
| Test focus   | `.rotate`/`.bounce` native paths engage         | Native Liquid Glass renders; perf parity smoke  |

**Constraint**: Apple Silicon hosts can only virtualise Apple Silicon macOS
guests. The minimum guest is **macOS 12**; the project's compatibility floor is
14. The host can run at most **2 concurrent macOS VMs** ([Apple Virtualization
limit](https://khronokernel.com/macos/2023/08/08/AS-VM.html)).

Add new env rows to `docs/qa/release-qa-matrix.md` (currently ENV-09 covers
macOS 14, ENV-10 covers 15, ENV-11 covers 26).

---

## 10. Known gaps

- **No `os.Logger` instrumentation in app code** — `log stream
  --process LiveWallpaper` is mostly empty. Adding a centralised `AppLog`
  (subsystem = bundle id, per-domain categories: `Persistence`, `Playback`,
  `Effects`, `Glass`, `Session`) would let runtime fallback decisions surface
  directly. Tracked as a follow-up.
- **No multi-monitor VM config** — VirtualBuddy default is 1 virtual display;
  edit the VM to add a second display before testing multi-screen wallpaper
  paths.
- **No real-hardware verification on macOS 14 / 15 / 26** — VM covers
  functional regression; GPU performance and "set as desktop wallpaper"
  window-server compositing still require physical hardware for sign-off (see
  `docs/qa/rc-signoff-template.md`).

---

## 11. Runtime-report template

Save under `docs/qa/runtime-reports/macosNN-YYYYMMDD.md` after each VM smoke
run.

```markdown
# macOS NN Runtime Smoke — YYYY-MM-DD

- Build: <commit sha or branch + date>
- Guest: macOS NN.N.N ARM (VirtualBuddy)
- Host: macOS NN.N (Apple Silicon)
- Operator: <name>

## Static gates
- MacOSCompatibilityPolicyTests: ✅ / ❌
- AdaptiveGlass symbols present in dylib: ✅ / ❌
- `applyingCIFiltersWithHandler` path linked: ✅ / ❌

## Runtime smoke
| # | Action | Result | Notes |
|---|---|---|---|
| 1 | App launch | ✅/❌ | |
| 2 | Liquid Glass fallback | ✅/❌ | |
| 3 | SymbolEffect fallback (.rotate→.pulse) | ✅/❌ | |
| 4 | SymbolEffect fallback (.bounce→.pulse) | ✅/❌ | |
| 5 | Video wallpaper + CIFilter | ✅/❌ | |
| 6 | Multi-screen layout | ✅/❌ / N/A | |
| 7 | Persistence round-trip | ✅/❌ | |
| 8 | Clean shutdown | ✅/❌ | |

## Crashes
(paste key stack frames from `.ips`, or "none")

## Log highlights
(paste relevant `log show` excerpts, or "none / project lacks Logger")

## Follow-ups
- ...
```

---

## 12. Maintenance

Update this doc when:
- A new VM (15 / 26 / future) is added to the matrix.
- The bridge path schema changes.
- `MacOSCompatibilityPolicyTests` adds new needles or rules.
- A new debugging entry-point becomes standard (e.g. `os.Logger` rollout).

Cross-references:
- `CLAUDE.md` §9 (Adaptive Liquid Glass convention)
- `docs/qa/release-qa-matrix.md` (ENV-09 / ENV-10 / ENV-11)
- `docs/qa/rc-signoff-template.md`
- `LiveWallpaperTests/MacOSCompatibilityPolicyTests.swift`
- `Packages/LiveWallpaperSharedUI/Sources/LiveWallpaperSharedUI/Components/AdaptiveGlass.swift`
- `Packages/LiveWallpaperSharedUI/Sources/LiveWallpaperSharedUI/Components/SymbolEffectOptions+Compatibility.swift`
