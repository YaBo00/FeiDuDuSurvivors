@echo off
REM Fast compile check: builds every script/scene, reports errors in seconds.
setlocal
set "GC=C://111SoftWare//Godot//4.7.2-stable//Godot_v4.7.2-stable_win64_console.exe"
rem  This script lives in <project>\tools\ -- the project root is its parent.
for %%i in ("%~dp0..") do set "P=%%~fi"
"%GC%" --headless --path "%P%" --script res://scripts/dev/CheckAll.gd 2>&1 | findstr /C:"CHECK PASS" /C:"CHECK FAIL" /C:"COMPILE FAIL"

