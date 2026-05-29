# Stage G — Particle System

## Checklist (abridged to ❌/⚠️ + key ✅)

| concept | impl (file:line) | verdict | note |
|---|---|---|---|
| Emitter rate/maxcount | Def:288/270; System:397-404,172 | ✅ | accumulator; cap 8192 |
| Emitter starttime/delay | Def:273; System:273-287 | ⚠️ | read as spawn delay; WPE = pre-simulation (D1) |
| Emitter distancemin/max | Def:290-291; :226-265 | ✅ | radius sampled |
| Emitter directions (axis) | Def:292-294; :233-264 | ⚠️ | binary axis enable; WPE = scalar magnitudes (D5) |
| Emitter sphere/box/layer shape | :258-264 | ⚠️/➖ | sphere only; box/layer not distinguished |
| Init lifetime/size/velocity/color/alpha/rotation/angularvelocity/turbulentvelocity randoms | :324-376 | ✅ | velocity Y-flip correct |
| Init exponent bias | — | ❌ | all flat uniform; WPE exposes exponent skew (D4) |
| Op movement (gravity/drag) | :396-398,374-375 | ✅ | gravity Y-flip + euler |
| Op angularmovement | :399-403,392-394 | ✅ | Z-only |
| Op alphafade | :393-395,412-426 | ✅ | lifetime-fraction |
| Op turbulence | :404-416,498-502 | ⚠️ | home-grown sine noise, not WPE field (D6) |
| **Op sizechange** | — | ❌ | not implemented (essential) (D2) |
| **Op colorchange** | — | ❌ | not implemented (essential) (D2) |
| Op alphachange / oscillate* | — | ❌ | not implemented (D3) |
| Op controlpoint/vortex/boids/capvelocity/collision | — | ➖ | advanced, not impl |
| Control points / worldspace | — | ➖ | not impl; particles object-relative baked at spawn |
| Spritesheet cols/rows/sequence + frame blend | SpriteSheet:54-78; :300-329,417-445 | ✅ | lifetime-relative |
| Spritesheet randomframe / no-blend flag | — | ➖ | mode not parsed; always sequence+blend |
| Spritesheet sequencemultiplier | :274,310 | ⚠️ | `×2` magic fudge (D7); baseFrameRate parsed but unused |
| Coord space → NDC projection | +Uniforms:308; shader:408-415 | ✅ | centered px / half-extent |
| Size mapping px→NDC | shader:414-415 | ✅ | size*2/sceneSize |
| Blend translucent/additive | executor:399-408 | ✅ | straight-alpha |
| **Blend normal** | executor:394-398 | ❌ | src=one,dst=zero opaque overwrite → black boxes (D8) |

## Deviations

- **D1 (Major) — `starttime` semantics inverted.** Code treats it as spawn delay (`Def:273`→startDelay; gate `System:397`). WPE = **pre-simulate** at creation to avoid empty screen (the opposite). `prewarm()` exists but isn't driven by starttime. Fix: feed starttime into `prewarm(simulatedSeconds:)`, drop the gate.
- **D2 (Major) — `sizechange` + `colorchange` operators missing.** Not in operator switch (`Def:389-420`). Docs call them "essential". Size/color fixed at spawn → fade-and-grow embers, color-shift fire, shrinking sparks all wrong.
- **D3 (Minor→Mod) — oscillate operators missing** (oscillateposition/alpha/size).
- **D4 (Mod) — random `exponent` bias ignored.** Flat `random(0...1)` (`System:212-216`). WPE skews distributions via exponent; not even parsed.
- **D5 (Mod) — `directions` reduced to binary axis mask** (`abs()` + `>0.0001`). WPE = scalar magnitudes relative to DistanceMax → anisotropic emission shapes lost.
- **D6 (Minor) — turbulence ad-hoc sine noise** (`System:498-502`, hardcoded freqs), not WPE noise field w/ speed/scale.
- **D7 (Minor) — `sequencemultiplier ×2` magic factor** (`System:310`, comment admits empirical); WPE model is purely lifetime-relative. `baseFrameRate` parsed but unused.
- **D8 (Mod) — `normal` blend overwrites instead of alpha-blends.** `executor:394-398` `src=one,dst=zero` ignores alpha → transparent sprite corners become solid → hard rectangular boxes. Correct = srcAlpha/oneMinusSrcAlpha. Affects only `normal`-blend particle materials.

**Strengths:** common-path math correct (rate, sphere dispersal, gravity, drag, angular, alphafade, all randoms incl. Y-flip), pixel→NDC projection + size mapping sound, sprite-sheet sequence + frame blend.

Note: 0 real particle `.json` under `…/431960/<id>/particles/`, so operator-frequency claims rest on docs' "essential operators" list.

Sources: docs particles/component/{general,emitter,initializer,operator}, particles/tutorial/spritesheet.
