#!/bin/bash
# Gate 31 selfcheck 验证器隔离（0.1.20 方案 §9.1 Gate 31）
#
# 职责：验证 g31-verifier-isolation.sh 的判定矩阵——隔离执法器自身必须
#   可证伪：五条臂与两类环境错误都要有"植入必红"的反向用例（T4 纪律）。
#
# 用例：
#   T1 生产形态正向绿：真实源码树全链 rc=0
#   T2 隔离全绿：真实源快照到 tmp 根 → rc=0（基线语义与生产一致）
#   T3 对象面越界：注入 S2/LLM 外部调用 → rc=1（B1 点名）
#   T4 实现面越界：实现文件引 LLM 头 → rc=1（A1 点名）
#   T5 契约面越界：契约头引 LLM 头 → rc=1（A2 点名）
#   T6 入口改名：公开入口定义失位 → rc=1（B2 点名，防空壳）
#   T7 空 TU：实现清空 → rc=1（B2 点名，零符号也是空壳）
#   T8 双实现：他文件追加同名定义 → rc=1（B3 点名）
#   T9 受审件缺席（.c）→ rc=2（fail-closed）
#   T10 受审件缺席（.h）→ rc=2（fail-closed）
#   T11 工具链缺席 → rc=2（无法判断即红，不得静默跳过）
#   T12 include 根缺席 → rc=2（契约闭包不可解析）
#   T13 豁免不得泛化：服务实现头（非 *_types.h）仍红（A1 点名）
#
# 用法: selfcheck/gate-31.sh
# 退出码: 0 = 全部断言符合预期；1 = 判定矩阵失守
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../../.." && pwd)"
GATE="${GATES_DIR}/g31-verifier-isolation.sh"

AW="${PROJECT_ROOT}/agent-workload"
SRC_C="${AW}/products/cognition/src/grad/grad_verifier.c"
SRC_H="${AW}/products/cognition/src/grad/grad_verifier.h"

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

# 隔离根构造器：agentrt 以符号链接复用真实头面（编译闭包与生产一致），
# cognition 源码整目录快照（供变异），每个用例只做单一变异，红因唯一。
make_base() {
    local root="$1"
    mkdir -p "$root/agent-workload/products/cognition"
    ln -s "$AW/agentrt" "$root/agent-workload/agentrt"
    cp -a "$AW/products/cognition/src" "$root/agent-workload/products/cognition/src"
    cp -a "$AW/products/cognition/include" "$root/agent-workload/products/cognition/include"
}

run_iso() {
    local root="$1"
    G31_ROOT="$root" bash "$GATE"
}

expect_red() {
    local name="$1" marker="$2" root="$3" out rc
    out="$(run_iso "$root" 2>&1)" && rc=0 || rc=$?
    expect_rc "$name" 1 "$rc"
    printf '%s\n' "$out" | grep -q "${marker}" \
        || { log_err "${name}: 未由 ${marker} 点名"; exit 1; }
    log_ok "${name}: ${marker} 点名成立"
}

for f in "$SRC_C" "$SRC_H"; do
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

# ── T3: 对象面越界 → B1 点名 ────────────────────────────────
section "T3: LLM call injected must map red"
cp -a "$TMP/base" "$TMP/t3"
printf '\nextern int grad_llm_s2_plan_ping(void);\nint grad_verifier_gate_probe(void) { return grad_llm_s2_plan_ping(); }\n' \
    >> "$TMP/t3/agent-workload/products/cognition/src/grad/grad_verifier.c"
expect_red "T3 symbol leakage" "B1" "$TMP/t3"

# ── T4: 实现面越界 → A1 点名 ────────────────────────────────
section "T4: LLM header in implementation must map red"
cp -a "$TMP/base" "$TMP/t4"
sed -i 's/^#include "grad_verifier.h"$/#include "grad_verifier.h"\n#include "grad_llm_call.h"/' \
    "$TMP/t4/agent-workload/products/cognition/src/grad/grad_verifier.c"
