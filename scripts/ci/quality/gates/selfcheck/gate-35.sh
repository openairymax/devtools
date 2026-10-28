#!/bin/bash
# Gate 35 selfcheck 部分失败语义门禁（0.1.20 方案 §9.1 Gate 35 / §9.3）
#
# 职责：g35-partial-failure.sh 的判定矩阵逐条"植入必红"——若门禁恒绿，
#   「5 种部分失败组合必须指明哪一步失败」就退化为一句口号，日后删掉
#   某个阶段的赋值或某条 stage 断言也无人察觉。
#
# 用例（每例只在快照树上施注单一突变，红因归因唯一）：
#   T1  生产形态正向绿：真实源码树 + 真实构建树 rc=0
#   T2  快照形态正向绿：未突变快照 rc=0（证明后续红因来自突变而非隔离）
#   T3  单例丢 stage 断言：删 no_llm 的 stage 行 → rc=1 且 B2 点名
#   T4  全量丢 stage 断言：删去所有 stage 断言 → rc=1 且 B1 点名
#   T5  阶段零赋值：删 coordinator 的 verify 赋值 → rc=1 且 A2 点名
#   T6  出口兜底缺席：删未收敛兜底两行 → rc=1 且 A2 点名
#   T7  新增未分类阶段：枚举追加一值 → rc=1 且 A1 点名
#   T8  组合用例注销：删 RUN_TEST 注册 → rc=1 且 B3 点名
#   T9  事件丢归因：删事件中的 stage 字段 → rc=1 且 D1 点名
#   T10 trace 丢归因：删 trace 格式串的 stage 键 → rc=1 且 D1 点名
#   T11 受审文件缺席：rc=2（不得静默跳过）
#   T12 构建树未指定：rc=2（fail-closed）
#   T13 构建树无用例登记：rc=1 且 D2 点名（无运行臂即不可验证）
#
# 用法: selfcheck/gate-35.sh
# 前置: AIRYRT_BUILD_ROOT 指向含 cognition_grad_tests 的构建树
# 退出码: 0 = 全部断言符合预期；1 = 判定矩阵失守；2 = 前置缺席
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AHUB="$(cd "$SCRIPT_DIR/../../../../../.." && pwd)"
GATE="${GATES_DIR}/g35-partial-failure.sh"

AW="${AHUB}/agent-workload"
SRC_HDR="${AW}/agentrt/atoms/coreloopthree/include/grad.h"
SRC_RUN="${AW}/products/cognition/src/grad/grad_run.c"
SRC_COORD="${AW}/products/cognition/src/grad/grad_coordinator.c"
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

BUILD="${AIRYRT_BUILD_ROOT:-${QUALITY_GATE_BUILD_DIR:-}}"
if [ -z "$BUILD" ] || [ ! -d "$BUILD" ]; then
    log_err "前置缺席：AIRYRT_BUILD_ROOT/QUALITY_GATE_BUILD_DIR 未指向构建树"
    exit 2
fi

for f in "$SRC_HDR" "$SRC_RUN" "$SRC_COORD" "$SRC_CASES" "$SRC_RUNNER" \
         "$SRC_BUILD" "$SRC_EVENT"; do
    [ -f "$f" ] || { log_err "受审源文件缺席: ${f}"; exit 2; }
done

# 快照树：仅复制受审七件，路径与生产同构。
BASE_REL="agent-workload"
make_base() {
    local root="$1"
    mkdir -p "$root/$BASE_REL/agentrt/atoms/coreloopthree/include" \
             "$root/$BASE_REL/agentrt/atoms/coreloopthree/src/cognition/think" \
             "$root/$BASE_REL/products/cognition/src/grad" \
             "$root/$BASE_REL/products/cognition/tests/unit"
    cp "$SRC_HDR" "$root/$BASE_REL/agentrt/atoms/coreloopthree/include/grad.h"
    cp "$SRC_EVENT" "$root/$BASE_REL/agentrt/atoms/coreloopthree/src/cognition/think/engine_process_grad.c"
    cp "$SRC_RUN" "$root/$BASE_REL/products/cognition/src/grad/grad_run.c"
    cp "$SRC_COORD" "$root/$BASE_REL/products/cognition/src/grad/grad_coordinator.c"
    cp "$SRC_CASES" "$root/$BASE_REL/products/cognition/tests/unit/test_grad_run.c"
    cp "$SRC_RUNNER" "$root/$BASE_REL/products/cognition/tests/unit/test_grad.c"
    cp "$SRC_BUILD" "$root/$BASE_REL/products/cognition/CMakeLists.txt"
}

