# Stage E — Material / Pipeline Build / Combos / Texture defaults / Require / Uniform layout

**Real data verified:** `defaultprojects/arsenal/materials/pistols/goldmetal.json`, `eagleflag/materials/eagle.json`, `assets/materials/util/composelayer.json`, stock `assets/shaders/generic.frag`. Logic lives in `WPERenderPipelineBuilder.swift`.

## Checklist (abridged)

| rule | impl (file:line) | verdict | note |
|---|---|---|---|
| Material passes[] → per-pass shader | builder:54 | ✅ | loads shaders/<name>.vert/.frag |
| textures[] index → g_TextureN | builder:815-838 + :850-857 | ✅ | array idx N → slot N (goldmetal verified) |
| Texture index 0 = layer source | builder:822-829 | ✅ | matches WPE image-effect convention |
| combos{} → #define | builder:913-920; merged :674-676 | ✅ | + uppercase alias |
| Default combo from `// [COMBO]{"default":N}` | builder:650-658 | ✅ | material combos override |
| Combo default used in #if when undefined | builder:415-439 | ⚠️ | auto-defines missing → 0, not the [COMBO] default (Dev #2) |
| constantshadervalues → uniform defaults | parsed Parser:638; applied :687-691 | ✅ | goldmetal verified |
| constantshadervalues key→uniform via `material` name | :667-669,:688-690 | ✅ | |
| sampler `default` texture (util/black, util/noise) | builder:724-726 | ✅ | overridable by textures[] |
| default/asset/fbo/previous classification | builder:840-848 | ⚠️ | no `.image` case (ok for defaults) (Dev #4) |
| sampler `combo`=1 when bound, 0 otherwise | builder:727-734 | ✅ | matches doc |
| `require` {"COMBO":value} gating sampler | builder:678,700-713 | ⚠️ | ANDs all keys; missing→0 (Dev #1 for requireany) |
| `requireany:true` (OR) | — | ❌ | not read; generic.frag uses it → samplers wrongly gated off (Dev #1) |
| combo-level `require` | only :678 (sampler) | ❌ | combo `[COMBO]{...,require}` ignored → default always emitted (Dev #3) |
| uniform default vec2/3/4/int/float/bool | builder:789-796 | ✅ | |
| uniform `range` | — | ➖ | editor clamp only |
| `usershadervalues` (uniform→user prop) | — | ⚠️ | not referenced anywhere; eagle.json uses it → user color scheme dropped (Dev #5) |
| blending per-pass → MTL | WPEMetalPipelineCache:90-128 | ✅ | |
| cullmode | :79-88 | ✅ | |

## Deviations

- **Dev #1 (HIGH) — `requireany:true` (OR) treated as AND.** Stock `generic.frag`: `g_Texture1/g_Texture2` use `"requireany":true,"require":{"LIGHTING":1,"REFLECTION":1}`. `builder:700-713` ANDs and never reads `requireany` → a model lit by LIGHTING=1 but REFLECTION=0 gates NORMALMAP/PBRMASKS samplers **off** → flat/incorrect lighting on a huge fraction of materials (generic is the most common shader).
- **Dev #2 (MED) — undefined combo in #if auto-defined 0, ignoring [COMBO] default.** `builder:415-439`. Declared combos are fine (populate comboValues first); risk is header-declared combos with nonzero defaults.
- **Dev #3 (MED) — combo-level `require` ignored.** `generic.frag` `[COMBO]{"combo":"RIMLIGHTING","require":{"LIGHTING":1}}`. `builder:650-658` reads only combo+default. Defaults are 0 here so impact small, but diverges.
- **Dev #4 (LOW) — `default` string never `.image`.** `builder:840-848`; defaults are always engine assets → `.asset` correct. Completeness only.
- **Dev #5 (MED) — `usershadervalues` unhandled.** `eagle.json` `"usershadervalues":{"flagcolor1":"color2",...}`. Zero Swift refs. User color-scheme → uniform binding dropped → renders with constantshadervalues/defaults instead of user-selected colors.

**Strengths:** texture index→slot, slot-0 source, combos→#define, constantshadervalues→uniform-default with material-name remap, sampler defaults, sampler-combo-on-bind, vec/float/int/bool parse — all match doc + real material data.

Sources: docs shader/variables, shader/syntax; Steam guide id=770802221; real default-project materials.
