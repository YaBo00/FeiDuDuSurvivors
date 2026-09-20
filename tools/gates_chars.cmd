@echo off
REM Six-character acceptance sweep: --selftest --char X for all six.
REM Slow (~100s per character) -- run at milestones, not every edit.
REM NOTE: this file must stay CRLF + pure ASCII (cmd.exe mangles non-ASCII).
REM Editing the list? Change BOTH gates_chars.cmd and gates_chars.sh in one go.
setlocal
set "GC=C://111SoftWare//Godot//4.7.2-stable//Godot_v4.7.2-stable_win64_console.exe"
for %%i in ("%~dp0..") do set "P=%%~fi"
set "B=res://scenes/battle/Battle.tscn"
set FAIL=0

echo [1/6] basic    - Surprise Barrage (baseline, pierce 2)
"%GC%" --headless --path "%P%" "%B%" -- --selftest --char basic | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [2/6] study     - Chalk Barrage (2 shots, fast, pierce 1)
"%GC%" --headless --path "%P%" "%B%" -- --selftest --char study | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [3/6] finance   - Gold Dart (pierce 5, gold_on_hit 0.12)
"%GC%" --headless --path "%P%" "%B%" -- --selftest --char finance | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [4/6] sad       - Shadow Bolt (pierce 99, lifesteal 0.08, dmg 1.8)
"%GC%" --headless --path "%P%" "%B%" -- --selftest --char sad | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [5/6] potato    - Spud Heavy Shot (slow heavy, radius 2.5, armor stacks)
"%GC%" --headless --path "%P%" "%B%" -- --selftest --char potato | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [6/6] kangaroo  - Bouncy Fists (fast light, move-stacked spd/aspd)
"%GC%" --headless --path "%P%" "%B%" -- --selftest --char kangaroo | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo.
if %FAIL%==0 (echo ALL CHARACTER SWEEPS PASS) else (echo SOME CHARACTER SWEEPS FAILED)
exit /b %FAIL%
