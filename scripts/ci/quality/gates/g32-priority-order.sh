#!/bin/bash
# Gate 32 违规优先级门禁（0.1.20 方案 §9.1 Gate 32 / §3.7l 第 6 项）
#
# 权威依据：
#   0.1.20-架构改进完善和自演化方案.md §3.7l：5 组冲突逐组断言
#     E-02 > E-05 > E-01 > E-03 > E-04；
#   §P0-3 重判表：grad_verifier.c 的优先级必须显式定序且唯一（Gate 32）。
#
# 为何判「表」而非「流水线」：E-02 命中即早退（Kahn 失败后无拓扑可遍历），
# 故真实流水线不可能产出「E-02 与其它位共存」的位图。若强行构造该位图去
# 断言，测的是虚构状态而非产品行为。故判据落在位图→单值的唯一映射函数上：
# 该函数是全部书写路径的 SSoT，梯序正确即所有可发生的组合正确。
#
# 四路取证（缺一路即无法宣称优先级成立）：
#   A1 单一真相   —— grad_err_rank 唯一定义、公开声明、被流水线唯一消费；
#                    不得残留内联 else-if 梯（两处真相即两套优先级）；
#   A2 梯序定死   —— 函数体内 E0x 字面量出现序恰为 E02/E05/E01/E03/E04，
#                    且以 AIRY_GRAD_OK 收尾（无位返回无错）；
#   B1 用例即判据 —— 两两组合真遍历、逐组比对高位者；边界（全位/零位）在场；
#   B2 用例在位   —— RUN_TEST 注册、所在文件在构建目标内、ctest 已登记；
#   D1 运行臂     —— 已构建树中 cognition_grad_tests 必须真实通过。
#
# 静态臂守「判据没有被写弱」，运行臂守「判据此刻成立」；两者缺一不可。
#
# 构建树位于源码区外（工程铁律 4.1.1）：由 AIRYRT_BUILD_ROOT 或
# QUALITY_GATE_BUILD_DIR 指定；两者皆空视为环境错误。
# 用法: [AIRYRT_BUILD_ROOT=<build>] g32-priority-order.sh
# 环境变量（selfcheck 注入用）：G32_ROOT
# 退出码: 0 = 通过；1 = 违例；2 = 环境错误
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# G32_ROOT 供 selfcheck 在快照树上施注单一突变；生产路径恒为脚本自身锚点。
PROJECT_ROOT="${G32_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
COG="${PROJECT_ROOT}/agent-workload/products/cognition"
IMPL="${COG}/src/grad/grad_verifier.c"
HDR="${COG}/src/grad/grad_verifier.h"
CASES="${COG}/tests/unit/test_grad_verifiers.c"
RUNNER="${COG}/tests/unit/test_grad.c"
BUILD="${COG}/CMakeLists.txt"
BUILD_ROOT="${AIRYRT_BUILD_ROOT:-${QUALITY_GATE_BUILD_DIR:-}}"