run_iso() {
    G35_ROOT="$1" AIRYRT_BUILD_ROOT="$BUILD" bash "$GATE"
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

P="agent-workload/products/cognition"
E="agent-workload/agentrt/atoms/coreloopthree"
CASES_REL="$P/tests/unit/test_grad_run.c"

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

# ── T3: 单例丢 stage 断言 → B2 ──────────────────────────────
section "T3: one case loses stage assertion must map red"
cp -a "$TMP/base" "$TMP/t3"
mutate "$TMP/t3/$CASES_REL" '/stats\.stage == GRAD_STAGE_LLM,/d'
expect_red "T3 stage assert dropped" "B2:" "$TMP/t3"

# ── T4: 全量丢 stage 断言 → B1 ──────────────────────────────
section "T4: all stage assertions gone must map red"
cp -a "$TMP/base" "$TMP/t4"
mutate "$TMP/t4/$CASES_REL" '/stats\.stage == /d'
expect_red "T4 stage asserts gone" "B1:" "$TMP/t4"

# ── T5: 阶段零赋值 → A2 ─────────────────────────────────────
section "T5: stage assignment removed must map red"
cp -a "$TMP/base" "$TMP/t5"
mutate "$TMP/t5/$P/src/grad/grad_coordinator.c" \
    '/stats\.stage = GRAD_STAGE_VERIFY;/d'
expect_red "T5 stage unreachable" "A2:" "$TMP/t5"

# ── T6: 出口兜底缺席 → A2 ───────────────────────────────────
section "T6: exit fallback removed must map red"
cp -a "$TMP/base" "$TMP/t6"
mutate "$TMP/t6/$P/src/grad/grad_coordinator.c" \
    '/stats\.stage == GRAD_STAGE_NONE)/d'
mutate "$TMP/t6/$P/src/grad/grad_coordinator.c" \
    '/stats\.stage = GRAD_STAGE_LOOP;/d'
expect_red "T6 fallback absent" "A2:" "$TMP/t6"

# ── T7: 新增未分类阶段 → A1 ─────────────────────────────────
section "T7: unclassified stage must map red"
cp -a "$TMP/base" "$TMP/t7"
mutate "$TMP/t7/$E/include/grad.h" \
    's/^} grad_stage_e;$/    GRAD_STAGE_MAYBE = 8\n} grad_stage_e;/'
expect_red "T7 unclassified stage" "A1:" "$TMP/t7"

# ── T8: 组合用例注销 → B3 ───────────────────────────────────
section "T8: unregistered case must map red"
cp -a "$TMP/base" "$TMP/t8"
mutate "$TMP/t8/$P/tests/unit/test_grad.c" '/RUN_TEST(test_run_exh);/d'
expect_red "T8 case unregistered" "B3:" "$TMP/t8"

# ── T9: 事件丢归因 → D1 ─────────────────────────────────────
section "T9: event drops stage must map red"
cp -a "$TMP/base" "$TMP/t9"
mutate "$TMP/t9/$E/src/cognition/think/engine_process_grad.c" \
    '/grad_out\.stats\.stage/d'
expect_red "T9 event stage dropped" "D1:" "$TMP/t9"

# ── T10: trace 丢归因 → D1 ──────────────────────────────────
section "T10: trace drops stage must map red"
cp -a "$TMP/base" "$TMP/t10"
mutate "$TMP/t10/$P/src/grad/grad_run.c" '/stage\\":%u,/d'
expect_red "T10 trace stage dropped" "D1:" "$TMP/t10"

# ── T11: 受审文件缺席 → rc=2 ────────────────────────────────
section "T11: missing audited file = env error"
cp -a "$TMP/base" "$TMP/t11"
rm -f "$TMP/t11/$P/src/grad/grad_coordinator.c"
rc=0
run_iso "$TMP/t11" >/dev/null 2>&1 || rc=$?
expect_rc "T11 audited file missing" 2 "$rc"

# ── T12: 构建树未指定 → rc=2 ────────────────────────────────
section "T12: unspecified build tree = env error"
rc=0
env -u AIRYRT_BUILD_ROOT -u QUALITY_GATE_BUILD_DIR bash "$GATE" >/dev/null 2>&1 || rc=$?
expect_rc "T12 build tree missing" 2 "$rc"

# ── T13: 构建树无用例登记 → D2 ──────────────────────────────
section "T13: build tree without case must map red"
mkdir -p "$TMP/emptybuild"
out="$(G35_ROOT="$TMP/base" AIRYRT_BUILD_ROOT="$TMP/emptybuild" bash "$GATE" 2>&1)" \
    && rc=0 || rc=$?
expect_rc "T13 runtime arm absent" 1 "$rc"
printf '%s\n' "$out" | grep -q "D2:" \
    || { log_err "T13 未由 D2 点名"; printf '%s\n' "$out" | tail -6; exit 1; }
log_ok "T13: D2 点名成立"

section "Gate 35 selfcheck verdict"
log_ok "全部断言符合预期（T1-T13）"
exit 0
