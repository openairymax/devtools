#!/bin/bash
# Gate 34 非法计划 schema 拒绝门禁（0.1.20 方案 §9.1 Gate 34 / §3.7l 第 8 项）
#
# 权威依据：
#   0.1.20-架构改进完善和自演化方案.md §3.7l：12 类非法计划全拒；
#   §P0-3 重判表：GRAD 计划 schema v1 的拒绝域必须可枚举、可定位。
#
# 为何判「原因码」而非「12 条 JSON」：plan_schema.c 的拒绝域本体就是那 12
# 个互异 reason 码（type/missing/pattern/range/enum/dup/missing_dep/
# self_dep/format/producer_missing/producer_not_in_depends/missing_ref）。
# 原因码是实现的分类学，按它逐类取证才不会虚构代码里不存在的拒绝域。而
# 「拒而不定位」与「拒绝」同样有害：运维只看到「计划被拒」，日志里没有
# 可指认的约束。故用例逐类断言 field+reason 双定位，而不只断言返回码。
#
# 四路取证（缺一路即无法宣称拒绝域成立）：
#   A1 十二类齐备 —— 12 个 reason 码在实现中各有一处定位写入；
#   A2 拒绝即止   —— 每处定位后立即返回（false / AIRY_EINVAL），不得
#                    静默修复后继续（静默修正会把非法计划变成合法计划）；
#   A3 定位不漏   —— 非对象节点单独定位：否则所有字段「缺席」，拒绝退化
#                    成无定位的整份拒绝；
#   B1 用例即判据 —— 表驱动恰 12 行、逐行比对 field+reason、非对象节点在案；
#   B2 用例在位   —— RUN_TEST 注册、所在文件在构建目标内、ctest 已登记；
#   D1 运行臂     —— 已构建树中 cognition_grad_tests 必须真实通过。
#
# 静态臂守「判据没有被写弱」，运行臂守「判据此刻成立」；两者缺一不可。
#
# 构建树位于源码区外（工程铁律 4.1.1）：由 AIRYRT_BUILD_ROOT 或
# QUALITY_GATE_BUILD_DIR 指定；两者皆空视为环境错误。
# 用法: [AIRYRT_BUILD_ROOT=<build>] g34-plan-schema-reject.sh
# 环境变量（selfcheck 注入用）：G34_ROOT
# 退出码: 0 = 通过；1 = 违例；2 = 环境错误
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# G34_ROOT 供 selfcheck 在快照树上施注单一突变；生产路径恒为脚本自身锚点。
PROJECT_ROOT="${G34_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
COG="${PROJECT_ROOT}/agent-workload/products/cognition"
IMPL="${COG}/src/grad/plan_schema.c"
HDR="${COG}/src/grad/plan_schema.h"
CASES="${COG}/tests/unit/test_grad_schema.c"
RUNNER="${COG}/tests/unit/test_grad.c"
BUILD="${COG}/CMakeLists.txt"
BUILD_ROOT="${AIRYRT_BUILD_ROOT:-${QUALITY_GATE_BUILD_DIR:-}}"

CASE_NAME="cognition_grad_tests"

# 12 类拒绝原因码（与 plan_schema.c 的实现分类学一一对应）。
REASONS="type missing pattern range enum dup missing_dep self_dep format
producer_missing producer_not_in_depends missing_ref"

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

section "0.1.20 G34 plan schema rejection gate"
for f in "$IMPL" "$HDR" "$CASES" "$RUNNER" "$BUILD"; do
    [ -f "$f" ] || { log_err "受审文件缺失: ${f}"; exit 2; }
done
[ -n "$BUILD_ROOT" ] || {
    log_err "build tree not specified: set AIRYRT_BUILD_ROOT or QUALITY_GATE_BUILD_DIR"
    exit 2
}
[ -d "$BUILD_ROOT" ] || { log_err "build tree not found: ${BUILD_ROOT}"; exit 2; }

# ── A1: 十二类齐备（每码各有一处定位写入）──────────────────
section "A1: twelve rejection classes"
for r in $REASONS; do
    # 原因码占据 grad_serr_set 的末参位置；字段名与原因码无重名，故不误判。
    grep -qE ", \"${r}\"\);" "$IMPL" \
        || fail "A1 原因码 ${r} 无定位写入（该类拒绝退化为无原因）"
done

