# WPE WebGL Runtime — Bridge Contract & Dev Workflow

Migration from the SPIRV-Cross / Metal pipeline to a WebGL2 runtime hosted
in `WKWebView`. See [.claude/plan/wpe-webgl-migration.md](../../.claude/plan/wpe-webgl-migration.md)
for the full multi-phase migration plan. This file is the
**implementation reference** the Swift host + JS runtime must agree on.

## Why this exists

WPE's official mobile shader target is **GLSL ES 3.00**, which is exactly
what WebGL2 speaks. The SPIRV-Cross / glslang path translates GLSL to MSL,
and every workshop scene that uses helper-scope textures, helper uniforms
inside `#if`/`#define`, named-FBO chains, or multi-texture helpers is a
new MSL edge case. WebGL2 makes the translation step a no-op — GLSL goes
straight to ANGLE-on-Metal, which Apple maintains.

## Toggling at runtime

`WPEUseWebGLRuntime` (UserDefaults key) controls the renderer in DEBUG
builds. Release builds always use Metal until the cutover gate is met.

```bash
# Enable the WebGL pipeline (DEBUG builds only)
defaults write Taijia.LiveWallpaper WPEUseWebGLRuntime -bool YES
# Disable (or just remove the key)
defaults write Taijia.LiveWallpaper WPEUseWebGLRuntime -bool NO
# Or delete to fall back to default
defaults delete Taijia.LiveWallpaper WPEUseWebGLRuntime
```

Selection happens once per `AmbientWallpaperSessionBuilder.makeSceneSession`
call via `WPERuntimeSelection.current`. There is no per-scene override.

## Custom URL schemes

Two `WKURLSchemeHandler`s are registered on every WebGL scene's
`WKWebViewConfiguration`:

### `wpe-runtime://host/<path>`

Serves the embedded `wpe-webgl-runtime.bundle/` (the JS/HTML output of
the TypeScript runtime build). Read-only. Path containment enforced. No
nonce — the bundle is fixed at build time.

| Method | Path | Response |
|--------|------|----------|
| `GET`  | `/index.html` | The runtime entry HTML |
| `GET`  | `/assets/*.js` | Bundled runtime JavaScript |
| `GET`  | `/assets/*.css` | Bundled styles |

### `wpe-asset://scene/<nonce>/<relative-path>`

Serves per-scene assets (textures, models, audio, video, fonts) for the
currently-active scene. Every renderer instance generates a fresh
`nonce`; only requests carrying the active nonce are served. Stale URLs
retained by a previous scene cannot replay.

Phase 1: 404s every request (no `WPEAssetProvider` plugged in).
Phase 4: backed by `WPETexDecoder` + `WPEMultiRootResourceResolver` →
PNG/JPEG/RAW bytes + correct MIME type. Range support for video assets
in Phase 6.

## Swift ↔ JS message bridge

WebKit message handler name: **`wpe`**. JS dispatches via
`window.webkit.messageHandlers.wpe.postMessage({...})`.

Swift dispatches via `evaluateJavaScript("window.__wpeHost.<method>(...)")`.

### JS → Swift events

| `event` | Payload | When |
|---------|---------|------|
| `ready` | `{ scene_id? }` | Bundle finished loading + WebGL2 context created |
| `scene_loaded` | `{ scene_id? }` | `loadScene(envelope)` succeeded — Swift `load()` resolves here |
| `load_failed` | `{ stage, pass_id?, message }` | `loadScene(envelope)` failed — Swift `load()` throws here |
| `error` | `{ stage, pass_id?, message }` | Runtime error after load completed |
| `diagnostic` | `{ kind, message }` | Non-fatal info (asset miss, fallback applied) |
| `frame` | `{ frame_index, elapsed_ms }` | After each rendered frame (rate-limited; Phase 9+) |
| `readback` | `{ width, height, data_b64 }` | Response to a Swift-initiated framebuffer snapshot (Phase 9) |