CASE_NAME="cognition_grad_tests"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'
log_ok() { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err() { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section() { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

violations=0
fail() {
    log_err "$*"
    violations=$((violations + 1))
}

# 取出映射函数体（自 grad_err_rank 定义起至其顶层闭合），供 A2 取证。
body() {
    awk '/^airy_grad_error_t grad_err_rank\(uint32_t errors\)$/ { on = 1 }
        on { print }
        on && /^}$/ { exit }' "$IMPL"
}

section "0.1.20 G32 violation priority gate"
for f in "$IMPL" "$HDR" "$CASES" "$RUNNER" "$BUILD"; do
    [ -f "$f" ] || { log_err "受审文件缺失: ${f}"; exit 2; }
done
[ -n "$BUILD_ROOT" ] || {
    log_err "build tree not specified: set AIRYRT_BUILD_ROOT or QUALITY_GATE_BUILD_DIR"
    exit 2
}
[ -d "$BUILD_ROOT" ] || { log_err "build tree not found: ${BUILD_ROOT}"; exit 2; }

# ── A1: 单一真相（唯一定义 + 唯一消费 + 无内联梯）──────────
section "A1: single source of truth"
DEFS="$(grep -cE '^airy_grad_error_t grad_err_rank\(uint32_t errors\)$' "$IMPL" || true)"
[ "$DEFS" = "1" ] || fail "A1 映射函数定义数 ${DEFS}（期望 1，重复定义即两套梯序）"
grep -qE 'airy_grad_error_t grad_err_rank\(uint32_t errors\);' "$HDR" \
    || fail "A1 映射函数未在 grad_verifier.h 声明（跨 TU 不可见即不可判）"
CALLS="$(grep -cF 'report->error = grad_err_rank(report->errors);' "$IMPL" || true)"
[ "$CALLS" = "1" ] \
    || fail "A1 流水线消费点 ${CALLS}（期望 1；0 即判据脱钩，>1 即多处赋值）"
INLINE="$(grep -c 'else if (report->errors &' "$IMPL" || true)"
[ "$INLINE" = "0" ] \
    || fail "A1 残留内联 else-if 梯 ${INLINE} 处（与映射函数构成两套真相）"

# ── A2: 梯序定死 ───────────────────────────────────────────
section "A2: ladder order"
B="$(body)"
if [ -z "$B" ]; then
    fail "A2 映射函数体不可取（A2 无判对象）"
else
    # 只取 return 语句：位测试出现在 if 条件里，return 才是梯序本体。
    RANKS="$(printf '%s\n' "$B" | grep -oE 'return AIRY_GRAD_E0[0-9]_[A-Z_]+;' \
        | sed -E 's/return AIRY_GRAD_(E0[0-9])_.*/\1/' | paste -sd' ' - || true)"
    EXPECT="E02 E05 E01 E03 E04"
    [ "$RANKS" = "$EXPECT" ] \
        || fail "A2 梯序 [${RANKS}] 与判据 [${EXPECT}] 不等（换位即优先级失守）"
    printf '%s\n' "$B" | grep -q 'return AIRY_GRAD_OK;' \
        || fail "A2 无位分支未返回 AIRY_GRAD_OK（空位图会被误判为违规）"
fi

# ── B1: 用例即判据（两两组合 + 边界）──────────────────────
section "B1: case encodes the ladder"
grep -qF 'void test_err_priority(void)' "$CASES" \
    || fail "B1 优先级用例缺席"
grep -qF 'for (int j = i + 1; j < 5; j++)' "$CASES" \
    || fail "B1 两两组合未真遍历（5 级梯需 10 组，缩程即漏检）"
grep -qF 'AIRY_GRAD_ERR_BIT(order[i]) | AIRY_GRAD_ERR_BIT(order[j])' "$CASES" \
    || fail "B1 组合位图未按位或构造（单比特测不出冲突）"
grep -qF 'grad_err_rank(pair) != order[i]' "$CASES" \
    || fail "B1 组合结果未与高位者比对"
grep -qF 'grad_err_rank(all) != AIRY_GRAD_E02_DEADLOCK' "$CASES" \
    || fail "B1 全位置位边界缺席（梯顶未定）"
grep -qF 'grad_err_rank(0) != AIRY_GRAD_OK' "$CASES" \
    || fail "B1 零位边界缺席（空位图语义未定）"

# ── B2: 用例在位（注册 + 构建 + ctest 登记）────────────────
section "B2: case registered and built"
grep -qF 'RUN_TEST(test_err_priority)' "$RUNNER" \
    || fail "B2 优先级用例未注册（永不运行）"
grep -q 'tests/unit/test_grad_verifiers\.c' "$BUILD" \
    || fail "B2 用例文件未列入构建目标（永不编译）"
grep -qE "add_test\(NAME ${CASE_NAME} COMMAND test_grad_strategy\)" "$BUILD" \
    || fail "B2 构建目标未登记 ctest 用例 ${CASE_NAME}"

# ── D1: 运行臂（已构建树中用例必须真实通过）────────────────
section "D1: runtime arm"
if ctest --test-dir "$BUILD_ROOT" -N -R "^${CASE_NAME}$" 2>/dev/null | grep -q "Test #"; then
    run_log="$(mktemp "${TMPDIR:-/tmp}/g32-run.XXXXXX")"
    rc=0
    ctest --test-dir "$BUILD_ROOT" -R "^${CASE_NAME}$" --output-on-failure \
        >"$run_log" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        log_ok "D1 ${CASE_NAME} 通过（10 组冲突由被测程序自证）"
    else
        fail "D1 ${CASE_NAME} 失败（rc=${rc}）"
        tail -12 "$run_log" | sed 's/^/        /'
    fi
    rm -f "$run_log"
else
    fail "D1 构建树未登记 ${CASE_NAME}（无运行臂则梯序结论不可验证）"
fi

# ── 裁决 ───────────────────────────────────────────────────
section "Verdict"
if [ "$violations" -gt 0 ]; then
    log_err "0.1.20 G32 violation priority gate FAILED (${violations} violation(s))"
    exit 1
fi
log_ok "0.1.20 G32 violation priority gate PASSED"
exit 0
