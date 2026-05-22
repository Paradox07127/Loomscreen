# HTML Wallpaper Audio: Ogg/Vorbis/Opus Decoder Limitation

**Status**: Known limitation, **not currently fixed**. Re-evaluate when complaint volume justifies the engineering investment.
**Last updated**: 2026-05-22
**Scope**: HTML-mode wallpapers that reference `.ogg` / `.oga` / `.opus` audio assets.

---

## Symptom

Wallpaper Engine and other web wallpaper packages frequently ship `.ogg` (Vorbis-encoded) or `.opus` audio files. In our app these can:

1. Refuse to play entirely
2. Play the first 1–5 seconds then go silent
3. Hang the WKWebView audio pipeline if the file is >1 MB
4. Trigger `Error 153` style "media engine stall" symptoms

User-visible result: a wallpaper that's supposed to have ambient audio is silent, possibly along with a paused-looking status indicator.

---

## Root cause

**Apple's system Ogg/Vorbis decoder in AVFoundation is fundamentally broken** for many real-world files. This is not a WKWebView bug — we reproduced the same failures in **macOS 26 Tahoe's QuickTime Player** (which uses AVFoundation directly). Specifically:

- Granulepos jumps in the Vorbis bitstream trip an infinite seek loop inside the system demuxer
- Multi-stream chained Ogg bitstreams produce silence with no error
- Opus support was added in Safari 17 / macOS 14 but Ogg-wrapped Opus only stabilized in Safari 18.4 / **macOS 15.4 (March 2025)**; pre-15.4 systems have no Ogg/Opus decoder at all
- File size > ~1 MB exacerbates the demuxer pathological-case behavior

Because the brokenness is at the AVFoundation layer, **every Apple-framework path inherits it**:

| API | Behavior on broken Ogg |
|---|---|
| `AVPlayer` / `<audio>` element | stall / silent |
| `AVAssetExportSession` (offline transcode) | same decoder → same failure |
| `AVAssetReader` + `AVAssetWriter` | same |
| `AVAudioEngine` / `AudioToolbox AudioFile*` | doesn't even open `.ogg` container (no `kAudioFileOggType` exists) |
| WebKit `decodeAudioData` / WebCodecs `AudioDecoder` | IPC to GPU process which calls the same AVFoundation decoder |

Chrome and Firefox work because they bundle their own `ffmpeg` and bypass the system decoder entirely.

---

## What we shipped

- **Sibling-file fallback** in `FolderURLSchemeHandler.oggFallbackURL`: when a request for `X.ogg` comes in and a `X.mp3` / `X.m4a` / `X.aac` / `X.wav` / `X.flac` sibling exists in the same directory, we serve that instead with the correct MIME. Wallpaper Engine authors often ship multiple formats, so this covers a fair slice of cases.
- **404 diagnostic logging** in `FolderURLSchemeHandler.logMissingResource`: when a file truly is missing, we log the resolved path, parent directory listing, and a hint about Ogg-codec limitations so users can self-diagnose.

These two together handle **maybe 70–80% of WPE wallpapers** in practice. The remaining 20–30% — packages that ship *only* `.ogg` — silently fail.

---

## What we evaluated and rejected

### Tier 2: Native `AVAssetExportSession` transcode (rejected)

Original plan was to detect orphan `.ogg`, transcode to `.m4a` offline, cache the result, serve cached file on subsequent requests. **Rejected** after confirming QuickTime Player itself fails on these files — the export session uses the same broken decoder, so success rate would be ~0% on the very files we need to fix. Investment of ~7 hours engineering for 0% payoff.

### Bundling `libvorbis` + `libopusfile` natively (rejected for now)

- ~500 KB total binary increase
- LGPL — requires dynamic linking + ship `LICENSE.txt`
- Mac App Store shippable with proper handling
- ~3–5 days work (build, sign, integrate, test, ship)
- **The only path that guarantees correctness**

Rejected for now because the user's stated principle is "no third-party dependencies." Revisit if complaint volume justifies the work.

### Bundling FFmpeg-mini (rejected)

