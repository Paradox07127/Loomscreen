@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem WPE Runtime Oracle one-shot launcher.
rem User-launched in the interactive Windows desktop session only.
rem No scheduled task, no admin requirement, no -ExecutionPolicy Bypass.

set "SCRIPT_DIR=%~dp0"
set "ROOT=%SCRIPT_DIR%"
set "DEFAULT_WPE_ROOT=D:\Steam\steamapps\common\wallpaper_engine"
set "DEFAULT_WORKSHOP_ROOT=D:\Steam\steamapps\workshop\content\431960"
set "DEFAULT_SCENE_ID=3526278753"
set "STATUS=failed"
set "HOOK_METHOD=none"
set "ERROR_TEXT="

if "%~1"=="" (
  echo Usage:
  echo   run_once.cmd job.example.json
  echo   run_once.cmd jobs\my-job.json
  echo   run_once.cmd my-job-id
  echo   run_once.cmd jobs\my-job.json extract-only
  exit /b 2
)

set "JOB_ARG=%~1"
if exist "%JOB_ARG%" (
  set "JOB_FILE=%JOB_ARG%"
) else if exist "%ROOT%jobs\%JOB_ARG%.json" (
  set "JOB_FILE=%ROOT%jobs\%JOB_ARG%.json"
) else (
  echo [wpe-oracle] job not found: %JOB_ARG%
  exit /b 2
)

for %%I in ("%JOB_FILE%") do set "JOB_FILE=%%~fI"

call :read_job
if errorlevel 1 exit /b 2

set "OUT_DIR=%ROOT%captures\%JOB_ID%\windows"
rem renderdoccmd appends a frame suffix to --capture-file, so capture to a
rem template (frame) and resolve the newest frame*.rdc afterwards. Manual UI
rem saves to frame.rdc, which the same glob matches.
set "RDC_TEMPLATE=%OUT_DIR%\frame"
set "RDC_SAVE_AS=%OUT_DIR%\frame.rdc"
set "RDC_FILE="
set "DONE_JSON=%ROOT%captures\%JOB_ID%\done.json"
set "CONVERT_XML=%OUT_DIR%\frame.zip.xml"

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%" >nul 2>&1
if not exist "%OUT_DIR%\rt" mkdir "%OUT_DIR%\rt" >nul 2>&1
if not exist "%OUT_DIR%\shaders" mkdir "%OUT_DIR%\shaders" >nul 2>&1

echo [wpe-oracle] job=%JOB_ID%
echo [wpe-oracle] scene=%SCENE_ID%
echo [wpe-oracle] project=%PROJECT_JSON%
echo [wpe-oracle] mode=%MODE%
echo [wpe-oracle] out=%OUT_DIR%

call :find_renderdoc
if errorlevel 1 goto fail

call :set_dpi_and_center_pointer

if /i "%~2"=="extract-only" (
  call :find_newest_rdc
  if errorlevel 1 (
    set "ERROR_TEXT=extract-only requested but no %OUT_DIR%\frame*.rdc exists"
    goto fail
  )
  set "HOOK_METHOD=manual-ui"
  goto extract
)

if /i "%CAPTURE_METHOD%"=="launch-under" goto capture_launch_under
if /i "%CAPTURE_METHOD%"=="inject" goto capture_inject
if /i "%CAPTURE_METHOD%"=="ui" goto ui_fallback

call :detect_wpe_pid
if defined WPE_PID (
  goto capture_inject
) else (
  goto capture_launch_under
)

:capture_launch_under
set "HOOK_METHOD=launch-under"
echo [wpe-oracle] hook=%HOOK_METHOD% starting wallpaper64.exe under RenderDoc
echo [wpe-oracle] launch: "%RENDERDOCCMD%" capture --capture-file "%RDC_TEMPLATE%" --working-dir "%WPE_ROOT%" "%WPE_EXE%"

rem Background the capture: renderdoccmd stays attached for the target's
rem lifetime, and the wallpaper runs indefinitely, so a foreground call would
rem never return.
start "WPE RenderDoc capture" /min "%RENDERDOCCMD%" capture ^
  --capture-file "%RDC_TEMPLATE%" ^
  --working-dir "%WPE_ROOT%" ^
  --opt-hook-children ^
  "%WPE_EXE%"

