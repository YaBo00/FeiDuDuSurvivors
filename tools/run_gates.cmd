@echo off
REM Run every gate. All of them must report PASS.
REM NOTE: this file must stay CRLF + pure ASCII (cmd.exe mangles non-ASCII).
REM Editing the gate list? Change BOTH run_gates.cmd and run_gates.sh in one go.
setlocal
set "GC=C://111SoftWare//Godot//4.7.2-stable//Godot_v4.7.2-stable_win64_console.exe"
rem  This script lives in <project>\tools\ -- the project root is its parent.
for %%i in ("%~dp0..") do set "P=%%~fi"
set "B=res://scenes/battle/Battle.tscn"
set FAIL=0

echo [1/27] syntax gate (CheckAll: compiles every script + scene, ~3s)
"%GC%" --headless --path "%P%" --script res://scripts/dev/CheckAll.gd 2>&1 | findstr /C:"CHECK PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [2/27] battle loop - full 20 waves, invincible, deterministic
"%GC%" --headless --path "%P%" "%B%" -- --selftest | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [3/27] defeat / settlement path
"%GC%" --headless --path "%P%" "%B%" -- --selftest-defeat | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [4/27] menu flow - title / char-select / chosen char reaches battle
"%GC%" --headless --path "%P%" --script res://scripts/dev/MenuFlowProbe.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [5/27] art spec - assets, size / alpha / mipmap / alpha-health
"%GC%" --headless --path "%P%" --script res://scripts/dev/AssetProbe.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [6/27] art wiring - sprites really filled at runtime
"%GC%" --headless --path "%P%" --script res://scripts/dev/SpriteWiringProbe.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [7/27] spawn bounds - off-screen spawns, arena centered (headless + real widescreen)
"%GC%" --headless --path "%P%" --script res://scripts/dev/SpawnBoundsProbe.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)
"%GC%" --resolution 1600x720 --path "%P%" --script res://scripts/dev/SpawnBoundsProbe.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [8/27] shop flow - open / buy / deduct / leave to next wave
"%GC%" --headless --path "%P%" --script res://scripts/dev/ShopFlowProbe.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [9/27] pickup lifetime + env chain
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbePickupExpiry.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)
"%GC%" --headless --path "%P%" res://scenes/dev/EnvCheck.tscn -- --selftest | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [10/27] ranged enemy + boss skills - fire / enemy proj hits player / state machine (deterministic)
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeRangedBoss.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [11/27] character traits + weapon table - 6 chars, 176 deterministic assertions
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeCharTraits.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [12/27] floor tile grid - seamless tiling / uniform scale / camera independent / 5 theme textures
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeFloorTiles.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [13/27] endless mode - curve keeps growing past wave 20 / first 20 waves unchanged / no settle at wave 20
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeEndless.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [14/27] endless end-to-end - --selftest --endless, full 40 waves without premature settlement
"%GC%" --headless --path "%P%" "%B%" -- --selftest --endless | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [15/27] darkest-gun end-to-end - --selftest --char sad (pierce 99 / lifesteal / gold_on_hit path)
"%GC%" --headless --path "%P%" "%B%" -- --selftest --char sad | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [16/27] audio - 10 sfx load + BGM is a looping OGG (not a 7MB WAV)
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeAudio.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [17/27] font coverage - subset font must cover every char used in source (anti-tofu)
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeFont.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [18/27] projectile pierce semantics - one projectile hits the same enemy at most once
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbePierce.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [19/27] wave-end upgrade enemy cost - dual vote bundling / level pure / capped / end-to-end
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeUpgradeCost.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [20/27] magnet drop + global magnet - elite guaranteed / timer decay / beyond range / reset
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeMagnet.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [21/27] contact damage sum + cap - swarming stacks up to a bounded cap / iframe single-window kept
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeContactDamage.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [22/27] MetaSave ledger - empty fallback / accumulate / persist / clamp / corrupt-safe
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeMetaSave.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [23/27] spawn tide - pure function bounded / window total exactly conserved
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeSpawnTide.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [24/27] MetaSave meta shop - xp conversion / purchase persist / denied when broke or maxed / player bonus applied
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeMetaShop.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [25/27] shop item prerequisites - no dangling refs / locked when unowned / chain unlock step by step / default roll unchanged
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeShopRequires.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [26/27] char unlock + simulated recharge - default basic only / lock tag / pay dialog / confirm unlock refresh
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeCharUnlock.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [27/27] weapon evolution 2nd form - table / shots / pierce / gold / lifesteal / rate / aoe splash + dedup
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeWeaponEvolution2.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo.
if %FAIL%==0 (echo ALL GATES PASS) else (echo SOME GATES FAILED)
exit /b %FAIL%
