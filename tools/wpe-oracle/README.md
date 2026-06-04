# WPE Runtime Oracle: Windows ↔ Mac divergence kit

Cross-device pipeline that aligns Wallpaper Engine's real D3D11 frame (Windows
ground truth) against our Metal renderer and pinpoints where they diverge:

- shared `wpe.trace.v1` contract (both producers)
- **Windows producer**: RenderDoc capture + headless `renderdoccmd convert` + Mac-side stdlib parser (`parse_capture.py`) → `windows/trace.json`
- **Mac producer** (Phase A): `WPECanonicalTraceRecorder.swift` emits `mac/trace.json` from the live Metal scene-debug path
- **Diff engine** (Phase B): `diff_traces.py` DP-aligns the two pass lists, normalizes uniforms by name, and buckets the first real divergence → `diff/divergence-summary.json` (`wpe.diff.v1`)
- not yet: corpus orchestration (Phase C), extra fidelity tools (Phase D), HTML report / in-app panel (Phase E)

Scope is structure / uniform / topology / texture-binding / RT-lineage diffing.
Per-pass perceptual (SSIM/ΔE) diff is deferred (the convert path has no WPE RT
readback); Mac per-pass RT hashes are best-effort placeholders for it.

## Requirements

- Windows interactive logon session. Do not run capture from SSH.
- Wallpaper Engine 2.8.26 (default path `D:\Steam\steamapps\common\wallpaper_engine\`, or set `wpeRoot` in the job).
- Workshop scenes at `D:\Steam\steamapps\workshop\content\431960\<id>\` (or set `workshopRoot` / `projectJson` in the job).
- RenderDoc for Windows (validated on v1.44) installed.
- Python 3 on the Mac for `parse_capture.py` (stdlib only).

No scheduled task is used. No `-ExecutionPolicy Bypass` is used. `run_once.cmd` is a plain command script the user launches manually.

## Files

- `wpe-trace.schema.json`: JSON Schema draft 2020-12 for `wpe.trace.v1`.
- `run_once.cmd`: user-launched Windows capture entry → `renderdoccmd convert` → `frame.zip.xml` + `frame.zip`.
- `parse_capture.py`: Mac stdlib parser; turns the convert output into `trace.json` + `shader-interface.md`.
- `extract_renderdoc_trace.py`: retained ONLY as a qrenderdoc GUI Python-shell alternative. RenderDoc 1.44 has no standalone `renderdoc` module and no `renderdoccmd python`, so it cannot run headless.
- `diff_traces.py`: Mac stdlib diff engine; aligns `windows/trace.json` ↔ `mac/trace.json` and writes `diff/divergence-summary.json` (`wpe.diff.v1`). The Mac trace is produced on-device by `WPECanonicalTraceRecorder` (DEBUG builds) into the scene-debug session folder.
- `job.example.json`: seed job for scene `3526278753`.

Artifacts are written under:

```text
tools\wpe-oracle\captures\<jobId>\windows\
  frame.rdc            (Windows; the raw capture)
  frame.zip.xml        (Windows; renderdoccmd convert structure)
  frame.zip            (Windows; convert blob payloads)
  trace.json           (Mac; parse_capture.py → wpe.trace.v1)
  shader-interface.md  (Mac; per-shader RDEF + signatures)
tools\wpe-oracle\captures\<jobId>\done.json
```

`captures/` holds WPE assets, shader bytecode, and large `.rdc`/`.zip` files. Keep it gitignored and local.

## Operator Flow

1. Install RenderDoc on Windows.

2. Copy a job, then edit the Steam paths inside it if Steam is not on `D:\`:

```cmd
cd tools\wpe-oracle
mkdir jobs 2>nul
copy job.example.json jobs\seed-3526278753-shader-first.json
:: edit jobs\seed-3526278753-shader-first.json: wpeRoot / workshopRoot / projectJson
```

3. Launch from the Windows interactive desktop session:

```cmd
run_once.cmd jobs\seed-3526278753-shader-first.json
```

4. The script:

- sets the process to per-monitor DPI aware v2 before reading screen geometry
- centers the pointer
- switches WPE to the scene via:

```cmd
wallpaper64.exe -control openWallpaper -file <project.json>
```

- warms up
- tries RenderDoc capture (auto launch-under / inject)
- runs `renderdoccmd convert -f <frame.rdc> -o windows\frame.zip.xml -c zip.xml`
- writes `done.json`

> **Reality check (validated on RenderDoc 1.44 + WPE 2.8.26):** WPE is a single-instance, windowless wallpaper, so CLI auto-capture rarely triggers. The reliable capture is the RenderDoc **GUI → "Launch Application"** tab: kill the running `wallpaper64.exe` first, then Launch `wallpaper64.exe` (working dir = the WPE folder, "Capture Child Processes" on) so RenderDoc owns the sole instance, then "Capture Frame(s) Immediately" and **Save Capture As** `frame.rdc`. `renderdoccmd convert` and `parse_capture.py` then run headlessly over SSH.

5. Copy the capture dir to the Mac and parse it (headless, stdlib only):

```bash
python3 tools/wpe-oracle/parse_capture.py \
  --capture-dir tools/wpe-oracle/captures/<jobId>/windows --scene-id <id>
```

This emits `windows/trace.json` (wpe.trace.v1) + `windows/shader-interface.md`.

## Divergence Diff (Phase B)

The Mac producer runs on-device: a DEBUG build with scene-debug artifacts
enabled (`defaults write Taijia.LiveWallpaper WPESceneDebugArtifactsEnabled -bool YES`,
then relaunch) writes `trace.json` into each scene-debug session folder
(`~/Library/Containers/Taijia.LiveWallpaper/Data/Library/Application Support/LiveWallpaper/scene-debug/<stamp>-<id>/`).
Copy it next to the Windows trace as `mac/trace.json`, then diff:

```bash
python3 tools/wpe-oracle/diff_traces.py \
  --windows tools/wpe-oracle/captures/<jobId>/windows/trace.json \
  --mac     tools/wpe-oracle/captures/<jobId>/mac/trace.json \
  --out     tools/wpe-oracle/captures/<jobId>/diff/divergence-summary.json
```

`divergence-summary.json` (`wpe.diff.v1`) carries: `status`, `primaryBucket`
(transpiler / FBO / asset / puppet+particle), `firstDivergence` (with a
`pinpoint` naming the exact pass / uniform / texture and a `responsibleSite`
code path), the full pass `alignment` (deletions = passes only WPE drew, e.g.
particle `POINTLIST`), per-pass `passes[].status` (matched / diverged /
unverified-cascade / skipped_on_mac), and `bucketHistogram`. Uniform-packing
differences (WPE `g_bufStatic`/`g_bufDynamic` split vs our flat slot array) are
reconciled by name and reported in `normalizationNotes`, not as divergence.

> Coverage note: the recorder traces custom-shader passes (the effect chain).
> The base-image `genericimage4` draw goes through a non-custom path and is not
> yet captured, so the diff reports it as a `missing-wpe-pass` (transpiler
> bucket) rather than a real rendering divergence.

## Mac to Windows Bridge

SSH is only for job delivery and artifact retrieval. It must not attempt interactive capture.

Example delivery (forward slashes parse most reliably over OpenSSH on Windows):

```bash
ssh Taijia@100.117.237.66 "mkdir D:/path/to/tools/wpe-oracle/jobs" 2>/dev/null
scp tools/wpe-oracle/job.example.json Taijia@100.117.237.66:D:/path/to/tools/wpe-oracle/jobs/seed-3526278753-shader-first.json
```

Then the user manually runs `run_once.cmd` on Windows.

Example retrieval:

```bash
scp -r Taijia@100.117.237.66:D:/path/to/tools/wpe-oracle/captures/seed-3526278753-shader-first ./captures/
```

## Feasibility Signal

The key signal is in `done.json`:

- `status=succeeded`, `hookMethod=launch-under`: RenderDoc saw WPE when launched under RenderDoc.
- `status=succeeded`, `hookMethod=inject`: RenderDoc saw an already-running `wallpaper64.exe`.
- `status=needs-ui`: CLI automation did not capture WPE. Use RenderDoc UI injection next.
- `status=failed`: convert failed; inspect the console stdout/stderr and the `error` field in `done.json`.

The minimum useful success is:

- Windows: `windows\frame.zip.xml` exists and `done.json.status` is `succeeded`.
- Mac (after `parse_capture.py`): `windows/trace.json` exists and validates against `wpe.trace.v1`.
- Mac: `passes[]` is non-empty.
- Mac: `resources.shaders` carries DXBC shader records + RDEF reflection (`shader-interface.md`).
- Mac: `constantBuffers[]` carries decoded runtime values (matrices like `g_ModelViewProjectionMatrix`) where RDEF layout + buffer contents allow.

## Fallback Ladder

1. **Launch-under-RenderDoc**

Use when WPE is not already running or the job sets `"captureMethod": "launch-under"`.

2. **Inject**

Use when WPE is already running. The script tries `renderdoccmd inject` against the newest `wallpaper64.exe` PID.

3. **RenderDoc UI**

If CLI capture fails:

- open RenderDoc in the interactive session
- **File > Inject into Process**, search `wallpaper64.exe`, click **Inject**
- once the wallpaper is visible, click **Capture Frame(s) Immediately** in the
  connection panel (the windowless wallpaper has no focus, so the F12 hotkey
  usually will not fire — use the UI button)
- select the capture, **File > Save Capture As**, save it as
  `captures\<jobId>\windows\frame.rdc`
- rerun:

```cmd
run_once.cmd jobs\<jobId>.json extract-only
```

4. **Nsight Graphics**

If RenderDoc cannot hook WorkerW/WPE at all, validate the path with Nsight Graphics on the NVIDIA RTX PRO 6000 machine before building any Mac-side trace or diff code.

## Notes

- Missing HLSL source is expected — WPE ships only DXBC. RDEF reflection (cbuffer layouts, resource/sampler bindings) + ISGN/OSGN signatures are the baseline, parsed by `parse_capture.py`.
- The convert path has no GPU replay readback, so per-RT PNGs are intentionally absent; `output.png` is `null` in `trace.json`. (Replayed images need the qrenderdoc GUI.)
- Divergence classification lives in `diff_traces.py` (Phase B); see "Divergence Diff" above.
- Do not commit `.rdc`, `.zip`, `frame.zip.xml`, shader blobs, captured WPE/workshop assets, or `mac/`+`diff/` outputs.
