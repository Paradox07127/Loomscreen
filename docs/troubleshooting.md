# Troubleshooting

## I. App won't open

- **Symptom**: “damaged / can't be opened”
  - Run quarantine clear once:
    ```bash
    xattr -dr com.apple.quarantine /Applications/Loomscreen.app
    ```
  - Re-open from `/Applications`.
- **Symptom**: menu bar icon not appearing
  - Make sure the app is actually running in Activity Monitor.
  - Launch and choose **Manage** from the menu bar popover.
  - If still missing, restart and check macOS login items/permission restrictions.

## II. Visual issues

- **Symptom**: nothing renders or black screen
  - Verify macOS 14+ on Apple Silicon.
  - Confirm a source is assigned to that screen in **Settings → Displays**.
  - Toggle menu bar master switch off/on.
  - If pause policy is on for battery/full-screen/window occlusion, temporarily disable those rules and retest.
- **Symptom**: first screen is fine, second screen is blank
  - Re-open the target detail panel and re-assign the same source explicitly.
  - Check if the source belongs to another display and that permission bookmarks are valid.

## III. Playlist / schedule

- **Symptom**: schedule does not switch
  - Confirm the active slot has no overlaps.
  - Confirm target bookmark is still valid and accessible.
  - Confirm the app is not paused by full-screen/game policy at those times.
- **Symptom**: playlist interval not changing
  - Verify the display has playlist mode enabled and contains at least two valid items.
  - Reset the interval and re-save the display panel.

## IV. Web and media import

- **Symptom**: web source fails to load
  - For folders, check that an index file can be inferred.
  - Reimport with `Import a File` / directory flow from onboarding.
- **Symptom**: large video stutters
  - Lower frame cap and RAM cache budget in inspector.
  - Use smaller source dimensions where possible.
  - Disable extra effects and weather particle layers to isolate load.

## V. Workshop / scene import (Pro)

- **Symptom**: scene import fails immediately
  - Folder may not look like a Wallpaper Engine scene (needs expected structure).
  - Some Windows-only scene assets are intentionally unsupported.
- **Symptom**: Steam workshop download path fails
  - Re-run SteamCMD checks in workshop settings.
  - Confirm network and Steam login/tool state.

## VI. Performance and stability

- High GPU/CPU in menu bar strip:
  - Pause on battery or window occlusion temporarily.
  - Reduce frame rate.
  - Turn off cursor-reactive effects for affected scenes.
- Desktop input feels blocked:
  - Scene `click interaction` can capture mouse clicks.
  - Disable this option and reload.

## VII. Recovery workflow

1. Reboot app.
2. Toggle relevant policy rules in **General Settings**.
3. Export and reimport configuration after clearing invalid paths.
4. If still broken, open **About → Report a Bug…**
   - keep diagnostics text
   - attach local runtime log
   - include exact reproduction steps.
