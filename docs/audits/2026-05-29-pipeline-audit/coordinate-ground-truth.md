# Coordinate-Convention Ground Truth: WPE (D3D) → Metal Port

Authoritative answer to "macOS vs Windows coordinate differences." Verified against the `linux-wallpaperengine` reference (a working WPE renderer in OpenGL) + graphics-convention references.

## 1. WPE scene Y direction: **Y-DOWN, top-left origin** (like D3D screen space)

Moving an object toward the TOP of the screen **DECREASES** `origin.y`. Proof — `linux-wallpaperengine` `CImage::setup()` (`CImage.cpp:250-254`):
```cpp
this->m_pos.x -= scene_width / 2;
this->m_pos.y = scene_height / 2 - this->m_pos.y;   // Y INVERTED
this->m_pos.z -= scene_width / 2;
this->m_pos.w = scene_height / 2 - this->m_pos.w;   // Y INVERTED
```
X is merely recentered; Y is recentered **AND flipped** — the flip exists precisely because WPE authoring space is Y-down (D3D-style) and the GL camera is Y-up. Corroborated by `CScene.cpp` (extent via `abs(origin.y)`, fullscreen layers at `origin={W/2,H/2,0}`).

## 2. Reference projection/view (2D)

`Camera.cpp`:
```cpp
m_lookat = glm::lookAt(eye, center, up);                                  // from scene JSON
m_projection = glm::ortho<float>(-width/2, width/2, -height/2, height/2, nearz, farz);  // Y-UP
m_projection = glm::translate(m_projection, eye);
// MVP = projection * lookAt   (GLM column-major, M*v)
```
`glm::ortho(left,right,bottom,top,...)` with `bottom=-h/2, top=+h/2` ⇒ **Y-up ortho** — which is exactly why `CImage::setup()` must pre-flip the Y-down origin. No Y inversion in the projection; the flip lives in vertex positions.

## 3. Convention table

| | D3D11/12 (WPE native) | **Metal** | OpenGL |
|---|---|---|---|
| (a) NDC/clip Y | +Y up | **+Y up (=D3D)** | +Y up |
| (b) framebuffer/viewport origin | top-left | **top-left (=D3D)** | bottom-left ❗ |
| (c) texture/UV origin | top-left, V down | **top-left, V down (=D3D)** | bottom-left, V up ❗ |
| (d) clip Z range | [0,1] | **[0,1] (=D3D)** | [-1,1] ❗ |
| (e) front-face winding | CW front | **CW front** (settable) | CCW front |
| (f) matrix / multiply | HLSL row `mul(v,M)` | column `M*v` | column `M*v` |

**Decisive fact (Veldrid / Hacks-of-Life):** Metal and D3D11 share identical clip-space (Y-up NDC, top-left framebuffer/texture origin, [0,1] depth). OpenGL is the outlier on (b)(c)(d). (Some tables conflate framebuffer origin with clip-Y — authoritatively, D3D/Metal clip-Y is up; framebuffer is top-left with a built-in viewport Y-flip.)

## 4. GL flips to DROP on Metal (a D3D→Metal port must NOT replicate)

1. **Present V-flip** (`WallpaperState.cpp` `m_vflip`, per-output `renderVFlip()`: Wayland/GLFW true, X11 false) — reconciles GL bottom-left origin. On Metal: fixed/removed.
2. **Present-quad "inverted positions"** (`CWallpaper.cpp:26-28`).
3. **`#define ddy(x) dFdy(-(x))`** (`ShaderUnit.cpp:51`) — GL framebuffer-Y negation. On Metal: `ddy→dfdy` **without** sign flip.
4. **`CImage::setup()` Y inversion** converts WPE Y-down → GL Y-up world. A Metal port should instead keep WPE Y-down (Y-down ortho, swap top/bottom) and not flip vertices — but do it **once**, never both.

## 4b. What a D3D→Metal port STILL must handle (Metal ≠ D3D)

- **(f) Matrix multiply order:** HLSL row `mul(v,M)` → MSL column `M*v`. Reference proves intent: `ShaderUnit.cpp:30` `#define mul(x,y) ((y)*(x))`. **The local code already does this correctly** (`WPERenderPipelineBuilder.swift:874`).
- **(e) Winding** only if culling 3D models; WPE 2D usually `glDisable(GL_CULL_FACE)`.
- **One deliberate WPE-Y-down → clip-Y-up mapping** is still required (you're mapping author Y-down to Metal Y-up NDC) — just *one* flip, not the GL pile.
- **Depth [0,1]:** use `orthoZO`/`perspectiveZO` (Metal/D3D), not GLM default `glm::ortho` ([-1,1]).

## 5. HLSL → MSL shader concerns

1. **`mul()` operand order — the big one.** HLSL `mul(v,M)` = row-vector `v·M`; MSL column-major `M*v`. Swap operands (or transpose on upload). ✅ done locally.
2. **`SV_Position`/fragcoord origin:** D3D and Metal both **top-left** → HLSL pixel-coord logic ports unchanged; do NOT apply GL's `gl_FragCoord.y = height − y` flip.
3. **`ddx`/`ddy` → `dfdx`/`dfdy` with NO sign flip** (drop the GL `dFdy(-x)`).
4. **Texture V:** D3D & Metal both V=0 at top → sample WPE UVs directly, no `1−v` flip.
5. **Type/intrinsic map** (mechanical): float2/3/4 native, frac→fract, lerp→mix, saturate/atan2/fmod native, tex2D/texSample2D→texture.sample; remember the matrix order swap.

## Bottom line
WPE scene space is **top-left, Y-down**. **Metal matches D3D**; strip linux-wallpaperengine's OpenGL-only flips (present vflip/inverted positions, texture V-flip, `ddy(-x)`, GL [-1,1] depth). Still required on Metal: HLSL→MSL `mul(v,M)→M*v` (done), `[0,1]` projections, ONE deliberate WPE-Y-down→clip-Y-up flip (currently inconsistent — matrix path flips, built-in geometry doesn't), and winding only for culled 3D models.

## Sources
- Almamu/linux-wallpaperengine (GitHub main): `CImage.cpp:250-254`, `Camera.cpp`, `CScene.cpp`, `CWallpaper.cpp:26-28,191-272`, `WallpaperState.cpp:24-29`, `ShaderUnit.cpp:30,45,51`.
- The Hacks of Life — "Keeping the Blue Side Up"; Veldrid backend-differences; REALTECH-VR coordinate systems; metashapes OpenGL→Metal projection; Microsoft HLSL matrix ordering; Apple MTLWinding + MSL spec; WPE docs ILayer/origin.
