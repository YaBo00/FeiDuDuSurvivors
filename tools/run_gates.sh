#!/usr/bin/env bash
# 一键跑完所有门禁。全部 PASS 才算工程没被改坏。
# 与 run_gates.cmd 等价（Windows 上双击那个；这个给命令行/Git Bash 用）。
# ⚠️ 改门禁必须【一次改完】本文件 + run_gates.cmd 两份，否则两边项数会对不上。
set -u

GC="${GODOT_CONSOLE:-/c/111SoftWare/Godot/4.7.2-stable/Godot_v4.7.2-stable_win64_console.exe}"
P="$(cd "$(dirname "$0")/.." && pwd)"
P_WIN="$(cygpath -m "$P" 2>/dev/null || echo "$P")"
B="res://scenes/battle/Battle.tscn"
FAIL=0

pass() { if [ "$1" -eq 0 ]; then echo "  ok"; else echo "  FAIL"; FAIL=1; fi; }

echo "[1/28] 语法门（CheckAll：编译全部脚本与场景，秒级）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/CheckAll.gd 2>&1 | grep -q "CHECK PASS"; pass $?

echo "[2/28] 战斗主循环（20 波全流程 / 无敌 / 确定性）"
"$GC" --headless --path "$P_WIN" "$B" -- --selftest 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[3/28] 失败结算路径（--selftest-defeat，特性关闭）"
"$GC" --headless --path "$P_WIN" "$B" -- --selftest-defeat 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[4/28] 菜单流程（标题 / 选角 / 进战斗）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/MenuFlowProbe.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[5/28] 美术规格（尺寸 / alpha / mipmap / 透明健康度）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/AssetProbe.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[6/28] 美术接线（精灵运行时真的被填充）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/SpriteWiringProbe.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[7/28] 刷怪边界（屏外出生 / 竞技场居中，headless + 真宽屏各一次）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/SpawnBoundsProbe.gd 2>&1 | grep -q "RESULT=PASS"; pass $?
"$GC" --resolution 1600x720 --path "$P_WIN" --script res://scripts/dev/SpawnBoundsProbe.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[8/28] 商店流程（开店 / 购买 / 扣钱 / 离开进下一波）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/ShopFlowProbe.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[9/28] 掉落寿命 + 环境链路"
# 用退出码判定（quit(0/1)）—— stdout 尾行在进程退出时偶发缓冲截断，文本解析会误报
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbePickupExpiry.gd > "$P/_g9_last.txt" 2>&1
pass $?
"$GC" --headless --path "$P_WIN" res://scenes/dev/EnvCheck.tscn -- --selftest 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[10/28] 远程怪 + Boss 三招技能（开火 / 敌弹命中 / 状态机确定性）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbeRangedBoss.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[11/28] 六角色特性 + 武器表（176 条确定性断言）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbeCharTraits.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[12/28] 地面瓦片网格（无缝 / 等比 / 相机无关 / 5 套主题）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbeFloorTiles.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[13/28] 无尽模式（曲线延伸 / 前 20 波不变 / 第 20 波不结算 / HUD 文案）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbeEndless.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[14/28] 无尽端到端（--selftest --endless，40 波不提前结算）"
"$GC" --headless --path "$P_WIN" "$B" -- --selftest --endless 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[15/28] darkest-gun 端到端（--selftest --char sad，pierce 99 / 吸血 / gold_on_hit）"
"$GC" --headless --path "$P_WIN" "$B" -- --selftest --char sad 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[16/28] 音频链路（10 个音效 + BGM 是循环 OGG）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbeAudio.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[17/28] 字体覆盖（子集字体覆盖源码全部用字，防豆腐块）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbeFont.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[18/28] 弹道穿透语义（单颗弹道对同一敌人至多命中一次）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbePierce.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[19/28] 波末升级敌人代价（双向投票：波末捆绑 / 等级纯净 / 乘区封顶 / 端到端生效）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbeUpgradeCost.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[20/28] 磁铁掉落与全场磁吸（精英必掉 / 计时衰减 / 范围外生效 / 重开归零）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbeMagnet.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[21/28] 接触伤害同帧求和+封顶（多怪围攻伤害叠加且有界 / 无敌帧单窗语义保留）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbeContactDamage.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[22/28] MetaSave 局外账本（空回落 / 累计入账 / 持久化 / 负值钳0 / 损坏安全）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbeMetaSave.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[23/28] 正弦怪潮（纯函数有界 / 窗口内总量精确守恒）"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbeSpawnTide.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[24/28] MetaSave meta shop - xp conversion / purchase persist / denied when broke or maxed / player bonus applied / zero-meta identical"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbeMetaShop.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[25/28] shop item prerequisites - no dangling refs / locked when unowned / chain unlock step by step / default roll unchanged"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbeShopRequires.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[26/28] char unlock + simulated recharge - default basic only / lock tag / pay dialog / confirm unlock refresh"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbeCharUnlock.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[27/28] weapon evolution 2nd form - table / shots / pierce / gold / lifesteal / rate / aoe splash + dedup"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbeWeaponEvolution2.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo "[28/28] new enemies batch - templates / pools / charger / splitter / bomber / support / BossPUA"
"$GC" --headless --path "$P_WIN" --script res://scripts/dev/_ProbeNewEnemies.gd 2>&1 | grep -q "RESULT=PASS"; pass $?

echo
if [ "$FAIL" -eq 0 ]; then echo "全部门禁 PASS"; else echo "有门禁未通过"; fi
exit "$FAIL"
