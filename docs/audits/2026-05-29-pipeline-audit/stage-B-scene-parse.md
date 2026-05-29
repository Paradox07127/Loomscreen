# Stage B — Scene Document Parse (scene.json → internal model)

**Method:** parser code vs the Steam structure guide (id=770802221) + **5 real `scene.json`** extracted from `scene.pkg` (PKGV0014–0019) in `431960/`. 0 raw scene.json on disk (all packed). Object census: 35 image, 12 particle, 7 text, 7 sound, **0 model/light**.

## Checklist (abridged to verdicts + notes)

| field/concept | impl (file:line) | verdict | note |
|---|---|---|---|
| root camera/general required; objects[] | Parser:35/38/45 | ✅ | throws if missing |
| general clearcolor / orthogonalprojection{w,h} | Parser:476/478 | ✅ | space-string vec; default 1920×1080 |
| general `ambientcolor` / `skylightcolor` | — | ❌ | present 5/5; **never read** |
| general `clearenabled` | — | ⚠️ | present 5/5; never read → always clears |
| general `fov`/`nearz`/`farz` | Camera:467-469 (wrong block) | ❌ | parser reads from **camera**; real files put them in **general** (5/5) |
| general `zoom` | — | ❌ | present 5/5 in general; never read |
| general bloom/hdr/camerafade/cameraparallax* | Parser:121 | ⚠️ | diagnostic only, not applied |
| camera center/eye/up | Camera:464-466 | ✅ | matches real files |
| object kind inference (no `type` key in real files) | Parser:451 | ✅ | shape inference matches corpus |
| object origin/angles/scale | Parser:184-186 | ✅ | string-vec; angles radians |
| object `parallaxDepth` | Parser:556 etc | ❌ | real value is `"x y"` string (5/5); `parseDouble`→nil → **always 0** |
| object `color` ({user,value} envelope) | Parser:526 | ⚠️ | image path uses bare parseVector3 (no unwrap) → enveloped tints lost; text path unwraps (ok) |
| object `alpha` (animated/{user,value}) | Parser:525 | ✅ | |
| object `blendmode` (string) | Parser:528 | ❌ | **field doesn't exist**; real field is `colorBlendMode` (int) |
| object `colorBlendMode` (int) | — | ❌ | the actual blend field, 42/61 objects; **never read** → all Normal |
| object visible/alignment/size/brightness/material | Parser:524-537 | ✅ | |
| object effects[]/passes/animationlayers/dependencies | Parser:539-600 | ✅ | keys match corpus |
| image perspective/solid/copybackground/ledsource/locktransforms | — | ⚠️ | present 40-51/61; ignored (`locktransforms` affects parent inherit) |
| particle path + instanceoverride | Parser:352/375 | ✅ | |
| text text/font/pointsize/color/align | Parser:239-277 | ✅ | envelope handled |
| text anchor/padding/backgroundcolor | — | ⚠️ | present 7/7; ignored |
| sound sound[]/volume({user,value})/playbackmode | Parser:190-220 | ✅ | unwrapDouble handles envelope |
| sound mintime/maxtime/muteineditor | — | ⚠️ | present 7/7; ignored |

## Deviations (severity-ordered)

- **❌ HIGH — `colorBlendMode` (int) read as `blendmode` (string); blend always Normal.** 42/61 real objects carry `colorBlendMode`, 0 carry `blendmode`. `WPESceneDocumentParser.swift:528`; map `WPESceneDocument.swift:541`. Every additive/multiply layer silently renders Normal.
- **❌ HIGH — `fov`/`nearz`/`farz`/`zoom` read from `camera`, live in `general`.** 5/5 real files. `Parser:467-469` → always defaults; `zoom` unmodeled. Wrong clip/FOV/parallax scaling.
- **❌ HIGH — `parallaxDepth` is `"x y"` 2-vector parsed as scalar → 0.** 49/49 objects. `Parser:556/374/279` `parseDouble`→nil→0. Parallax depth disabled.
- **❌ MED — `ambientcolor`/`skylightcolor` never read** (5/5; Steam guide lists ambient as core general field).
- **⚠️ MED — image `color` doesn't unwrap `{user,value}`** (`Parser:526` bare parseVector3) → user-bound image tints drop to white.
- **⚠️ MED — `clearenabled` ignored** → no-clear/transparent-accumulation scenes wrong.
- **⚠️ LOW — `orthogonalprojection.auto` defaulted true though key absent** → verify renderer doesn't discard explicit width/height.
- **⚠️ LOW — `locktransforms` ignored; `parent` hierarchy path untested vs corpus** (corpus uses flat absolute origins, no `parent`).

**Strengths:** structure/primitives (space-string vecs, {user,value} envelopes), object-shape inference, image/particle/text/sound shapes all match real corpus exactly. The HIGH bugs are silent (no import diagnostic).

Sources: Steam guide id=770802221; docs.wallpaperengine.io (SPA); real scene.pkg extractions (PKGV0014–0019).
