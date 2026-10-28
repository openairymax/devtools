#!/bin/bash
# Gate 36 三终态完备门禁（0.1.20 方案 §9.1 Gate 36 / C7）
#
# 权威依据：
#   0.1.20-架构改进完善和自演化方案.md §9.1 Gate 36：成功 / 失败 / 未知
#     三态各有构造用例；未知态不得被并入成功；fail-closed。
#   同方案 §3.7l：Gate 36 的 DoR 即 P0-7（四路径终态 + lightweight 档）。
#
# 断言（封闭世界，任何新增终态未分类即红）：
#   A1 终态域完备：grad.h 的 grad_status_e 恰为 7 值 0..6，与分类表全等
#   A2 生产者可达：grad_run.c 出口对 7 值全部有赋值（判据写在域内）
#   B1 用例完备：成功 / 失败 / 未知三分类各有构造用例，未知四值逐值有用例
#   B2 未知不并入成功：同一用例内不得同时断言成功态与未知态
#   B3 用例在位：每个终态用例必须经 RUN_TEST 注册且文件在构建目标内
#      （未注册的用例永不运行，等同虚设）
#   D1 未知可观测：机制面事件必须携带 stats.status，未知须可与成功区分
#
# 用法: g36-terminal-gate.sh
# 环境变量（selfcheck 注入用）：G36_ROOT
# 退出码: 0 = 通过；1 = 存在违例；2 = 环境错误
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
ROOT="${G36_ROOT:-$PROJECT_ROOT}"

HDR="${ROOT}/agent-workload/agentrt/atoms/coreloopthree/include/grad.h"
PROD="${ROOT}/agent-workload/products/cognition/src/grad/grad_run.c"
CASES="${ROOT}/agent-workload/products/cognition/tests/unit/test_grad_run.c"
RUNNER="${ROOT}/agent-workload/products/cognition/tests/unit/test_grad.c"
BUILD="${ROOT}/agent-workload/products/cognition/CMakeLists.txt"
EVENT="${ROOT}/agent-workload/agentrt/atoms/coreloopthree/src/cognition/think/engine_process_grad.c"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'
log_ok() { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err() { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section() { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

# 三分类 SSoT：成功 = 验证链完整且过门；失败 = 计划不放行；
# 未知 = 计划放行但验证深度不足（B 缺席/违例/轻载/无 LLM）。
SUCCESS="GRAD_STATUS_CONVERGED GRAD_STATUS_REPAIRED"
FAILURE="GRAD_STATUS_FAIL_CLOSED"
UNKNOWN="GRAD_STATUS_LIGHTWEIGHT GRAD_STATUS_NO_LLM"
UNKNOWN="$UNKNOWN GRAD_STATUS_B_UNAVAILABLE GRAD_STATUS_B_INVALID"
ALL="$SUCCESS $FAILURE $UNKNOWN"

# ── 环境前置（缺件即环境错误，不得静默跳过）──────────────────
for f in "$HDR" "$PROD" "$CASES" "$RUNNER" "$BUILD" "$EVENT"; do
    [ -f "$f" ] || { echo "受审文件缺失: $f"; exit 2; }
done

VIOLATIONS=0
fail() { log_err "$1"; VIOLATIONS=$((VIOLATIONS + 1)); }

# ── A1: 终态域完备（枚举 == 分类表，封闭世界）───────────────
section "A1: terminal-state domain (enum == classification)"
ENUM_BLOCK="$(awk '/^typedef enum \{/ { inblk = 1 }
    inblk { print }
    inblk && /^\} grad_status_e;/ { exit }' "$HDR")"
ENUM_SET="$(printf '%s\n' "$ENUM_BLOCK" \
    | grep -oE 'GRAD_STATUS_[A-Z_]+ *= *[0-9]+' | tr -d ' ' | paste -sd' ' - || true)"
EXPECT="GRAD_STATUS_CONVERGED=0 GRAD_STATUS_REPAIRED=1 GRAD_STATUS_FAIL_CLOSED=2 \
GRAD_STATUS_LIGHTWEIGHT=3 GRAD_STATUS_NO_LLM=4 GRAD_STATUS_B_UNAVAILABLE=5 \
GRAD_STATUS_B_INVALID=6"
EXPECT="$(printf '%s\n' $EXPECT | paste -sd' ' -)"
if [ "$ENUM_SET" = "$EXPECT" ]; then
    log_ok "A1 终态域 7 值 0..6，与三分类表全等"
else
    fail "A1 终态域与分类表不等价：实际 [${ENUM_SET}]"
fi
for s in $ALL; do
    case " $ENUM_SET " in
        *" ${s}="*) ;;
        *) fail "A1 分类表条目未在枚举域内: ${s}" ;;
    esac
done

# ── A2: 生产者可达（出口对 7 值全部有赋值）───────────────────
section "A2: producer reachability (grad_run exit)"
PROD_SET="$(grep -oE 'stats\.status *= *GRAD_STATUS_[A-Z_]+' "$PROD" \
    | grep -oE 'GRAD_STATUS_[A-Z_]+' | sort -u || true)"
