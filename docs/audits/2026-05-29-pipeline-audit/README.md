# WPE Metal pipeline audit — per-subagent finding records (2026-05-29)

Raw findings from each subagent in the multi-agent documentation-conformance audit. Synthesized + prioritized in the parent doc: [`../2026-05-29-wpe-metal-pipeline-conformance.md`](../2026-05-29-wpe-metal-pipeline-conformance.md).

| Record | Stage | Agent |
|--------|-------|-------|
| [stage-A-decode.md](stage-A-decode.md) | Texture/package/model decode (.tex/.pkg/.mdl) | Claude (aca750a0) |
| [stage-B-scene-parse.md](stage-B-scene-parse.md) | scene.json → model | Claude (adc64490) |
| [stage-C-coordinates.md](stage-C-coordinates.md) | Coordinate system / transforms / parallax | Claude (a3fc9d6f) |
| [stage-D-render-graph.md](stage-D-render-graph.md) | Render graph / compositing / FBO / blend | Claude (a494df23) |
| [stage-E-materials.md](stage-E-materials.md) | Materials / combos / pipeline | Claude (a6267a10) |
| [stage-F-shader-transpile.md](stage-F-shader-transpile.md) | GLSL→MSL transpile | Claude (a87f1b20) |
| [stage-G-particles.md](stage-G-particles.md) | Particle system | Claude (a95dbce0) |
| [stage-H-runtime-uniforms.md](stage-H-runtime-uniforms.md) | Time / audio / pointer / engine constants | Claude (aed340f8) |
| [stage-I-render-loop.md](stage-I-render-loop.md) | Per-frame dispatch / output | Claude (ab17c450) |
| [codex-cross-check.md](codex-cross-check.md) | Backend-authority cross-check (decode/coords/shader) | codex (019e7251) |
| [coordinate-ground-truth.md](coordinate-ground-truth.md) | WPE(D3D)↔Metal↔GL convention ground truth | Claude (abd0cf6e) |

Method: each stage agent had web access (official WPE docs + community refs) + repo read + static inspection of the real corpus at `~/Documents/Live Wallpapers/431960`. Report-first — no code changed.