expect_red "T4 source include" "A1" "$TMP/t4"

# ── T5: 契约面越界 → A2 点名 ────────────────────────────────
section "T5: LLM header in contract must map red"
cp -a "$TMP/base" "$TMP/t5"
printf '\n#include "grad_llm_call.h"\n' \
    >> "$TMP/t5/agent-workload/products/cognition/src/grad/grad_verifier.h"
expect_red "T5 contract include" "A2" "$TMP/t5"

# ── T6: 入口改名（空壳）→ B2 点名 ───────────────────────────
section "T6: missing public entry must map red"
cp -a "$TMP/base" "$TMP/t6"
sed -i 's/^airy_err_t airy_grad_verify_plan(/airy_err_t airy_grad_verify_plan_x(/' \
    "$TMP/t6/agent-workload/products/cognition/src/grad/grad_verifier.c"
expect_red "T6 entry renamed" "B2" "$TMP/t6"

# ── T7: 空 TU → B2 点名 ─────────────────────────────────────
section "T7: empty translation unit must map red"
cp -a "$TMP/base" "$TMP/t7"
printf '/* empty */\n' \
    > "$TMP/t7/agent-workload/products/cognition/src/grad/grad_verifier.c"
expect_red "T7 empty TU" "B2" "$TMP/t7"

# ── T8: 双实现 → B3 点名 ────────────────────────────────────
section "T8: duplicate implementation must map red"
cp -a "$TMP/base" "$TMP/t8"
printf '\nconst char *airy_grad_error_str(int e) { (void)e; return "x"; }\n' \
    >> "$TMP/t8/agent-workload/products/cognition/src/grad/grad_llm_call.c"
expect_red "T8 duplicate definition" "B3" "$TMP/t8"

# ── T9: 受审件缺席（.c）→ rc=2 ──────────────────────────────
section "T9: missing implementation file = env error"
cp -a "$TMP/base" "$TMP/t9"
rm -f "$TMP/t9/agent-workload/products/cognition/src/grad/grad_verifier.c"
rc=0
run_iso "$TMP/t9" >/dev/null 2>&1 || rc=$?
expect_rc "T9 implementation missing" 2 "$rc"

# ── T10: 受审件缺席（.h）→ rc=2 ─────────────────────────────
section "T10: missing contract file = env error"
cp -a "$TMP/base" "$TMP/t10"
rm -f "$TMP/t10/agent-workload/products/cognition/src/grad/grad_verifier.h"
rc=0
run_iso "$TMP/t10" >/dev/null 2>&1 || rc=$?
expect_rc "T10 contract missing" 2 "$rc"

# ── T11: 工具链缺席 → rc=2 ──────────────────────────────────
section "T11: missing toolchain = env error"
rc=0
G31_ROOT="$TMP/base" G31_CC=/nonexistent/cc bash "$GATE" >/dev/null 2>&1 || rc=$?
expect_rc "T11 toolchain missing" 2 "$rc"

# ── T12: include 根缺席 → rc=2 ──────────────────────────────
section "T12: missing include root = env error"
cp -a "$TMP/base" "$TMP/t12"
rm -rf "$TMP/t12/agent-workload/products/cognition/src/gccp"
rc=0
run_iso "$TMP/t12" >/dev/null 2>&1 || rc=$?
expect_rc "T12 include root missing" 2 "$rc"

# ── T13: 豁免不得泛化（服务实现头仍红）──────────────────────
section "T13: service header must stay red (exemption is types-only)"
cp -a "$TMP/base" "$TMP/t13"
sed -i 's/^#include "grad_verifier.h"$/#include "grad_verifier.h"\n#include "llm_service.h"/' \
    "$TMP/t13/agent-workload/products/cognition/src/grad/grad_verifier.c"
expect_red "T13 service include" "A1" "$TMP/t13"

section "Gate 31 selfcheck verdict"
log_ok "全部断言符合预期（T1-T13）"
exit 0