- 10–20 MB binary increase
- Same LGPL/GPL handling
- Overkill — we only need two codecs

### JS polyfill that URL-rewrites `.ogg` → `.mp3` (rejected)

Antigravity suggested injecting JS to monkey-patch `<audio>.src` / `fetch` / `XHR` so the wallpaper page would request `.mp3` instead of `.ogg`. This is functionally equivalent to our existing scheme-handler sibling-fallback (which works at HTTP layer, catches all paths including Service Workers / Web Workers / WASM internal fetches). JS polyfill is strictly weaker. No reason to add it.

### Calling user-installed `ffmpeg` via `Process` (rejected)

App Sandbox blocks `Process.run()` by default. Adding the exception entitlement is possible but breaks "just works" UX (users have to install ffmpeg, locate it, grant access). Probably an unjustified amount of work and complexity for a niche feature.

---

## The "if we revisit" path: WASM decoder injection

This is the cheapest path that **actually fixes the problem**. Documented here so future-us doesn't have to re-research.

### Approach

Ship a small WebAssembly Vorbis/Opus decoder inside the app bundle. Inject JS into the wallpaper WKWebView at `documentStart`:

1. Hook `HTMLMediaElement.src` setter, `<source>` element insertion, `fetch`, `XMLHttpRequest.open`
2. Detect `.ogg` / `.oga` / `.opus` URLs
3. Fetch the bytes, run the WASM decoder, get PCM samples
4. Build an `AudioBufferSourceNode` and play via Web Audio API
5. **Completely bypass AVFoundation** — same trick Chrome uses

### Recommended library

`@wasm-audio-decoders/ogg-vorbis` + `@wasm-audio-decoders/opus` — **MIT licensed** (no LGPL), **~120 KB gzipped combined**. Or `ogv.js` for one combined drop-in (~300 KB, covers Theora video too if we ever want that).

### Why MIT WASM is not "a third-party dependency" in the sense the user objected to

- Not linked into the binary at any layer
- Runs in WebKit's JS/WASM sandbox, not in our process
- No LGPL compliance network (no dylib redistribution rules)
- App Store treats WASM as "interpreted code" — same category as JavaScript

### Engineering cost estimate

~10 hours (~1.5 days):
- 1h pick library, ship pre-compiled WASM into `Resources/wasm-decoders/`
- 2h extend `HTMLWallpaperRuntimeScript.masterAudioController` with `__lwOggInterceptor__` JS segment
- 3h JS interceptor logic (Blob URL substitution, AudioBufferSourceNode plumbing)
- 2h test against real broken WPE wallpapers
- 1h performance verification (WASM decode real-time vs. CPU)
- 1h xcstrings + build gate

### Trigger to do this work

- User reports OGG-only wallpaper failures with notable frequency, OR
- Wallpaper Engine ecosystem moves toward OGG-only packaging, OR
- We add a "wallpaper compatibility score" indicator and want to honestly report >95% rather than ~75%

---

## File pointers

- Sibling fallback: `LiveWallpaper/VideoPlayback/FolderURLSchemeHandler.swift` → `oggFallbackURL(for:)` + the call site in `webView(_:start:)`
- 404 diagnostic: same file → `logMissingResource(fileURL:requestURL:)`
- Where the WASM interceptor would live if/when we build it: `LiveWallpaper/VideoPlayback/HTMLWallpaperView.swift` → `HTMLWallpaperRuntimeScript.masterAudioController` (extend with a new injected JS segment alongside the existing audio-mute/volume controller)

---

## Reproducer files

User-reported failures, useful as regression set if/when we revisit:

- `/Users/dev/Documents/Live Wallpapers/431960/3532325762/assets/audio/Theme_298.ogg` — plays first 5 seconds then silent in QuickTime, WKWebView, our app
- `/Users/dev/Documents/Live Wallpapers/431960/3112362931/audio/1.ogg` — referenced by HTML but only `1.mp3` shipped in folder (sibling fallback handles this; not an Ogg decoder issue)
- Files >1 MB in the same series — hang AVFoundation entirely
