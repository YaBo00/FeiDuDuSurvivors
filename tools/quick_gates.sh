#!/usr/bin/env bash
# 核心门禁：只跑 7 项最关键的检查（~4 分钟，大头是 20 波自检）。
# 用法：改完一个功能模块后跑一次，确认没改坏核心逻辑。
# 全量验证用 run_gates.sh（16 项，含美术/商店/菜单/音频/四角色端到端/无尽 40 波，~8 分钟）。
set -u
GC="${GODOT_CONSOLE:-/c/111SoftWare/Godot/4.7.2-stable/Godot_v4.7.2-stable_win64_console.exe}"
P="$(cd "$(dirname "$0")/.." && pwd)"
P_WIN="$(cygpath -m "$P" 2>/dev/null || echo "$P")"
B="res://scenes/battle/Battle.tscn"
FAIL=0

pass() { if [ "$1" -eq 0 ]; then echo "  ok"; else echo "  FAIL"; FAIL=1; fi; }

echo "[1/7] 语法门（加载主场景 + 战斗场景）"
"$GC" --headless --path "$P_WIN" --quit-after 5 2>&1 | grep -qE "SCRIPT ERROR|Parse Error"; op=$?
[ $op -ne 0 ]; pass $?
"$GC" --headless --path "$P_WIN" res://scenes/battle/Battle.tscn --quit-after 5 2>&1 | grep -qE "SCRIPT ERROR|Parse Error"; op=$?
[ $op -ne 0 ]; pass $?

echo "[2/7] 战斗主循环（20 波）"
"$GC" --headless --path "$P_WIN" "$B" -- --selftest 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[3/7] 失败结算路径"
"$GC" --headless --path "$P_WIN" "$B" -- --selftest-defeat 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[4/7] 刷怪边界"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/SpawnBoundsProbe.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[5/7] 角色特性与武器表（50 条断言，秒级）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbeCharTraits.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[6/7] 地面瓦片网格（4×4 无缝 / 相机无关，秒级）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbeFloorTiles.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[7/8] 无尽模式（曲线延伸 / 前 20 波不变 / 第 20 波不结算 / HUD 文案，秒级）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbeEndless.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[8/8] 字体覆盖（子集字体覆盖源码全部用字，防豆腐块，秒级）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbeFont.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo
if [ "$FAIL" -eq 0 ]; then echo "核心门禁 PASS"; else echo "核心门禁 FAIL"; fi
exit "$FAIL"
