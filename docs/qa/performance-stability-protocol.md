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

