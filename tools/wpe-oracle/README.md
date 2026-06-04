# WPE Runtime Oracle: Windows Shader-First Capture Kit

This is the minimal first slice only:

- shared `wpe.trace.v1` contract
- Windows RenderDoc capture + headless `renderdoccmd convert`
- Mac-side stdlib parser (`parse_capture.py`) for `frame.zip.xml` + blobs
- no Mac Swift exporter
- no diff engine
- no HTML report

The stop-loss is intentional: first validate that RenderDoc can see Wallpaper Engine's WorkerW desktop-wallpaper D3D11 path.

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
- This first slice intentionally does not classify divergences.
- Do not commit `.rdc`, `.zip`, `frame.zip.xml`, shader blobs, or captured WPE/workshop assets.
