#!/bin/bash
# Gate 33 裁决往返门禁（0.1.20 方案 §9.1 Gate 33 / §3.7l 第 7 项）
#
# 权威依据：
#   0.1.20-架构改进完善和自演化方案.md §9.1 Gate 33：同一输入往返 100 次，
#     裁决结果字节级一致。
#
# 四路取证（缺一路即无法宣称往返成立）：
#   A1 写出侧在场 —— grad_verdict_to_json 有唯一定义与公开声明；无 cJSON 时
#                    返回 AIRY_ESERVICE（不得产出无法再解析的近似 JSON）；
#   A2 规范形定序 —— 写出的键序恰为 verdict/confidence/e04/opinion/
#                    defects/affected_scope，多一键少一键即红；
#   A3 空值省键   —— opinion 空串、defects/scope 空数组不落键（否则空数组
#                    与缺键两种形态并存，往返不可能字节稳定）；
#   A4 出参契约   —— out_json 先置 NULL 再校验 v（失败态不留悬垂指针）；
#   B1 用例即判据 —— 往返用例真迭代 100 次、与首轮规范形逐字节比对、且做
#                    字段级深比较（只比长度或只比首尾都是假往返）；
#   B2 用例在位   —— 用例经 RUN_TEST 注册、所在文件在构建目标内、ctest 已
#                    登记（未注册的用例永不运行，等同虚设）；
#   D1 运行臂     —— 已构建树中 cognition_grad_tests 必须真实通过。
#
# 静态臂守「判据没有被写弱」，运行臂守「判据此刻成立」；两者缺一不可。
#
# 构建树位于源码区外（工程铁律 4.1.1）：由 AIRYRT_BUILD_ROOT 或
# QUALITY_GATE_BUILD_DIR 指定；两者皆空视为环境错误。
# 用法: [AIRYRT_BUILD_ROOT=<build>] g33-verdict-roundtrip.sh
# 环境变量（selfcheck 注入用）：G33_ROOT
# 退出码: 0 = 通过；1 = 违例；2 = 环境错误
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# G33_ROOT 供 selfcheck 在快照树上施注单一突变；生产路径恒为脚本自身锚点。
PROJECT_ROOT="${G33_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
COG="${PROJECT_ROOT}/agent-workload/products/cognition"
IMPL="${COG}/src/grad/grad_verdict.c"
HDR="${COG}/src/grad/grad_internal.h"
CASES="${COG}/tests/unit/test_grad_patch.c"
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

# 取出写出函数体（自 grad_verdict_to_json 定义起至其顶层闭合），供 A1-A4 共用。
body() {
    awk '/^airy_err_t grad_verdict_to_json\(/ { on = 1 }
        on { print }
        on && /^}$/ { exit }' "$IMPL"
}

section "0.1.20 G33 verdict roundtrip gate"
for f in "$IMPL" "$HDR" "$CASES" "$RUNNER" "$BUILD"; do
    [ -f "$f" ] || { log_err "受审文件缺失: ${f}"; exit 2; }
done
[ -n "$BUILD_ROOT" ] || {
    log_err "build tree not specified: set AIRYRT_BUILD_ROOT or QUALITY_GATE_BUILD_DIR"
    exit 2
}
[ -d "$BUILD_ROOT" ] || { log_err "build tree not found: ${BUILD_ROOT}"; exit 2; }

# ── A1: 写出侧在场且唯一 ───────────────────────────────────
section "A1: serializer present and fail-closed"
DEFS="$(grep -cE '^airy_err_t grad_verdict_to_json\(' "$IMPL" || true)"
[ "$DEFS" = "1" ] || fail "A1 写出侧定义数 ${DEFS}（期望 1，重复定义即两套规范形）"
grep -qE 'grad_verdict_to_json\(const grad_verdict_t \*v, char \*\*out_json\);' "$HDR" \
    || fail "A1 写出侧未在 grad_internal.h 声明"
FB="$(body | awk '/^#else/ { on = 1 } on && /^#endif/ { exit } on { print }')"
printf '%s\n' "$FB" | grep -q 'return AIRY_ESERVICE;' \
    || fail "A1 无 cJSON 分支未 fail-closed（须返回 AIRY_ESERVICE，不得近似写出）"

# ── A2: 规范形字段序 ───────────────────────────────────────
section "A2: canonical key order"
KEYS="$(body | grep -oE '"[a-z0-9_]+"' | tr -d '"' | paste -sd' ' - || true)"
EXPECT="verdict confidence e04 opinion defects affected_scope"
[ "$KEYS" = "$EXPECT" ] \
    || fail "A2 写出的键序 [${KEYS}] 与规范形 [${EXPECT}] 不等"

