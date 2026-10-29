#!/bin/bash
# Gate 38 金丝雀六门禁可触发门禁（0.1.20 方案 §9.1 Gate 38 / §9.1.2）
#
# 权威依据：
#   0.1.20-架构改进完善和自演化方案.md §9.1 Gate 38：六道门禁 K1-K6
#     必须各自可触发（-2..-7 互异），且"无观测样本"必须是 -8 而非放行。
#   同方案 §9.1.2：门禁必须自证判别力（注入违规样本必须能红）。
#
# 断言（封闭世界：新增门禁未登记即红）：
#   A1 六判据在位：canary_gates 体内六个比较表达式逐条精确存在
#   A2 返回码映射：六个 return 常量恰为 -2..-7，顺序与 K1..K6 全等
#   A3 未知域收口：CANARY_K_UNKNOWN == -8，且以具名常量返回（非魔法数）
#   B1 用例完备：-2..-7 与 -8 各有断言，且分处不同 test_ 函数
#   B2 用例在跑：用例文件列入构建目标
#   C1 判别力：selfcheck/gate-38.sh 八用例（七红一绿）全部符合预期
#
# 用法: g38-canary-gate.sh
# 环境变量（selfcheck 注入用）：G38_ROOT、G38_SKIP_MUT
# 退出码: 0 = 通过；1 = 存在违例；2 = 环境错误
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
ROOT="${G38_ROOT:-$PROJECT_ROOT}"

CANARY="${ROOT}/agent-workload/products/canary"
HDR="${CANARY}/include/canary.h"
CORE="${CANARY}/src/canary_core.c"
CASES="${CANARY}/tests/unit/test_canary.c"
BUILD_P="${CANARY}/CMakeLists.txt"
BUILD_T="${CANARY}/tests/unit/CMakeLists.txt"
MUT="${SCRIPT_DIR}/selfcheck/gate-38.sh"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'
log_ok() { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err() { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section() { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

for f in "$HDR" "$CORE" "$CASES" "$BUILD_P" "$BUILD_T"; do
    [ -f "$f" ] || { echo "受审文件缺失: $f"; exit 2; }
done

VIOLATIONS=0
fail() { log_err "$1"; VIOLATIONS=$((VIOLATIONS + 1)); }

# K1..K6 → 期望返回码（SSoT：与 canary.h 注释及方案 §9.1 表一致）。
# 首项 -1 为输入守卫（NULL 指标表），其后恰为 K1..K6 的 -2..-7。
K_CODES="-2 -3 -4 -5 -6 -7"
K_SEQ="-1 ${K_CODES}"

# ── A1: 六判据在位 ──────────────────────────────────────────
section "A1: six gate predicates present"
PREDICATES=(
    'g->ok_pm < CANARY_OK_FLOOR'
    'g->perf_ppm < CANARY_PERF_FLOOR'
    'g->crashes != 0u'
    'g->rb_secs > CANARY_RB_MAX_SECS'
    '(g->flags & CANARY_G_EXPLAIN) == 0u'
    '(g->flags & CANARY_G_BOUNDARY) == 0u'
)
for p in "${PREDICATES[@]}"; do
    grep -qF "$p" "$CORE" || fail "A1 判据缺失（门禁恒真）: ${p}"
done

# ── A2: 返回码映射（canary_gates 体内 return 常量序列）──────
section "A2: return code mapping == -2..-7"
BODY="$(awk '/^int canary_gates\(/ { f = 1 } f { print } f && /^}/ { exit }' "$CORE")"
[ -n "$BODY" ] || fail "A2 未定位 canary_gates 函数体，扫描口径异常"
CODES="$(printf '%s\n' "$BODY" | grep -oE 'return -[0-9]+;' | grep -oE '\-[0-9]+' | paste -sd' ' - || true)"
if [ "$CODES" = "$K_SEQ" ]; then
    log_ok "A2 六门禁返回码 -2..-7 顺序全等"
else
    fail "A2 返回码序列不符：实际 [${CODES}]"
fi

# ── A3: 未知域收口 ──────────────────────────────────────────
section "A3: unknown domain (-8, named constant)"
grep -qE '^#define CANARY_K_UNKNOWN +\(-8\)' "$HDR" \
    || fail "A3 CANARY_K_UNKNOWN 非 -8 定义"
grep -qF 'return CANARY_K_UNKNOWN;' "$CORE" \
    || fail "A3 未知态未以具名常量返回（魔法数会随重编号静默漂移）"
if printf '%s\n' "$BODY" | grep -qE 'return -8;'; then
    fail "A3 未知态以魔法数 -8 返回（应与宏同源）"
fi

# ── 用例解析：函数体内的门禁断言（函数级归属）───────────────
PAIRS="$(awk '
    /^(static )?void test_[a-z0-9_]+\(/ {
        fn = $0; sub(/^.*void /, "", fn); sub(/\(.*/, "", fn); next
    }
    fn != "" {
        rest = $0
        while (match(rest, /canary_gates\(&g\) == (-[0-9]+|CANARY_K_UNKNOWN)/)) {
            m = substr(rest, RSTART, RLENGTH)
            sub(/^.*== /, "", m)
            print fn, m
            rest = substr(rest, RSTART + RLENGTH)
        }
    }
    /^}/ { fn = "" }
' "$CASES" | sort -u)"

# ── B1: 用例完备且分处不同函数 ──────────────────────────────
section "B1: per-code constructed cases in distinct test functions"
for code in $K_CODES CANARY_K_UNKNOWN; do
    fns="$(printf '%s\n' "${PAIRS:-}" | awk -v c="$code" '$2 == c { print $1 }' | sort -u)"
    if [ -z "$fns" ]; then
        fail "B1 门禁返回码无用例断言: ${code}"
    elif [ "$(printf '%s\n' "$fns" | wc -l | tr -d ' ')" -ne 1 ]; then
        fail "B1 返回码 ${code} 分散于多函数（单点注入无法判别）: $(echo $fns)"
    fi
done
[ "$VIOLATIONS" -eq 0 ] && log_ok "B1 七个返回码各有用例（六门禁 + 未知）"

# ── B2: 用例在跑 ────────────────────────────────────────────
section "B2: cases built"
if grep -q 'test_canary.c' "$BUILD_P" || grep -q 'test_canary.c' "$BUILD_T"; then
    log_ok "B2 用例文件列入构建目标"
else
    fail "B2 用例文件未列入构建目标（永不编译）"
fi

# ── C1: 判别力（八用例七红一绿）─────────────────────────────
section "C1: mutation selfcheck (seven red, one green)"
if [ "${G38_SKIP_MUT:-0}" = "1" ]; then
    fail "C1 selfcheck 被跳过：跳过不是判定（fail-closed）"
elif [ ! -x "$MUT" ]; then
    fail "C1 反向用例脚本缺失或不可执行: ${MUT}"
else
    rc=0
    bash "$MUT" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        log_ok "C1 selfcheck 8/8 符合预期（七红一绿）"
    else
        fail "C1 selfcheck 未通过（exit ${rc}）：六门禁判别力不成立"
    fi
fi

# ── 裁决 ────────────────────────────────────────────────────
section "Verdict"
if [ "$VIOLATIONS" -gt 0 ]; then
    log_err "Gate 38 金丝雀六门禁违例 ${VIOLATIONS} 处"
    exit 1
fi
log_ok "Gate 38 六门禁可触发且判别力成立（未知 ≠ 通过）"
exit 0
