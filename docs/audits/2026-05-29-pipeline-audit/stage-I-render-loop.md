# Stage I — Render Loop / Per-Frame Dispatch / Output

(Behavioral correctness, not doc-conformance.)

## Checklist (abridged)

| behavior | impl (file:line) | verdict | note |
|---|---|---|---|
| Order: clear → layers → effects → particles → text → present | WPEMetalSceneRenderer:758-898; WPEMetalRenderExecutor:143-205 | ✅ | particles(784), text(795), present(1263) |
| Layer z/parallax composite order | render loop :143-186 (array order); builder :44-86 | ⚠️ | no explicit z/depth sort (Issue 1) |
| Within-layer pass order (material→effects) | :175-185 | ✅ | ping-pong :512-534 |
| Command buffer ordering/encoding | :121-192 single buffer | ✅ | particles/text separate buffers, loadAction=.load |
| Per-frame output-texture alloc | makeOutputTexture:982-997, called :120 | ➖ PERF | fresh .shared RT/frame (Issue 4) |
| waitUntilCompleted ×3 | :193,268,327 | ➖ PERF | needed for snapshot; perf (Issue 4) |
| Depth attach only when needed + compare-fn | DepthStateCache:23-27,82-103; :536-550 | ✅ | keyed on (target,W,H) |
| Blend modes 2D | :1469-1500; particle :393-409; text :348-354 | ✅ | |
| Pause/occlusion stops GPU | applyPerformanceProfile(.suspended) :1211-1216; SceneWallpaperSession :97/102/237 | ✅ | isPaused, releaseDrawables |
| **Pause stops time** | FrameClock :99 `CACurrentMediaTime−loadTime` | ❌ | wall-clock → g_Time keeps advancing → jump on resume (Issue 2) |
| Throttle (non-exclusive) → 1fps | setThrottled :1151-1155 | ✅ | |
| Snapshot/first-frame readback | performLoad :411-420; .shared+wait | ✅ | |
| **Image-layer visibility honored** | particle :1015, text :798 gate on .visible | ⚠️ | image layers NOT gated (Issue 3) |
| Layer alpha/brightness | genericImageUniforms :1191-1200 | ✅ | |
| Layer blendmode | per-pass pass.pass.blending | ✅ | |
| Static vs continuous | needsContinuousFrames :1199-1201; draw(in:) :1250-1268 | ✅ | static re-presents cached output |
| present clear+copy | :416-473 | ✅ | opaque-black clear, no needless wait |

## Issues

### Correctness
- **Issue 2 (Major) — time doesn't pause while suspended/occluded.** `FrameClock.runtimeUniforms` = `CACurrentMediaTime()−loadTime` (`WPEMetalRuntimeUniforms:99`), loadTime fixed. Occluded → `.suspended` (no frames) but wall clock runs → first resumed frame jumps `g_Time` by the hidden duration; time-driven shaders snap, `tick(now:)` integrates a huge dt (particles burst). Fix: subtract paused intervals or use an accumulated-delta clock advanced only on rendered frames.
- **Issue 1 (Major, verify) — layer composite order unsorted.** Executor composites `preparedPipeline.layers` in array order (`:143`); builder appends in document order (`:44-86`), no z/parallax-depth sort. If document JSON isn't authored strictly back-to-front (or builder reorders for FBO deps), layers composite wrong. Highest-risk behavioral gap for "renders normally". Confirm a sort by WPE depth exists before marking ✅.
- **Issue 3 (Minor) — image-layer visibility not gated.** Particle/text gate on `object.visible`; image layers always encoded (`:143` no check). Hidden image objects still draw (unless builder drops them).

### Perf (not correctness — confirms prior review)
- **Issue 4 (Major perf only) — per-frame output alloc + triple waitUntilCompleted.** New `.shared` output/frame (no pool) + 3 blocking waits (:193,268,327). Frame state/time still advance correctly. Steady-state `draw(in:)` could drop the render-side wait (only load-time snapshot needs it) and pool/double-buffer the output.
- **Issue 5 (Minor perf) — dispatcher instantiated per pass** (`:575`); trivial struct, hoist out of loop.

**Correct despite looking suspect:** single shared command buffer with ping-pong guards (`passReadsCurrentTarget:1216`, copy-on-first-write :524-534, `_rt_*` snapshot :722); `previousFrameHistory` cross-frame feedback gated on matching scene size; snapshot readback reliable (.shared + wait).

**Act on for "renders normally":** Issue 1 (layer order) + Issue 2 (paused-time). Alloc/wait are perf.