The Swift host's `WPEWebGLBridge` decodes into `WPEWebGLIncomingMessage`
and dispatches to typed `onReady` / `onError` / etc. callbacks.

### Swift → JS methods

| Method | Argument | When |
|--------|----------|------|
| `loadScene(envelope)` | `WPEPipelineEnvelope` | Once per `load()` / `reload()` |
| `pushRuntimeState(state)` | `WPERuntimeStatePayload` | Each frame (coalesced) or on visibility change |
| `unloadCurrentScene()` | — | On reload / cleanup |

`WPEPipelineEnvelope` (see [`LiveWallpaper/Models/WPEPipelineEnvelope.swift`](../../LiveWallpaper/Models/WPEPipelineEnvelope.swift))
carries the scene ID, asset scheme binding (with nonce + URL prefix), and
in Phase 3 the serialized render graph IR.

## Visibility + lifecycle

The renderer maps Swift `WallpaperPerformanceProfile` cases to a string
`visibility` field inside the runtime state payload:

| Swift profile | JS `visibility` | JS runtime behavior |
|---------------|------------------|---------------------|
| `.quality` (default) | `active` | rAF running, full fps |
| `.suspended` | `background` | rAF paused, FBOs may be released |
| Externally throttled (display occluded) | `occluded` | rAF at 1 Hz |

Phase 10 will refine this with measured battery + GPU impact.

## CSP

The bundled `index.html` ships with a default-deny CSP:

```html
<meta http-equiv="Content-Security-Policy" content="
  default-src 'none';
  script-src 'self';
  connect-src wpe-asset:;
  img-src wpe-asset: blob: data:;
  media-src wpe-asset: blob:;
  style-src 'self' 'unsafe-inline';
  font-src wpe-asset: data:;
">
```

`data:` URIs are allowed for inline images (e.g. canvas snapshots
embedded as data URIs during scene-script callbacks) and inline fonts
(WPE scenes occasionally bundle base64-encoded font payloads). They are
**not** allowed for scripts, styles, or media — keeping the script /
style sources scheme-restricted closes the obvious XSS surface even if
a future scene tried to embed `data:text/javascript,...`.

`'self'` here resolves to `wpe-runtime://host`. Remote network access is
denied entirely.

## Phase rollout

See [.claude/plan/wpe-webgl-migration.md](../../.claude/plan/wpe-webgl-migration.md)
for the 12-phase plan and `wpe-webgl-migration-progress.md` for the
phase-by-phase execution journal.

| Phase | Status (as of Phase 0+1+2 landing) |
|------:|------------------------------------|
| 0 — Recovery tag + feature flag | Flag landed; tag deferred to Phase 12 prerequisite |
| 1 — Renderer shell + bridge contract | Landed |
| 2 — JS runtime scaffold | Landed (Vite + TS source + placeholder bundle) |
| 3 — ShaderCompiler + RenderGraphExecutor MVP | Pending |
| 4 — Asset pipeline (TEXB) | Pending |
| 5 — Multi-pass FBO chains + blend modes | Pending |
| 6 — Video textures via `<video>` | Pending |
| 7 — Particles / Text / Audio / SceneScript | Pending |
| 8 — Preflight + capability gates | Pending |
| 9 — Corpus harness adaptation + golden tests | Pending |
| 10 — Performance + memory pass | Pending |
| 11 — Cutover | Pending |
| 12 — Metal/SPIRV deletion | Pending |

## Dev workflow

The TypeScript runtime lives at `WPEWebGLRuntime/` (repo root).

```bash
# One-time
cd WPEWebGLRuntime
npm install

# Production build → LiveWallpaper/Resources/wpe-webgl-runtime.bundle/
npm run build

# Dev server with HMR (used in DEBUG; renderer reads WPE_RUNTIME_DEV_URL
# from environment, defaults to http://localhost:5173/)
npm run dev
```

The Vite config outputs to `../LiveWallpaper/Resources/wpe-webgl-runtime.bundle/`.
The output directory is a folder reference picked up by Xcode 16's file
system synchronized root group on the `LiveWallpaper` target.
