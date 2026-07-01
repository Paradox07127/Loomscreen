# Screenshots and release assets

## Required assets

Place real screenshots under `docs/images/` with these names:

- `main.png`
- `video.png`
- `web.png`
- `scene.png`
- `workshop.png`

Current default set:

- `main.png` — app main surface (menu bar + settings entry).
- `video.png` — video workflow setup and controls.
- `web.png` — web workflow setup and controls.
- `scene.png` — scene/shader workflow (Pro).
- `workshop.png` — workshop browse/import flow (Pro).

Optional assets (add when available):

- `settings-shortcuts.png`
- `settings-about.png`
- `settings-displays.png`
- `screen-detail.png`
- `livewallpaper-logo.png`
- `loomscreen-logo.png`

## Scene mapping

- `main.png`: menu / launch / primary settings entry.
- `video.png`: local video import, playback controls, playlist, and scheduling preview.
- `web.png`: web source assignment and web runtime inspector.
- `scene.png`: shader / Wallpaper Engine scene configuration (Pro).
- `workshop.png`: Workshop browser/import/install path (Pro).

## Capture checklist

1. Use a clean app state and consistent monitor layout.
2. Capture each scene with high-contrast settings.
3. Export as PNG under `docs/images/`.
4. Keep names exactly as listed above.
5. Commit `docs/images/*.png` alongside docs references.

## Note

If your CI/build environment cannot capture screenshots, use a local GUI session to generate these files and then commit them as-is.
