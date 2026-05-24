# WPEWebGLRuntime

TypeScript + Vite source for the WebGL2 runtime hosted in `WKWebView` for
LiveWallpaper's WPE scene playback. Built bundle is placed under
`../LiveWallpaper/Resources/wpe-webgl-runtime.bundle/` — picked up
automatically by Xcode 16's file-system synchronized root group.

See [`docs/engineering/wpe-webgl-runtime.md`](../docs/engineering/wpe-webgl-runtime.md)
for the bridge contract, scheme handlers, and CSP details.

## Workflow

```bash
npm install
npm run build       # → ../LiveWallpaper/Resources/wpe-webgl-runtime.bundle/
npm run dev         # local Vite dev server at http://127.0.0.1:5173
npm run typecheck
```

Dev/debug build with inline source maps + non-minified output (for
Safari Web Inspector step-through):

```bash
WPE_DEV_BUILD=1 npm run build
```

Build output:

```
../LiveWallpaper/Resources/wpe-webgl-runtime.bundle/
├── index.html
└── assets/
    ├── main.js
    └── …chunks
```

## Layout

```
src/
├── main.ts                  # entry — boots canvas, installs window.__wpeHost
├── bridge/HostBridge.ts     # Swift ↔ JS message contract (mirrors Swift types)
└── core/WebGLContext.ts     # WebGL2 context creation + dpr resize helpers
```

Phase 3+ will add `core/RenderGraphExecutor.ts`,
`resources/ShaderCompiler.ts`, `resources/TextureManager.ts`,
`resources/FramebufferPool.ts`, `systems/ParticleSystem.ts`,
`systems/TextRenderer.ts`, `systems/AudioRouter.ts`,
`script/SceneScriptHost.ts`.

## Toolchain notes

- TypeScript 5.4+, Vite 5.2+, Node 20+.
- ES2022 target — WKWebView on macOS 14+ supports it natively.
- `modulePreload: false` keeps the script tag layout simple under the
  custom URL scheme.
- `minify: "esbuild"`, no source maps in build output (turn on locally
  in `vite.config.ts` if debugging).
