@echo off
rem ============================================================
rem  Double-click this file to RUN the game (no editor).
rem  Same as pressing F5 inside the editor.
rem ============================================================
setlocal
set "GODOT=C:\111SoftWare\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe"

rem  Strip the trailing backslash from %~dp0 (see open_editor.cmd for why).
rem  This script lives in <project>\tools\ -- the project root is its parent.
for %%i in ("%~dp0..") do set "PROJECT=%%~fi"
if "%PROJECT:~-1%"=="\" set "PROJECT=%PROJECT:~0,-1%"

if not exist "%GODOT%" (
    echo [ERROR] Godot not found at: %GODOT%
    echo         Edit this .cmd and fix the GODOT path.
    pause
    exit /b 1
)

start "" "%GODOT%" --path "%PROJECT%"
exit /b 0