if [ -z "$PROD_SET" ]; then
    fail "A2 出口无终态赋值，扫描口径异常"
fi
for s in $ALL; do
    printf '%s\n' "$PROD_SET" | grep -qx "$s" \
        || fail "A2 出口不可达终态（零赋值）: ${s}"
done
log_ok "A2 出口可达终态 $(printf '%s\n' "$PROD_SET" | wc -l | tr -d ' ') 值"

# ── 用例解析：函数体内的 stats.status 断言（函数级归属）──────
PAIRS="$(awk '
    /^(static )?void test_[a-z0-9_]+\(/ {
        fn = $0; sub(/^.*void /, "", fn); sub(/\(.*/, "", fn); next
    }
    fn != "" {
        rest = $0
        while (match(rest, /stats\.status == GRAD_STATUS_[A-Z_]+/)) {
            m = substr(rest, RSTART, RLENGTH)
            sub(/^.*GRAD_STATUS_/, "GRAD_STATUS_", m)
            print fn, m
            rest = substr(rest, RSTART + RLENGTH)
        }
    }
    /^}/ { fn = "" }
' "$CASES" | sort -u)"
if [ -z "$PAIRS" ]; then
    fail "B1 终态断言零命中，用例文件口径异常"
fi

# ── B1: 三分类用例完备（未知四值逐值）───────────────────────
section "B1: constructed cases per class"
ASSERTED="$(printf '%s\n' "${PAIRS:-}" | awk 'NF{print $2}' | sort -u)"
for s in $ALL; do
    printf '%s\n' "$ASSERTED" | grep -qx "$s" \
        || fail "B1 终态无用例断言: ${s}"
done
for cls in SUCCESS FAILURE UNKNOWN; do
    n=0
    for s in ${!cls}; do
        printf '%s\n' "$ASSERTED" | grep -qx "$s" && n=$((n + 1))
    done
    [ "$n" -gt 0 ] || fail "B1 分类零用例: ${cls}"
done
log_ok "B1 三分类全覆盖（断言 $(printf '%s\n' "$ASSERTED" | wc -l | tr -d ' ') 个终态）"

# ── B2: 未知不得并入成功（同用例内互斥）─────────────────────
section "B2: unknown must not merge into success"
MERGED=0
UNK_FNS="$(printf '%s\n' "$PAIRS" | while read -r fn st; do
    case " $UNKNOWN " in *" $st "*) echo "$fn" ;; esac
done | sort -u)"
if [ -z "$UNK_FNS" ]; then
    fail "B2 未知态无用例，互斥关系不可判"
fi
while IFS= read -r fn; do
    [ -z "$fn" ] && continue
    for s in $SUCCESS; do
        if printf '%s\n' "$PAIRS" | grep -qx "${fn} ${s}"; then
            fail "B2 用例 ${fn} 同时断言未知态与成功态 ${s}"
            MERGED=$((MERGED + 1))
        fi
    done
done <<< "$UNK_FNS"
[ "$MERGED" -eq 0 ] && log_ok "B2 未知态用例 $(printf '%s\n' "$UNK_FNS" | wc -l | tr -d ' ') 例内零成功态混入"

# ── B3: 用例在位（注册 + 构建目标）──────────────────────────
section "B3: cases registered and built"
FNS="$(printf '%s\n' "$PAIRS" | awk 'NF{print $1}' | sort -u)"
grep -q 'tests/unit/test_grad_run.c' "$BUILD" \
    || fail "B3 用例文件未列入构建目标（永不编译）"
while IFS= read -r fn; do
    [ -z "$fn" ] && continue
    grep -qE "RUN_TEST\(${fn}\)" "$RUNNER" \
        || fail "B3 用例未注册（永不运行）: ${fn}"
done <<< "$FNS"
log_ok "B3 用例注册与构建目标齐备（$(printf '%s\n' "$FNS" | wc -l | tr -d ' ') 例）"

# ── D1: 未知可观测（事件携带 status）────────────────────────
section "D1: unknown observable in mechanism event"
D1_BAD=0
grep -q 'grad_out.stats.status' "$EVENT" || {
    fail "D1 机制面事件未携带 stats.status，未知态不可区分"
    D1_BAD=1
}
grep -q 'GRAD_STATUS_NO_LLM' "$EVENT" || {
    fail "D1 无 LLM 路径未显式申报未知终态"
    D1_BAD=1
}
[ "$D1_BAD" -eq 0 ] && log_ok "D1 事件携带终态，未知态可观测"

# ── 裁决 ────────────────────────────────────────────────────
section "Verdict"
if [ "$VIOLATIONS" -gt 0 ]; then
    log_err "Gate 36 三终态完备违例 ${VIOLATIONS} 处"
    exit 1
fi
log_ok "Gate 36 三终态完备通过（未知 ≠ 通过）"
exit 0
