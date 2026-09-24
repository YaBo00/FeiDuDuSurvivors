@echo off
rem ============================================================
rem  One-click Web (browser) export for 肥嘟嘟幸存者.
rem
rem  Output: build\web\index.html  (+ .wasm / .pck / .js / icons)
rem  Open index.html through a tiny local server to test, or upload
rem  the whole build\web\ folder to any static host (GitHub Pages,
rem  Cloudflare Pages, Vercel, Nginx, ...).
rem
rem  Preset "Web (Mobile)" is single-threaded on purpose:
rem    - No COOP/COEP response headers required.
rem    - Works on iOS Safari and any plain static host.
rem  Trade-off: single-threaded wasm is a bit slower than threaded.
rem  To switch to threaded later: in the Godot editor -> Project ->
rem  Export -> Web (Mobile) -> enable "Thread Support", and host it
rem  with the two isolation headers set (see web_shell\README).
rem
rem  NOTE: Godot does NOT create the output folder for you. Create it
rem  up front or the export fails with "export path does not exist".
rem ============================================================
setlocal
set "GODOT=C:\111SoftWare\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64_console.exe"

rem  This script lives in <project>\tools\ -- the project root is its parent.
for %%i in ("%~dp0..") do set "PROJECT=%%~fi"
if "%PROJECT:~-1%"=="\" set "PROJECT=%PROJECT:~0,-1%"

if not exist "%GODOT%" (
    echo [ERROR] Godot not found at: %GODOT%
    echo         Edit this .cmd and fix the GODOT path.
    pause
    exit /b 1
)

if not exist "%PROJECT%\build\web" mkdir "%PROJECT%\build\web"

echo.
echo === Web export (release) ===
"%GODOT%" --headless --path "%PROJECT%" --export-release "Web (Mobile)" "build/web/index.html"
if errorlevel 1 (
    echo.
    echo [FAILED] web export
    pause
    exit /b 1
)

echo.
echo === DONE ===
echo   Output : %PROJECT%\build\web\
echo   Open   : %PROJECT%\build\web\index.html  (served over http, not file://)
pause
exit /b 0
