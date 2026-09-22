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

echo [1/29] syntax gate (CheckAll: compiles every script + scene, ~3s)
"%GC%" --headless --path "%P%" --script res://scripts/dev/CheckAll.gd 2>&1 | findstr /C:"CHECK PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [2/29] battle loop - full 20 waves, invincible, deterministic
"%GC%" --headless --path "%P%" "%B%" -- --selftest | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [3/29] defeat / settlement path
"%GC%" --headless --path "%P%" "%B%" -- --selftest-defeat | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [4/29] menu flow - title / char-select / chosen char reaches battle
"%GC%" --headless --path "%P%" --script res://scripts/dev/MenuFlowProbe.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [5/29] art spec - assets, size / alpha / mipmap / alpha-health
"%GC%" --headless --path "%P%" --script res://scripts/dev/AssetProbe.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [6/29] art wiring - sprites really filled at runtime
"%GC%" --headless --path "%P%" --script res://scripts/dev/SpriteWiringProbe.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [7/29] spawn bounds - off-screen spawns, arena centered (headless + real widescreen)
"%GC%" --headless --path "%P%" --script res://scripts/dev/SpawnBoundsProbe.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)
"%GC%" --resolution 1600x720 --path "%P%" --script res://scripts/dev/SpawnBoundsProbe.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [8/29] shop flow - open / buy / deduct / leave to next wave
"%GC%" --headless --path "%P%" --script res://scripts/dev/ShopFlowProbe.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [9/29] pickup lifetime + env chain
rem 用退出码判定（quit(0/1)）—— stdout 尾行在进程退出时偶发缓冲截断，文本解析会误报
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbePickupExpiry.gd > "%P%\_g9_last.txt" 2>&1
if errorlevel 1 (echo   FAIL ^（详见 _g9_last.txt^） & set FAIL=1) else (echo   ok)
"%GC%" --headless --path "%P%" res://scenes/dev/EnvCheck.tscn -- --selftest | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [10/29] ranged enemy + boss skills - fire / enemy proj hits player / state machine (deterministic)
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeRangedBoss.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [11/29] character traits + weapon table - 6 chars, 176 deterministic assertions
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeCharTraits.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [12/29] floor tile grid - seamless tiling / uniform scale / camera independent / 5 theme textures
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeFloorTiles.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [13/29] endless mode - curve keeps growing past wave 20 / first 20 waves unchanged / no settle at wave 20
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeEndless.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [14/29] endless end-to-end - --selftest --endless, full 40 waves without premature settlement
"%GC%" --headless --path "%P%" "%B%" -- --selftest --endless | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [15/29] darkest-gun end-to-end - --selftest --char sad (pierce 99 / lifesteal / gold_on_hit path)
"%GC%" --headless --path "%P%" "%B%" -- --selftest --char sad | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [16/29] audio - 10 sfx load + BGM is a looping OGG (not a 7MB WAV)
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeAudio.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [17/29] font coverage - subset font must cover every char used in source (anti-tofu)
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeFont.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [18/29] projectile pierce semantics - one projectile hits the same enemy at most once
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbePierce.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [19/29] wave-end upgrade enemy cost - dual vote bundling / level pure / capped / end-to-end
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeUpgradeCost.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [20/29] magnet drop + global magnet - elite guaranteed / timer decay / beyond range / reset
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeMagnet.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [21/29] contact damage sum + cap - swarming stacks up to a bounded cap / iframe single-window kept
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeContactDamage.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [22/29] MetaSave ledger - empty fallback / accumulate / persist / clamp / corrupt-safe
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeMetaSave.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [23/29] spawn tide - pure function bounded / window total exactly conserved
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeSpawnTide.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [24/29] MetaSave meta shop - xp conversion / purchase persist / denied when broke or maxed / player bonus applied
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeMetaShop.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [25/29] shop item prerequisites - no dangling refs / locked when unowned / chain unlock step by step / default roll unchanged
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeShopRequires.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [26/29] char unlock + simulated recharge - default basic only / lock tag / pay dialog / confirm unlock refresh
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeCharUnlock.gd | findstr /C:"RESULT=PASS" >nul
if errorlevel 1 (echo   FAIL & set FAIL=1) else (echo   ok)

echo [27/29] weapon evolution 2nd form - table / shots / pierce / gold / lifesteal / rate / aoe splash + dedup
rem 用退出码判定（quit(0/1)）—— stdout 尾行偶发缓冲截断会让 findstr 误报（同 [9][28]）
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeWeaponEvolution2.gd > "%P%\_g27_last.txt" 2>&1
if errorlevel 1 (echo   FAIL ^（详见 _g27_last.txt^） & set FAIL=1) else (echo   ok)

echo [28/29] new enemies batch - templates / pools / charger / splitter / bomber / support / BossPUA
rem 用退出码判定（quit(0/1)）—— stdout 尾行偶发缓冲截断会让 findstr 误报（同 [9]）
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeNewEnemies.gd > "%P%\_g28_last.txt" 2>&1
if errorlevel 1 (echo   FAIL ^（详见 _g28_last.txt^） & set FAIL=1) else (echo   ok)

echo [29/29] difficulty system - table / normal bit-identical / hard multipliers / boss dynamic hp / half-hp rage
rem 用退出码判定（quit(0/1)）—— stdout 尾行偶发缓冲截断会让 findstr 误报（同 [27][28]）
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeDifficulty.gd > "%P%\_g29_last.txt" 2>&1
if errorlevel 1 (echo   FAIL ^（详见 _g29_last.txt^） & set FAIL=1) else (echo   ok)

echo [30/30] wave clear rhythm - 30s spawn window / no spawn after close / kill-ratio bar / no countdown text
rem 用退出码判定（quit(0/1)）—— stdout 尾行偶发缓冲截断会让 findstr 误报（同 [27][28][29]）
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeWaveClear.gd > "%P%\_g30_last.txt" 2>&1
if errorlevel 1 (echo   FAIL ^（详见 _g30_last.txt^） & set FAIL=1) else (echo   ok)

echo [31/31] elite affix system - table / spawn curve (wave^>=5, 1+wave/8) / swift-armored-enraged / exploder aoe + summoner / gold x3 + coupon / shop 0.8
rem 用退出码判定（quit(0/1)）—— stdout 尾行偶发缓冲截断会让 findstr 误报（同 [27][28][29][30]）
"%GC%" --headless --path "%P%" --script res://scripts/dev/_ProbeEliteAffix.gd > "%P%\_g31_last.txt" 2>&1
if errorlevel 1 (echo   FAIL ^（详见 _g31_last.txt^） & set FAIL=1) else (echo   ok)

echo.
if %FAIL%==0 (echo ALL GATES PASS) else (echo SOME GATES FAILED)
exit /b %FAIL%
