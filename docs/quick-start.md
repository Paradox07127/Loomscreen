# Quick Start

> For the full feature matrix, go to [features.md](features.md).

## 1) Install and first launch

1. Download the latest `.dmg` from [Releases](https://github.com/Paradox07127/Loomscreen/releases/latest).
2. Drag `Loomscreen.app` into `/Applications`.
3. Run once:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Loomscreen.app
   ```
4. Launch from `/Applications`.

On first launch, the onboarding flow opens. Choose one source to apply to all detected displays:

- `Import a File` → video/web/scene (Pro only for scene)
- `Apple Aerials` (local aerial catalog)
- `Steam Workshop` (Pro direct distribution only)

If you skip onboarding, you can continue from the Settings window and set up displays manually.

## 2) Open the app surfaces

- **Menu bar icon** (main quick control): open to quickly pause/play, add wallpaper, and jump to settings.
- **Menu → Manage**: opens the Settings window.
- **Settings → Displays**: per-screen source + settings.
- **Settings → About**: version/build/issue reporting area.

## 3) Configure one screen end-to-end

1. Open **Settings → Displays**.
2. Pick a target display from the left list.
3. In the detail panel, choose the wallpaper type:
   - Video
   - Web
   - Shader (Pro)
   - Wallpaper Engine Scene (Pro)
4. In the preview/source area, choose local file/folder or project.
5. Tune playback/effects in the right inspector panel.
6. Save by closing the panel (state is persisted as you interact).

### Helpful defaults

- Start with one active wallpaper + a small playlist length until performance is stable.
- Keep one source path per display to avoid repeated file permission prompts.
- Enable pause rules if you are on battery, in games, or frequently switch full-screen apps.

## 4) Playlists and rotation

Go to the display detail **Playlist** section:

- Add/remove entries.
- Set play interval (minutes) for auto-rotation.
- Shuffle on/off.
- Apply to current display or all screens.

Tip: Use `Schedule` for strict windows and playlist for continuous motion.

## 5) Time scheduling

In **Schedule**:

1. Add a time slot.
2. Pick a bookmark from current gallery.
3. Set start/end time and repeat/weekday settings (where available).
4. Loomscreen resolves conflicts automatically and highlights overlaps.

If no slot matches, the screen returns to its default primary wallpaper.

## 6) Global controls and shortcuts

- Master toggle in menu bar: enable/disable rendering across all displays.
- Per-display controls in the menu bar rows: prev/next/play-pause when supported.
- **Settings → Shortcuts**:
  - Play / Pause all
  - Next / Previous (active display)
  - Toggle mute
  - Toggle mouse interaction
  - Show / hide all wallpapers
  - Reload all wallpapers

## 7) Import/export and backup

- Export: save a `.lwconfig` bundle from Settings and keep it for migration.
- Import: restore display/layout behavior on another Mac.
- Bookmarks are included as references where possible; verify source availability after import.

## 8) Workshop path (Pro/direct distribution)

Use **Settings → Workshop**:

- Browse scenes and paste/download links.
- Install local scene folders into the library.
- Open and preview scenes.

Workshop access is runtime-gated and depends on distribution settings.

## 9) After first day

- Tune performance (RAM budget, frame cap, pause rules).
- Add `Application` exceptions for apps that should keep wallpaper running.
- Build a small bookmark set for quick swaps from the menu bar.
- Report edge cases with diagnostics from **About → Report a Bug…**.