# ── A2: 拒绝即止（定位后立刻返回，不得静默修复）──────────────
section "A2: locate then refuse"
ORPHAN="$(awk '
    /grad_serr_set\(/ && /\);/ { pend = 1; next }
    pend {
        pend = 0
        if ($0 !~ /^[[:space:]]*return (false|AIRY_EINVAL);[[:space:]]*$/)
            printf "%d:%s\n", NR, $0
    }
' "$IMPL")"
[ -z "$ORPHAN" ] || {
    fail "A2 存在定位后未立即返回的路径（静默修复会把非法计划变合法）"
    printf '%s\n' "$ORPHAN" | head -3 | sed 's/^/        /'
}

# ── A3: 非对象节点单独定位 ─────────────────────────────────
section "A3: non-object node located"
grep -qF 'if (!cJSON_IsObject(nd))' "$IMPL" \
    || fail "A3 节点循环未区分非对象节点（字段全缺席 → 拒绝无定位）"
grep -qF 'grad_serr_set(err, i, "node", "type");' "$IMPL" \
    || fail "A3 非对象节点未回填 node/type（日志无法指认是哪一条）"

# ── B1: 用例即判据（12 行表 + 双定位 + 非对象节点）──────────
section "B1: case encodes the taxonomy"
grep -qF 'void test_plan_reject(void)' "$CASES" \
    || fail "B1 拒绝分类用例缺席"
ROWS="$(awk '/static const bad_plan_t cases\[\] = \{/ { on = 1; next }
    on && /^[[:space:]]*\};/ { exit }
    on && /^[[:space:]]*\{"[a-z_]+", "[a-z_]+",/ { c++ }
    END { print c + 0 }' "$CASES")"
[ "$ROWS" = "12" ] \
    || fail "B1 用例表 ${ROWS} 行（期望 12，缩表即漏检某类拒绝）"
grep -qF 'strcmp(err.field, cases[k].field) != 0' "$CASES" \
    || fail "B1 未比对 field（只判返回码会把语义拒绝与解析失败混为一谈）"
grep -qF 'strcmp(err.reason, cases[k].reason) != 0' "$CASES" \
    || fail "B1 未比对 reason（同类拒绝无法归因）"
grep -qF 'rc != AIRY_EINVAL' "$CASES" \
    || fail "B1 未断言拒绝返回码"
grep -qF '"{\"nodes\":[\"x\"]}"' "$CASES" \
    || fail "B1 非对象节点用例缺席（A3 的根因修复无回归）"

# ── B2: 用例在位（注册 + 构建 + ctest 登记）────────────────
section "B2: case registered and built"
grep -qF 'RUN_TEST(test_plan_reject)' "$RUNNER" \
    || fail "B2 拒绝分类用例未注册（永不运行）"
grep -q 'tests/unit/test_grad_schema\.c' "$BUILD" \
    || fail "B2 用例文件未列入构建目标（永不编译）"
grep -qE "add_test\(NAME ${CASE_NAME} COMMAND test_grad_strategy\)" "$BUILD" \
    || fail "B2 构建目标未登记 ctest 用例 ${CASE_NAME}"

# ── D1: 运行臂（已构建树中用例必须真实通过）────────────────
section "D1: runtime arm"
if ctest --test-dir "$BUILD_ROOT" -N -R "^${CASE_NAME}$" 2>/dev/null | grep -q "Test #"; then
    run_log="$(mktemp "${TMPDIR:-/tmp}/g34-run.XXXXXX")"
    rc=0
    ctest --test-dir "$BUILD_ROOT" -R "^${CASE_NAME}$" --output-on-failure \
        >"$run_log" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        log_ok "D1 ${CASE_NAME} 通过（12 类拒绝由被测程序自证）"
    else
        fail "D1 ${CASE_NAME} 失败（rc=${rc}）"
        tail -12 "$run_log" | sed 's/^/        /'
    fi
    rm -f "$run_log"
else
    fail "D1 构建树未登记 ${CASE_NAME}（无运行臂则拒绝域结论不可验证）"
fi

# ── 裁决 ───────────────────────────────────────────────────
section "Verdict"
if [ "$violations" -gt 0 ]; then
    log_err "0.1.20 G34 plan schema rejection gate FAILED (${violations} violation(s))"
    exit 1
fi
log_ok "0.1.20 G34 plan schema rejection gate PASSED"
exit 0
