#!/usr/bin/env bash
# 六角色验收扫（设计契约 §8.1：--selftest --char <id> 六连跑全绿）。
# 慢（每个角色约 100 秒真实时间）—— 里程碑跑，不要每次改代码都跑。
# 日常改动请用 tools/run_gates.sh，其中 [15/17] 已覆盖忧郁嘉豪这条最极端的武器路径。
set -u

GC="${GODOT_CONSOLE:-/c/111SoftWare/Godot/4.7.2-stable/Godot_v4.7.2-stable_win64_console.exe}"
P="$(cd "$(dirname "$0")/.." && pwd)"
P_WIN="$(cygpath -m "$P" 2>/dev/null || echo "$P")"
B="res://scenes/battle/Battle.tscn"
FAIL=0

pass() { if [ "$1" -eq 0 ]; then echo "  ok"; else echo "  FAIL"; FAIL=1; fi; }

echo "[1/6] basic    —— 随手连弹（基准，pierce 2）"
"$GC" --headless --path "$P_WIN" "$B" -- --selftest --char basic 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[2/6] study    —— 粉笔连射（2 发 / 高频 / pierce 1）"
"$GC" --headless --path "$P_WIN" "$B" -- --selftest --char study 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[3/6] finance  —— 金币镖（pierce 5 / gold_on_hit 0.12）"
"$GC" --headless --path "$P_WIN" "$B" -- --selftest --char finance 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[4/6] sad      —— 暗影弹（pierce 99 / 吸血 0.08 / 伤害 1.8）"
"$GC" --headless --path "$P_WIN" "$B" -- --selftest --char sad 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[5/6] potato   —— 薯块重弹（重弹慢速 / radius 2.5 / 受击叠甲）"
"$GC" --headless --path "$P_WIN" "$B" -- --selftest --char potato 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[6/6] kangaroo —— 蹦蹦拳（高频轻弹 / 移动叠攻速移速）"
"$GC" --headless --path "$P_WIN" "$B" -- --selftest --char kangaroo 2>&1 | grep -q "RESULT=PASS"; pass $?

echo
if [ "$FAIL" -eq 0 ]; then echo "六角色自检全绿"; else echo "有角色自检未通过"; fi
exit "$FAIL"
