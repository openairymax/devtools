#!/bin/bash
# Gate 33 selfcheck 裁决往返门禁（0.1.20 方案 §9.1 Gate 33 / §9.3）
#
# 职责：g33-verdict-roundtrip.sh 的四路静态臂逐条"植入必红"——门禁恒绿等于
#   把「往返字节稳定」降级为一句口号，审计日志的可比对性将无法证伪。
#
# 用例（每例只在快照树上施注单一突变，红因归因唯一）：
#   T1 生产形态正向绿：真实源码树 + 真实构建树 rc=0
#   T2 快照形态正向绿：未突变快照 rc=0（证明后续红因来自突变而非隔离）
#   T3 往返次数缩水：100 → 1 → rc=1 且 B1 点名
#   T4 用例注销：删 RUN_TEST 注册 → rc=1 且 B2 点名
#   T5 用例脱构：测试源集删去 test_grad_patch.c → rc=1 且 B2 点名
#   T6 空值省键失守：删 opinion 空串守卫 → rc=1 且 A3 点名
#   T7 规范形失守：写出键改名 → rc=1 且 A2 点名
#   T8 降级失守：无 cJSON 分支改返 SUCCESS → rc=1 且 A1 点名
#   T9 出参失守：删 *out_json = NULL → rc=1 且 A4 点名
#   T10 受审文件缺席：rc=2（不得静默跳过）
#   T11 构建树未指定：rc=2（fail-closed）
#
# 用法: selfcheck/gate-33.sh
# 前置: AIRYRT_BUILD_ROOT 指向含 cognition_grad_tests 的构建树
# 退出码: 0 = 全部断言符合预期；1 = 判定矩阵失守；2 = 前置缺席
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AHUB="$(cd "$SCRIPT_DIR/../../../../../.." && pwd)"
GATE="${GATES_DIR}/g33-verdict-roundtrip.sh"

