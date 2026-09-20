#!/usr/bin/env bash
# 秒级编译检查：编译工程里所有脚本与场景，几秒钟出结果。
# 用法： bash check.sh     （或 Windows 双击 check.cmd）
# 这是「我每改完一轮，立刻知道有没有写坏」的那个工具。
set -u
GC="${GODOT_CONSOLE:-/c/111SoftWare/Godot/4.7.2-stable/Godot_v4.7.2-stable_win64_console.exe}"
P="$(cd "$(dirname "$0")/.." && pwd)"
P_WIN="$(cygpath -m "$P" 2>/dev/null || echo "$P")"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/CheckAll.gd 2>&1 | grep -aE "CHECK PASS|CHECK FAIL|COMPILE FAIL|Parse Error"
exit "${PIPESTATUS[0]}"
