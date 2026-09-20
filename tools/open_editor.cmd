@echo off
rem ============================================================
rem  Double-click this file to open the Godot editor for this project.
rem  (Kept ASCII-only on purpose: .cmd files with non-ASCII content
rem   get garbled by the Windows OEM code page.)
rem ============================================================
setlocal
set "GODOT=C:\111SoftWare\Godot\4.7.2-stable\Godot_v4.7.2-stable_win64.exe"

rem  %~dp0 always ends with a backslash. Quoting "...\game\" would make the
rem  parser read \" as an escaped quote, so the path arrives broken.
rem  Strip the trailing backslash before using it.
rem  This script lives in <project>\tools\ -- the project root is its parent.
for %%i in ("%~dp0..") do set "PROJECT=%%~fi"
if "%PROJECT:~-1%"=="\" set "PROJECT=%PROJECT:~0,-1%"

if not exist "%GODOT%" (
    echo [ERROR] Godot not found at: %GODOT%
    echo         Edit this .cmd and fix the GODOT path.
    pause
    exit /b 1
)

if not exist "%PROJECT%\project.godot" (
    echo [ERROR] project.godot not found under: %PROJECT%
    pause
    exit /b 1
)

start "" "%GODOT%" --path "%PROJECT%" --editor
exit /b 0