timeout /t 3 /nobreak >nul
call :switch_scene
call :set_dpi_and_center_pointer
call :warmup
call :prompt_renderdoc_trigger
call :wait_for_rdc 120
if errorlevel 1 (
  echo [wpe-oracle] hook=launch-under did not produce an .rdc; trying inject if a WPE process is visible.
  call :detect_wpe_pid
  if defined WPE_PID goto capture_inject
  goto ui_fallback
)
echo [wpe-oracle] hook=launch-under status=succeeded
goto extract

:capture_inject
set "HOOK_METHOD=inject"
echo [wpe-oracle] hook=%HOOK_METHOD% switching WPE scene before capture
call :switch_scene
call :set_dpi_and_center_pointer
call :warmup
call :detect_wpe_pid
if not defined WPE_PID (
  echo [wpe-oracle] no wallpaper64.exe PID found for inject
  goto ui_fallback
)

echo [wpe-oracle] hook=inject pid=%WPE_PID%
rem PID is positional for `renderdoccmd inject`; it returns a target-control
rem ident (non-zero) on success, so we background it and watch for the .rdc
rem instead of testing errorlevel.
start "WPE RenderDoc inject" /min "%RENDERDOCCMD%" inject ^
  --capture-file "%RDC_TEMPLATE%" ^
  "%WPE_PID%"

call :prompt_renderdoc_trigger
call :wait_for_rdc 120
if errorlevel 1 goto ui_fallback
echo [wpe-oracle] hook=inject status=succeeded
goto extract

:ui_fallback
set "HOOK_METHOD=needs-ui"
echo.
echo [wpe-oracle] AUTO HOOK DID NOT CAPTURE.
echo [wpe-oracle] Feasibility signal: RenderDoc CLI alone did not produce a capture for WorkerW/WPE.
echo [wpe-oracle] Manual fallback (RenderDoc UI, interactive session):
echo   1. Open RenderDoc.
echo   2. File ^> Inject into Process, search "wallpaper64.exe", click Inject.
echo   3. Once the wallpaper is visible, click "Capture Frame(s) Immediately"
echo      in the connection panel (or press F12 / PrintScreen).
echo   4. Select the capture, File ^> Save Capture As, and save it as:
echo      %RDC_SAVE_AS%
echo   5. Re-run:
echo      %~nx0 "%JOB_FILE%" extract-only
set "STATUS=needs-ui"
call :write_done
exit /b 3

:extract
call :find_newest_rdc
echo [wpe-oracle] converting RenderDoc capture to structured zip.xml from %RDC_FILE%
if not exist "%RDC_FILE%" (
  set "ERROR_TEXT=missing capture under %OUT_DIR% (no frame*.rdc)"
  goto fail
)

rem RenderDoc 1.x has no `renderdoccmd python` and no standalone renderdoc module;
rem convert is headless/SSH-safe. The Mac parses frame.zip.xml via parse_capture.py.
if exist "%CONVERT_XML%" del "%CONVERT_XML%" >nul 2>&1
"%RENDERDOCCMD%" convert -f "%RDC_FILE%" -o "%CONVERT_XML%" -c zip.xml
if errorlevel 1 (
  set "ERROR_TEXT=renderdoccmd convert failed (see console stdout/stderr)"
  goto fail
)

if not exist "%CONVERT_XML%" (
  set "ERROR_TEXT=renderdoccmd convert completed without frame.zip.xml"
  goto fail
)

set "STATUS=succeeded"
call :write_done
echo [wpe-oracle] hook=%HOOK_METHOD% status=succeeded
echo [wpe-oracle] structured capture=%CONVERT_XML%
echo [wpe-oracle] next: copy this capture dir to Mac, run: python3 parse_capture.py --capture-dir "%OUT_DIR%"
exit /b 0

:fail
if not defined ERROR_TEXT set "ERROR_TEXT=unknown failure"
echo [wpe-oracle] ERROR: %ERROR_TEXT%
set "STATUS=failed"
call :write_done
exit /b 1

