@echo off
rem ============================================================
rem  One-click Windows export (Release + Debug).
rem
rem  NOTE 1: Godot does NOT create the output folder for you.
rem          If it is missing the export fails with:
rem              "the given export path does not exist."
rem          So both folders are created up front.
rem
rem  NOTE 2: never write "if COND cmdA & cmdB" in a .cmd file --
rem          the "&" binds outside the if, so cmdB runs unconditionally.
rem          Always use a parenthesised block.
rem ============================================================
setlocal
set "GODOT=C:\111SoftWare\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64_console.exe"

rem  This script lives in <project>\tools\ -- the project root is its parent.
for %%i in ("%~dp0..") do set "PROJECT=%%~fi"
if "%PROJECT:~-1%"=="\" set "PROJECT=%PROJECT:~0,-1%"

if not exist "%GODOT%" (
    echo [ERROR] Godot not found at: %GODOT%
    pause
    exit /b 1
)

if not exist "%PROJECT%\build\windows"       mkdir "%PROJECT%\build\windows"
if not exist "%PROJECT%\build\windows_debug" mkdir "%PROJECT%\build\windows_debug"

echo.
echo === [1/2] Release export ===
"%GODOT%" --headless --path "%PROJECT%" --export-release "Windows Desktop" "build/windows/FeiDuDuSurvivors.exe"
if errorlevel 1 (
    echo.
    echo [FAILED] release export
    pause
    exit /b 1
)

echo.
echo === [2/2] Debug export ===
"%GODOT%" --headless --path "%PROJECT%" --export-debug "Windows Desktop" "build/windows_debug/FeiDuDuSurvivors_debug.exe"
if errorlevel 1 (
    echo.
    echo [FAILED] debug export
    pause
    exit /b 1
)

echo.
echo === DONE ===
echo   Release : %PROJECT%\build\windows\
echo   Debug   : %PROJECT%\build\windows_debug\   (.console.exe prints engine logs)
pause
exit /b 0
