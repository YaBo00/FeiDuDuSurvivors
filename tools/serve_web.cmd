@echo off
rem ============================================================
rem  Serve the exported Web build over http for local testing.
rem
rem  Web exports CANNOT be opened via file:// (CORS blocks the
rem  .wasm/.pck fetch). This starts a tiny static server on
rem  port 8060 and opens the browser.
rem
rem  Get a public shareable link on top of this with, e.g.:
rem      npx --yes cloudflared tunnel --url http://localhost:8060
rem  or  npx --yes localtunnel --port 8060
rem ============================================================
setlocal
for %%i in ("%~dp0..") do set "PROJECT=%%~fi"
if "%PROJECT:~-1%"=="\" set "PROJECT=%PROJECT:~0,-1%"
set "WEB=%PROJECT%\build\web"

if not exist "%WEB%\index.html" (
    echo [ERROR] No web build found at: %WEB%
    echo         Run tools\export_web.cmd first.
    pause
    exit /b 1
)

cd /d "%WEB%"
echo Serving %WEB%  --^>  http://localhost:8060/
start "" http://localhost:8060/
python -m http.server 8060
exit /b 0
