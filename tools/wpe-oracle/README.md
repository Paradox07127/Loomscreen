# WPE Runtime Oracle: Windows Shader-First Capture Kit

This is the minimal first slice only:

- shared `wpe.trace.v1` contract
- Windows RenderDoc shader-first capture/export
- no Mac Swift exporter
- no diff engine
- no HTML report

The stop-loss is intentional: first validate that RenderDoc can see Wallpaper Engine's WorkerW desktop-wallpaper D3D11 path.

## Requirements

- Windows interactive logon session. Do not run capture from SSH.
- Wallpaper Engine 2.8.26 (default path `D:\Steam\steamapps\common\wallpaper_engine\`, or set `wpeRoot` in the job).
- Workshop scenes at `D:\Steam\steamapps\workshop\content\431960\<id>\` (or set `workshopRoot` / `projectJson` in the job).
- RenderDoc for Windows (v1.31+ recommended) installed.
- Python available through RenderDoc's Python environment (`renderdoccmd python`) or a Python environment where `renderdoc` is importable.

No scheduled task is used. No `-ExecutionPolicy Bypass` is used. `run_once.cmd` is a plain command script the user launches manually.

## Files

- `wpe-trace.schema.json`: JSON Schema draft 2020-12 for `wpe.trace.v1`.
- `extract_renderdoc_trace.py`: RenderDoc replay exporter for `.rdc` files.
- `run_once.cmd`: user-launched one-shot capture entry.
- `job.example.json`: seed job for scene `3526278753`.

Artifacts are written under:

```text
tools\wpe-oracle\captures\<jobId>\windows\
  frame.rdc
  trace.json
  rt\*.png
  shaders\*.dxbc.txt
tools\wpe-oracle\captures\<jobId>\done.json
```

`captures/` can contain WPE assets, shader disassembly, and large `.rdc` files. Keep it gitignored and local.

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
- tries RenderDoc capture
- exports `windows\trace.json`, `rt\*.png`, and `shaders\*.dxbc.txt`
- writes `done.json`

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
- `status=failed`: capture or extraction failed; inspect the console stdout/stderr and the `error` field in `done.json`. (Per-texture save failures additionally drop a `*.error.txt` beside the affected PNG.)

The minimum useful success is:

- `windows\trace.json` exists
- `passes[]` is non-empty
- `resources.shaders` contains DXBC disassembly paths
- `constantBuffers[]` contains runtime values such as `g_Time` when reflection exposes them
- `rt\*.png` contains at least one render target dump

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

- Missing HLSL source is expected. DXBC disassembly and reflection are the baseline.
- This first slice intentionally does not classify divergences.
- Do not commit `.rdc`, PNGs, shader dumps, or captured WPE/workshop assets.
