#!/bin/bash
# Gate 39 金丝雀爆炸半径门禁（0.1.20 方案 §9.1 Gate 39 / §7.0.2.2）
#
# 权威依据：
#   0.1.20 方案 §7.0.2.2：一次演化 ≤1 模块 / ≤3 文件 / ≤200 行；
#     G30 准入新增函数 ≤150 行、修改后 ≤200 行。
#   同方案 §9.3：门禁必须能把"上限悄悄消失"判红（B6 语义复辟、
#     恒真放行两类历史缺陷）。
#
# 断言：
#   A1 常量实例值：3 / 200 / 150 / 200 四值精确（口径漂移即红）
#   A2 比较在位：propose 两处 + admit 一处，且判据方向为 ">"（超限才拒）
#   A3 合法纯修改：admit(0, >0) 不被空度量判据误杀（B6 复辟防线）
#   B1 边界用例：恰好等于上限接受、超一拒绝，四类边界各有断言
#   C1 判别力：selfcheck/gate-39.sh 三用例（两红一绿）全部符合预期
#
# 用法: g39-blast-gate.sh
# 环境变量（selfcheck 注入用）：G39_ROOT、G39_SKIP_MUT
# 退出码: 0 = 通过；1 = 存在违例；2 = 环境错误
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
ROOT="${G39_ROOT:-$PROJECT_ROOT}"

CANARY="${ROOT}/agent-workload/products/canary"
HDR="${CANARY}/include/canary.h"
CORE="${CANARY}/src/canary_core.c"
CASES="${CANARY}/tests/unit/test_canary.c"
MUT="${SCRIPT_DIR}/selfcheck/gate-39.sh"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'
log_ok() { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err() { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section() { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

for f in "$HDR" "$CORE" "$CASES"; do
    [ -f "$f" ] || { echo "受审文件缺失: $f"; exit 2; }
done

VIOLATIONS=0
fail() { log_err "$1"; VIOLATIONS=$((VIOLATIONS + 1)); }

# ── A1: 常量实例值 ──────────────────────────────────────────
section "A1: blast-radius constants (instance values)"
check_def() { # $1=宏 $2=期望值
    grep -qE "^#define $1 +\(?$2\)?$" "$HDR" \
        || fail "A1 ${1} 非 ${2}（实际 $(grep -E "^#define $1 " "$HDR" | head -1 | awk '{print $3}')）"
}
check_def CANARY_MAX_FILES 3
check_def CANARY_MAX_LINES 200
check_def CANARY_FN_NEW_MAX 150
check_def CANARY_FN_MOD_MAX 200

# ── A2: 比较在位且方向正确 ──────────────────────────────────
section "A2: ceiling comparisons in place"
grep -qF 'if (b->nfiles > CANARY_MAX_FILES || b->lines > CANARY_MAX_LINES)' "$CORE" \
    || fail "A2 propose 爆炸半径比较缺失或改写（上限失守）"
grep -qF 'if (new_fn > CANARY_FN_NEW_MAX || mod_fn > CANARY_FN_MOD_MAX)' "$CORE" \
    || fail "A2 admit 函数行数比较缺失或改写（上限失守）"
ADMIT_BODY="$(awk '/^int canary_admit\(/ { f = 1 } f { print } f && /^}/ { exit }' "$CORE")"
printf '%s\n' "$ADMIT_BODY" | grep -qF 'new_fn == 0 && mod_fn == 0' \
    || fail "A2 空度量判据被改写（须仅 (0,0) 非法）"

# ── A3: 合法纯修改不被误杀（B6 复辟防线）───────────────────
section "A3: pure modification is legal (B6 regression guard)"
grep -qE 'CHECK\(canary_admit\(0, 200\) == 0\)' "$CASES" \
    || fail "A3 缺 (0,200)==0 用例：纯修改补丁可能被空度量判据误杀"
grep -qE 'CHECK\(canary_admit\(0, 201\) == -2\)' "$CASES" \
    || fail "A3 缺 (0,201)==-2 用例：纯修改超限不可判"

# ── B1: 四类边界用例 ────────────────────────────────────────
section "B1: boundary cases (at-limit accept, over-limit reject)"
grep -qE 'CHECK\(canary_admit\(150, 200\) == 0\)' "$CASES" \
    || fail "B1 缺恰好等于上限的接受用例 (150,200)"
grep -qE 'CHECK\(canary_admit\(151, 200\) == -2\)' "$CASES" \
    || fail "B1 缺新增函数超一拒绝用例 (151,200)"
grep -qE 'CHECK\(canary_admit\(150, 201\) == -2\)' "$CASES" \
    || fail "B1 缺修改超一拒绝用例 (150,201)"
grep -qE 'CHECK\(canary_admit\(0, 0\) == -1\)' "$CASES" \
    || fail "B1 缺空度量非法用例 (0,0)"
grep -qF 'b.nfiles = 4;' "$CASES" \
    || fail "B1 缺第 4 文件用例（≤3 文件硬约束不可判）"
grep -qF 'b.lines = 201;' "$CASES" \
    || fail "B1 缺 201 行用例（≤200 行硬约束不可判）"

# ── C1: 判别力（两红一绿）───────────────────────────────────
section "C1: mutation selfcheck (two red, one green)"
if [ "${G39_SKIP_MUT:-0}" = "1" ]; then
    fail "C1 selfcheck 被跳过：跳过不是判定（fail-closed）"
elif [ ! -x "$MUT" ]; then
    fail "C1 反向用例脚本缺失或不可执行: ${MUT}"
else
    rc=0
    bash "$MUT" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        log_ok "C1 selfcheck 3/3 符合预期（两红一绿）"
    else
        fail "C1 selfcheck 未通过（exit ${rc}）：上限判别力不成立"
    fi
fi

# ── 裁决 ────────────────────────────────────────────────────
section "Verdict"
if [ "$VIOLATIONS" -gt 0 ]; then
    log_err "Gate 39 爆炸半径违例 ${VIOLATIONS} 处"
    exit 1
fi
log_ok "Gate 39 爆炸半径硬约束成立（3 文件 / 200 行 / 150+200 函数行）"
exit 0