SRC_COG="${AHUB}/agent-workload/products/cognition"
SRC_IMPL="${SRC_COG}/src/grad/grad_verdict.c"
SRC_HDR="${SRC_COG}/src/grad/grad_internal.h"
SRC_CASES="${SRC_COG}/tests/unit/test_grad_patch.c"
SRC_RUNNER="${SRC_COG}/tests/unit/test_grad.c"
SRC_BUILD="${SRC_COG}/CMakeLists.txt"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'
log_ok() { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err() { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section() { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

expect_rc() {
    local name="$1" want="$2" rc="$3"
    if [ "$rc" -eq "$want" ]; then
        log_ok "${name}: exit ${rc}（期望 ${want}）"
    else
        log_err "${name}: exit ${rc}，期望 ${want}"
        exit 1
    fi
}

BUILD="${AIRYRT_BUILD_ROOT:-${QUALITY_GATE_BUILD_DIR:-}}"
if [ -z "$BUILD" ] || [ ! -d "$BUILD" ]; then
    log_err "前置缺席：AIRYRT_BUILD_ROOT/QUALITY_GATE_BUILD_DIR 未指向构建树"
    exit 2
fi

for f in "$SRC_IMPL" "$SRC_HDR" "$SRC_CASES" "$SRC_RUNNER" "$SRC_BUILD"; do
    [ -f "$f" ] || { log_err "受审源文件缺席: ${f}"; exit 2; }
done

# 快照树：仅复制受审五件，路径与生产同构。
make_base() {
    local root="$1" dir
    dir="$root/agent-workload/products/cognition"
    mkdir -p "$dir/src/grad" "$dir/tests/unit"
    cp "$SRC_IMPL" "$dir/src/grad/grad_verdict.c"
    cp "$SRC_HDR" "$dir/src/grad/grad_internal.h"
    cp "$SRC_CASES" "$dir/tests/unit/test_grad_patch.c"
    cp "$SRC_RUNNER" "$dir/tests/unit/test_grad.c"
    cp "$SRC_BUILD" "$dir/CMakeLists.txt"
}

run_iso() {
    G33_ROOT="$1" AIRYRT_BUILD_ROOT="$BUILD" bash "$GATE"
}

expect_red() {
    local name="$1" marker="$2" root="$3" out rc
    out="$(run_iso "$root" 2>&1)" && rc=0 || rc=$?
    expect_rc "$name" 1 "$rc"
    printf '%s\n' "$out" | grep -q "$marker" \
        || { log_err "${name}: 未由 ${marker} 点名"; printf '%s\n' "$out" | tail -6; exit 1; }
    log_ok "${name}: ${marker} 点名成立"
}

# 突变后必须真的改变文件（sed 未命中 = selfcheck 自身失效，fail-closed）。
mutate() {
    local file="$1" expr="$2" before
    before="$(cksum <"$file")"
    sed -i "$expr" "$file"
    [ "$before" != "$(cksum <"$file")" ] || { log_err "突变未命中: ${expr}"; exit 1; }
}

# ── T1: 生产形态正向绿 ──────────────────────────────────────
section "T1: production tree green"
rc=0
run_iso "$AHUB" >/dev/null 2>&1 || rc=$?
expect_rc "T1 production audit" 0 "$rc"

make_base "$TMP/base"

# ── T2: 快照形态正向绿 ──────────────────────────────────────
section "T2: snapshot control arm"
rc=0
run_iso "$TMP/base" >/dev/null 2>&1 || rc=$?
expect_rc "T2 snapshot control" 0 "$rc"

# ── T3: 往返次数缩水 ────────────────────────────────────────
section "T3: roundtrip count shrinkage must map red"
cp -a "$TMP/base" "$TMP/t3"
mutate "$TMP/t3/agent-workload/products/cognition/tests/unit/test_grad_patch.c" \
    's/i < 100/i < 1/'
expect_red "T3 roundtrip count" "B1:" "$TMP/t3"

# ── T4: 用例注销 ────────────────────────────────────────────
section "T4: unregistered case must map red"
cp -a "$TMP/base" "$TMP/t4"
mutate "$TMP/t4/agent-workload/products/cognition/tests/unit/test_grad.c" \
    '/RUN_TEST(test_verdict_roundtrip);/d'
expect_red "T4 case unregistered" "B2:" "$TMP/t4"

# ── T5: 用例脱构 ────────────────────────────────────────────
section "T5: case dropped from build must map red"
cp -a "$TMP/base" "$TMP/t5"
mutate "$TMP/t5/agent-workload/products/cognition/CMakeLists.txt" \
    '/tests\/unit\/test_grad_patch\.c/d'
expect_red "T5 case unwired" "B2:" "$TMP/t5"

# ── T6: 空值省键失守 ────────────────────────────────────────
section "T6: missing empty-value guard must map red"
cp -a "$TMP/base" "$TMP/t6"
mutate "$TMP/t6/agent-workload/products/cognition/src/grad/grad_verdict.c" \
    's/v->opinion\[0\] &&/(void)0;/'
expect_red "T6 opinion guard" "A3:" "$TMP/t6"

# ── T7: 规范形失守 ──────────────────────────────────────────
section "T7: renamed canonical key must map red"
cp -a "$TMP/base" "$TMP/t7"
mutate "$TMP/t7/agent-workload/products/cognition/src/grad/grad_verdict.c" \
    '/^airy_err_t grad_verdict_to_json(/,/^}$/ s/"verdict"/"verdict_x"/'
expect_red "T7 canonical key" "A2:" "$TMP/t7"

# ── T8: 无 cJSON 降级失守 ───────────────────────────────────
section "T8: degraded emit must map red"
cp -a "$TMP/base" "$TMP/t8"
mutate "$TMP/t8/agent-workload/products/cognition/src/grad/grad_verdict.c" \
    '/verdict serialization requires cJSON/{n;s/return AIRY_ESERVICE;/return AIRY_SUCCESS;/}'
expect_red "T8 fail-closed emit" "A1:" "$TMP/t8"

# ── T9: 出参契约失守 ────────────────────────────────────────
section "T9: out-parameter reset removed must map red"
cp -a "$TMP/base" "$TMP/t9"
mutate "$TMP/t9/agent-workload/products/cognition/src/grad/grad_verdict.c" \
    '/^airy_err_t grad_verdict_to_json(/,/^}$/ { /^[[:space:]]*\*out_json = NULL;/d }'
expect_red "T9 out-param reset" "A4:" "$TMP/t9"

# ── T10: 受审文件缺席 → rc=2 ────────────────────────────────
section "T10: missing audited file = env error"
cp -a "$TMP/base" "$TMP/t10"
rm -f "$TMP/t10/agent-workload/products/cognition/src/grad/grad_verdict.c"
rc=0
run_iso "$TMP/t10" >/dev/null 2>&1 || rc=$?
expect_rc "T10 audited file missing" 2 "$rc"

# ── T11: 构建树未指定 → rc=2 ────────────────────────────────
section "T11: unspecified build tree = env error"
rc=0
env -u AIRYRT_BUILD_ROOT -u QUALITY_GATE_BUILD_DIR bash "$GATE" >/dev/null 2>&1 || rc=$?
expect_rc "T11 build tree missing" 2 "$rc"

section "Gate 33 selfcheck verdict"
log_ok "全部断言符合预期（T1-T11）"
exit 0
