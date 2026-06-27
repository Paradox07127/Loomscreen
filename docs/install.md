# Install, update & troubleshoot

## Install

1. Download the latest `Loomscreen-x.y.z.dmg` from
   [Releases](https://github.com/Paradox07127/Loomscreen/releases/latest).
2. Open the DMG and drag **Loomscreen.app** into `/Applications`.
3. Clear the Gatekeeper quarantine **once** in Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Loomscreen.app
   ```
4. Launch Loomscreen — its icon appears in the menu bar.

### Why the `xattr` step?

Loomscreen has no paid Apple Developer ID yet, so the build is **ad-hoc signed**.
macOS Gatekeeper quarantines ad-hoc-signed apps on first launch; the one-time
`xattr -dr com.apple.quarantine` clears that flag. After it, the app launches like
any other. (The DMG's `READ ME — first launch.txt` repeats this.)

You can verify a download against the published `.dmg.sha256`:

```bash
shasum -a 256 -c Loomscreen-x.y.z.dmg.sha256
```

## Updates

Loomscreen checks the GitHub Releases API **once per launch**, throttled to 12 hours —
no background polling, no telemetry. When a newer version exists you'll see a banner;
open the Releases page to download it. You can also:

- **Settings → About → Check Now** — check on demand.
- **Skip this version** — silence a specific release.

Updating is a manual download-and-replace (drag the new `Loomscreen.app` into
`/Applications`, repeat the `xattr` step).

## Troubleshooting

**"Loomscreen.app is damaged / can't be opened."**
The quarantine flag is still set. Run the `xattr -dr com.apple.quarantine` command
above. (Gatekeeper shows this for ad-hoc-signed apps, not actual damage.)

**Nothing renders / black wallpaper.**
Confirm you're on an Apple Silicon Mac running macOS 14+ — Intel is not supported.

**A wallpaper won't import (Pro).**
Projects that require Windows executables or `.dll` plugins are skipped on macOS.

**It keeps pausing.**
That's intended — Loomscreen suspends rendering while a full-screen game or app is
frontmost, and resumes when you leave it.

Still stuck? Open an [issue](https://github.com/Paradox07127/Loomscreen/issues) with
your macOS version and Mac model.
