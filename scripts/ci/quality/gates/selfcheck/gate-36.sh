#!/bin/bash
# Gate 36 selfcheck 三终态完备（0.1.20 方案 §9.1 Gate 36）
#
# 职责：验证 g36-terminal-gate.sh 的判定矩阵——三终态完备的执法器
#   自身必须可证伪：每一条断言都要有"植入必红"的反向用例（T4 纪律）。
#
# 用例：
#   T1 生产形态正向绿：真实源码树全链 rc=0
#   T2 隔离全绿：真实源快照到 tmp 根 → rc=0（基线语义与生产一致）
#   T3 未知并入成功：轻载用例追加 converged 断言 → rc=1（B2 点名）
#   T4 未知零用例：删去 no_llm 断言 → rc=1（B1 点名）
#   T5 用例未注册：删去 RUN_TEST 注册 → rc=1（B3 点名）
#   T6 新增未分类终态：枚举追加值 → rc=1（A1 点名）
#   T7 环境错误 fail-closed：受审文件缺席 → rc=2（不得静默跳过）
#   T8 用例未入构建：删去构建目标条目 → rc=1（B3 点名）
#
# 用法: selfcheck/gate-36.sh
# 退出码: 0 = 全部断言符合预期；1 = 判定矩阵失守
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../../.." && pwd)"
GATE="${GATES_DIR}/g36-terminal-gate.sh"

AW="${PROJECT_ROOT}/agent-workload"
SRC_HDR="${AW}/agentrt/atoms/coreloopthree/include/grad.h"
SRC_PROD="${AW}/products/cognition/src/grad/grad_run.c"
SRC_CASES="${AW}/products/cognition/tests/unit/test_grad_run.c"
SRC_RUNNER="${AW}/products/cognition/tests/unit/test_grad.c"
SRC_BUILD="${AW}/products/cognition/CMakeLists.txt"
SRC_EVENT="${AW}/agentrt/atoms/coreloopthree/src/cognition/think/engine_process_grad.c"

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

# 隔离根构造器：把真实源快照进 tmp 树（基线语义与生产一致，
# 每个用例只在快照上做单一变异，保证红因归因唯一）
make_base() {
    local root="$1"
    mkdir -p "$root/agent-workload/agentrt/atoms/coreloopthree/include" \
             "$root/agent-workload/agentrt/atoms/coreloopthree/src/cognition/think" \
             "$root/agent-workload/products/cognition/src/grad" \
             "$root/agent-workload/products/cognition/tests/unit"
    cp "$SRC_HDR" "$root/agent-workload/agentrt/atoms/coreloopthree/include/grad.h"
    cp "$SRC_EVENT" "$root/agent-workload/agentrt/atoms/coreloopthree/src/cognition/think/engine_process_grad.c"
    cp "$SRC_PROD" "$root/agent-workload/products/cognition/src/grad/grad_run.c"
    cp "$SRC_CASES" "$root/agent-workload/products/cognition/tests/unit/test_grad_run.c"
    cp "$SRC_RUNNER" "$root/agent-workload/products/cognition/tests/unit/test_grad.c"
    cp "$SRC_BUILD" "$root/agent-workload/products/cognition/CMakeLists.txt"
}

run_iso() {
    G36_ROOT="$1" bash "$GATE"
}

# 变异：在指定用例函数内植入一行断言（函数级归属由 gate 侧 awk 判定）
inject_assert() {
    local file="$1" fn="$2" status="$3"
    sed -i "/^void ${fn}(void)\$/a\\
    TEST_CHECK(oc.stats.status == ${status}, \"injected\");" "$file"
}

# 反向用例通用判定：必须 rc=1 且由预期断点点名
expect_red() {
    local name="$1" marker="$2" root="$3" out rc
    out="$(run_iso "$root" 2>&1)" && rc=0 || rc=$?
    expect_rc "$name" 1 "$rc"
    printf '%s\n' "$out" | grep -q "${marker}" \
        || { log_err "${name}: 未由 ${marker} 点名"; exit 1; }
    log_ok "${name}: ${marker} 点名成立"
}

for f in "$SRC_HDR" "$SRC_PROD" "$SRC_CASES" "$SRC_RUNNER" "$SRC_BUILD" "$SRC_EVENT"; do
    [ -f "$f" ] || { log_err "受审源文件缺席: ${f}"; exit 1; }
done

# ── T1: 生产形态正向绿 ──────────────────────────────────────
section "T1: production tree green"
rc=0
bash "$GATE" >/dev/null 2>&1 || rc=$?
expect_rc "T1 production audit" 0 "$rc"

# ── T2: 隔离全绿（真实源快照）───────────────────────────────
section "T2: isolated snapshot green"
make_base "$TMP/base"
rc=0
run_iso "$TMP/base" >/dev/null 2>&1 || rc=$?
expect_rc "T2 isolated green" 0 "$rc"

# ── T3: 未知并入成功 → B2 点名 ──────────────────────────────
section "T3: unknown merged into success must map red"
cp -a "$TMP/base" "$TMP/t3"
inject_assert "$TMP/t3/agent-workload/products/cognition/tests/unit/test_grad_run.c" \
    test_run_light GRAD_STATUS_CONVERGED
expect_red "T3 merged status" "B2" "$TMP/t3"

# ── T4: 未知态零用例 → B1 点名 ──────────────────────────────
section "T4: missing unknown case must map red"
cp -a "$TMP/base" "$TMP/t4"
sed -i '/stats\.status == GRAD_STATUS_NO_LLM/d' \
    "$TMP/t4/agent-workload/products/cognition/tests/unit/test_grad_run.c"
expect_red "T4 no_llm case gone" "B1" "$TMP/t4"

# ── T5: 用例未注册 → B3 点名 ────────────────────────────────
section "T5: unregistered case must map red"
cp -a "$TMP/base" "$TMP/t5"
sed -i '/RUN_TEST(test_run_light)/d' \
    "$TMP/t5/agent-workload/products/cognition/tests/unit/test_grad.c"
expect_red "T5 case unregistered" "B3" "$TMP/t5"

# ── T6: 新增未分类终态 → A1 点名（封闭世界）─────────────────
section "T6: unclassified new status must map red"
cp -a "$TMP/base" "$TMP/t6"
sed -i 's/^} grad_status_e;$/    GRAD_STATUS_MAYBE = 7\n} grad_status_e;/' \
    "$TMP/t6/agent-workload/agentrt/atoms/coreloopthree/include/grad.h"
expect_red "T6 unclassified status" "A1" "$TMP/t6"

# ── T7: 受审文件缺席 → rc=2（fail-closed）───────────────────
section "T7: missing audited file = env error"
cp -a "$TMP/base" "$TMP/t7"
rm -f "$TMP/t7/agent-workload/agentrt/atoms/coreloopthree/src/cognition/think/engine_process_grad.c"
rc=0
run_iso "$TMP/t7" >/dev/null 2>&1 || rc=$?
expect_rc "T7 audited file missing" 2 "$rc"

# ── T8: 用例未入构建目标 → B3 点名 ──────────────────────────
section "T8: case file not built must map red"
cp -a "$TMP/base" "$TMP/t8"
sed -i '/tests\/unit\/test_grad_run.c/d' \
    "$TMP/t8/agent-workload/products/cognition/CMakeLists.txt"
expect_red "T8 case not built" "B3" "$TMP/t8"

section "Gate 36 selfcheck verdict"
log_ok "全部断言符合预期（T1-T8）"
exit 0