# ── A3: 空值省键 ───────────────────────────────────────────
section "A3: empty values omitted"
B="$(body)"
printf '%s\n' "$B" | grep -q 'v->opinion\[0\] *&&' \
    || fail "A3 opinion 未做空串判定（空 opinion 会落键，产生第二种形态）"
printf '%s\n' "$B" | grep -q 'v->defect_count *> *0' \
    || fail "A3 defects 未做非空判定（空数组会落键）"
printf '%s\n' "$B" | grep -q 'v->scope_count *> *0' \
    || fail "A3 affected_scope 未做非空判定（空数组会落键）"

# ── A4: 出参契约（先置 NULL 再校验入参）────────────────────
section "A4: out-parameter contract"
L_OUT=$(printf '%s\n' "$B" | grep -n 'if (!out_json)' | head -1 | cut -d: -f1 || true)
L_NUL=$(printf '%s\n' "$B" | grep -n '^\s*\*out_json = NULL;' | head -1 | cut -d: -f1 || true)
L_V=$(printf '%s\n' "$B" | grep -n 'if (!v)' | head -1 | cut -d: -f1 || true)
if [ -z "$L_OUT" ] || [ -z "$L_NUL" ] || [ -z "$L_V" ]; then
    fail "A4 出参守卫生效顺序不可判（缺少 !out_json / *out_json=NULL / !v 之一）"
elif [ "$L_OUT" -lt "$L_NUL" ] && [ "$L_NUL" -lt "$L_V" ]; then
    log_ok "A4 out_json 先置 NULL（${L_NUL}）再校验裁决（${L_V}）"
else
    fail "A4 顺序错误：!out_json=${L_OUT} 置空=${L_NUL} 校验 v=${L_V}（失败态会留悬垂值）"
fi
printf '%s\n' "$B" | grep -q 'if (!v || !out_json)' \
    && fail "A4 合并判定使失败态无法置空 out_json"

# ── B1: 用例即判据（100 次 + 字节比对 + 字段深比较）────────
section "B1: case encodes 100 roundtrips"
grep -q 'void test_verdict_roundtrip(void)' "$CASES" \
    || fail "B1 往返用例缺席"
grep -qE 'i < 100' "$CASES" \
    || fail "B1 往返次数不足 100（少一次就不是方案判据）"
grep -q 'strcmp(next, canon)' "$CASES" \
    || fail "B1 未与首轮规范形逐字节比对"
grep -q 'vd_same(&v, &base)' "$CASES" \
    || fail "B1 未做字段级深比较（仅字节比对上不了语义漂移）"
N_CORPUS=$(grep -c 'vd_rt_one(' "$CASES" || true)
[ "$N_CORPUS" -ge 4 ] \
    || fail "B1 语料数 ${N_CORPUS}（期望 ≥4：函数体 1 + 三份语料）"

# ── B2: 用例在位（注册 + 构建 + ctest 登记）────────────────
section "B2: case registered and built"
grep -q 'RUN_TEST(test_verdict_roundtrip)' "$RUNNER" \
    || fail "B2 用例未注册（永不运行）"
grep -q 'tests/unit/test_grad_patch\.c' "$BUILD" \
    || fail "B2 用例文件未列入构建目标（永不编译）"
grep -qE "add_test\(NAME ${CASE_NAME} COMMAND test_grad_strategy\)" "$BUILD" \
    || fail "B2 构建目标未登记 ctest 用例 ${CASE_NAME}"

# ── D1: 运行臂（已构建树中用例必须真实通过）────────────────
section "D1: runtime arm"
if ctest --test-dir "$BUILD_ROOT" -N -R "^${CASE_NAME}$" 2>/dev/null | grep -q "Test #"; then
    run_log="$(mktemp "${TMPDIR:-/tmp}/g33-run.XXXXXX")"
    rc=0
    ctest --test-dir "$BUILD_ROOT" -R "^${CASE_NAME}$" --output-on-failure \
        >"$run_log" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        log_ok "D1 ${CASE_NAME} 通过（100 次往返由被测程序自证）"
    else
        fail "D1 ${CASE_NAME} 失败（rc=${rc}）"
        tail -12 "$run_log" | sed 's/^/        /'
    fi
    rm -f "$run_log"
else
    fail "D1 构建树未登记 ${CASE_NAME}（无运行臂则往返结论不可验证）"
fi

# ── 裁决 ───────────────────────────────────────────────────
section "Verdict"
if [ "$violations" -gt 0 ]; then
    log_err "0.1.20 G33 verdict roundtrip gate FAILED (${violations} violation(s))"
    exit 1
fi
log_ok "0.1.20 G33 verdict roundtrip gate PASSED"
exit 0