:read_job
rem Parse the whole job JSON in ONE PowerShell call (11 sequential calls cost
rem ~15s of shell startup) and emit `set` statements into a temp batch to load.
echo [wpe-oracle] parsing job configuration...
set "TEMP_JOB_BAT=%TEMP%\wpe_oracle_job_%RANDOM%.bat"
powershell -NoProfile -Command ^
  "try { $j = Get-Content -Raw $env:JOB_FILE | ConvertFrom-Json -ErrorAction Stop } catch { Write-Error 'Failed to parse job JSON'; exit 1 };" ^
  "if (-not $j) { Write-Error 'Empty job JSON'; exit 1 };" ^
  "$jobId = if($j.jobId){$j.jobId}else{'job-'+(Get-Date -Format yyyyMMdd-HHmmss)};" ^
  "$sceneId = if($j.sceneId){$j.sceneId}else{'%DEFAULT_SCENE_ID%'};" ^
  "$mode = if($j.mode){$j.mode}else{'shader-first'};" ^
  "$wpeRoot = if($j.wpeRoot){$j.wpeRoot}else{'%DEFAULT_WPE_ROOT%'};" ^
  "$workshopRoot = if($j.workshopRoot){$j.workshopRoot}else{'%DEFAULT_WORKSHOP_ROOT%'};" ^
  "$projectJson = if($j.projectJson){$j.projectJson}else{Join-Path $workshopRoot ($sceneId + '\project.json')};" ^
  "$renderDocCmd = if($j.renderDocCmd){$j.renderDocCmd}else{''};" ^
  "$warmupMs = if($j.warmupMs -ne $null){[int]$j.warmupMs}else{1500};" ^
  "$frameOrdinal = if($j.frameOrdinal -ne $null){[int]$j.frameOrdinal}else{0};" ^
  "$captureMethod = if($j.captureMethod){$j.captureMethod}else{'auto'};" ^
  "$wpeVersion = if($j.wpeVersion){$j.wpeVersion}else{'2.8.26'};" ^
  "Write-Output ('set \"JOB_ID=' + $jobId + '\"');" ^
  "Write-Output ('set \"SCENE_ID=' + $sceneId + '\"');" ^
  "Write-Output ('set \"MODE=' + $mode + '\"');" ^
  "Write-Output ('set \"WPE_ROOT=' + $wpeRoot + '\"');" ^
  "Write-Output ('set \"WORKSHOP_ROOT=' + $workshopRoot + '\"');" ^
  "Write-Output ('set \"PROJECT_JSON=' + $projectJson + '\"');" ^
  "Write-Output ('set \"RENDERDOCCMD=' + $renderDocCmd + '\"');" ^
  "Write-Output ('set \"WARMUP_MS=' + $warmupMs + '\"');" ^
  "Write-Output ('set \"FRAME_ORDINAL=' + $frameOrdinal + '\"');" ^
  "Write-Output ('set \"CAPTURE_METHOD=' + $captureMethod + '\"');" ^
  "Write-Output ('set \"WPE_VERSION=' + $wpeVersion + '\"');" ^
  > "%TEMP_JOB_BAT%"
if errorlevel 1 (
  echo [wpe-oracle] ERROR: failed to parse job JSON or file is corrupted.
  if exist "%TEMP_JOB_BAT%" del "%TEMP_JOB_BAT%" >nul 2>&1
  exit /b 1
)
call "%TEMP_JOB_BAT%"
del "%TEMP_JOB_BAT%" >nul 2>&1

set "WPE_EXE=%WPE_ROOT%\wallpaper64.exe"
if not exist "%WPE_EXE%" (
  echo [wpe-oracle] wallpaper64.exe not found: %WPE_EXE%
  exit /b 1
)
if not exist "%PROJECT_JSON%" (
  echo [wpe-oracle] project.json not found: %PROJECT_JSON%
  exit /b 1
)
exit /b 0

:find_renderdoc
if defined RENDERDOCCMD if exist "%RENDERDOCCMD%" exit /b 0
if exist "%ProgramFiles%\RenderDoc\renderdoccmd.exe" (
  set "RENDERDOCCMD=%ProgramFiles%\RenderDoc\renderdoccmd.exe"
  exit /b 0
)
if exist "%ProgramFiles(x86)%\RenderDoc\renderdoccmd.exe" (
  set "RENDERDOCCMD=%ProgramFiles(x86)%\RenderDoc\renderdoccmd.exe"
  exit /b 0
)
for /f "delims=" %%A in ('where renderdoccmd.exe 2^>nul') do (
  set "RENDERDOCCMD=%%A"
  exit /b 0
)
set "ERROR_TEXT=renderdoccmd.exe not found; install RenderDoc or set renderDocCmd in job.json"
exit /b 1

:switch_scene
echo [wpe-oracle] WPE control openWallpaper
"%WPE_EXE%" -control openWallpaper -file "%PROJECT_JSON%"
exit /b 0

:warmup
for /f "usebackq delims=" %%A in (`powershell -NoProfile -Command "[Math]::Max(1, [Math]::Ceiling([int]$env:WARMUP_MS / 1000.0))"`) do set "WARMUP_SECONDS=%%A"
echo [wpe-oracle] warmup=%WARMUP_MS%ms
timeout /t %WARMUP_SECONDS% /nobreak >nul
exit /b 0

:detect_wpe_pid
set "WPE_PID="
for /f "usebackq delims=" %%A in (`powershell -NoProfile -Command "$p=Get-Process wallpaper64 -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending | Select-Object -First 1; if($p){$p.Id}"`) do set "WPE_PID=%%A"
if defined WPE_PID echo [wpe-oracle] wallpaper64 pid=%WPE_PID%
exit /b 0

:set_dpi_and_center_pointer
powershell -NoProfile -Command ^
  "Add-Type 'using System; using System.Runtime.InteropServices; public static class W { [DllImport(\"user32.dll\")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v); [DllImport(\"user32.dll\")] public static extern int GetSystemMetrics(int n); [DllImport(\"user32.dll\")] public static extern bool SetCursorPos(int x,int y); }';" ^
  "[W]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null;" ^
  "$x=[W]::GetSystemMetrics(76)+[int]([W]::GetSystemMetrics(78)/2);" ^
  "$y=[W]::GetSystemMetrics(77)+[int]([W]::GetSystemMetrics(79)/2);" ^
  "[W]::SetCursorPos($x,$y) | Out-Null; Write-Host ('[wpe-oracle] pointer centered at {0},{1}' -f $x,$y)"
exit /b 0

:prompt_renderdoc_trigger
echo [wpe-oracle] RenderDoc should now be attached to wallpaper64.exe.
echo [wpe-oracle] If no capture appears, trigger ONE capture from the RenderDoc
echo [wpe-oracle] connection panel ("Capture Frame(s) Immediately") while waiting.
exit /b 0

:find_newest_rdc
set "RDC_FILE="
for /f "delims=" %%F in ('dir /b /a:-d /o:-d "%OUT_DIR%\frame*.rdc" 2^>nul') do (
  set "RDC_FILE=%OUT_DIR%\%%F"
  exit /b 0
)
exit /b 1

:wait_for_rdc
set "WAIT_LIMIT=%~1"
if not defined WAIT_LIMIT set "WAIT_LIMIT=60"
set /a WAITED=0
:wait_loop
call :find_newest_rdc
if not errorlevel 1 (
  echo [wpe-oracle] capture file detected: %RDC_FILE%
  exit /b 0
)
if %WAITED% GEQ %WAIT_LIMIT% (
  echo [wpe-oracle] TIMEOUT: no frame*.rdc under %OUT_DIR% after %WAIT_LIMIT%s.
  exit /b 1
)
set /a REMAINING=WAIT_LIMIT-WAITED
set /a MOD=WAITED %% 5
if %MOD%==0 echo [wpe-oracle] waiting for capture... %REMAINING%s remaining (watch %OUT_DIR%\frame*.rdc)
timeout /t 1 /nobreak >nul
set /a WAITED+=1
goto wait_loop

:write_done
for %%D in ("%DONE_JSON%") do if not exist "%%~dpD" mkdir "%%~dpD" >nul 2>&1
powershell -NoProfile -Command ^
  "$done=[ordered]@{status=$env:STATUS; jobId=$env:JOB_ID; sceneId=$env:SCENE_ID; hookMethod=$env:HOOK_METHOD; error=$env:ERROR_TEXT; rdc=$env:RDC_FILE; convertedXml=$env:CONVERT_XML; completedUtc=(Get-Date).ToUniversalTime().ToString('o')};" ^
  "$done | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 $env:DONE_JSON"
echo [wpe-oracle] done=%DONE_JSON% status=%STATUS% hook=%HOOK_METHOD%
exit /b 0
