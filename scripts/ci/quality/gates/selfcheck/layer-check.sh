#!/bin/bash
# layer-check selfcheck 进程内通道总线边界（0.1.20 方案 §3.7p / Gate 24 E 段）
#
# 职责：E 段（P1-10 裁决）逐条"植入必红"——若越界引用与 .rpc 命名
#   派生恒绿，则「再造一条进程内命名通路」可在门禁下静默复活，
#   12,057 次 target not found 的缺陷面将重新打开。
#
# 用例（每例只在隔离树上施注单一突变，红因归因唯一）：
#   T1 生产树正向绿：真实源码树 rc=0
#   T2 夹具控制臂：无突变夹具 rc=0（证明 T3-T7 的红只来自注入）
#   T3 E1 外户越界：products 侧调用 airy_ipc_connect → rc=1 且 E1 点名
#   T4 E1 内核外越界：daemons 侧调用 airy_ipc_create_channel → rc=1 且 E1 点名
#   T5 E2 命名派生：以 ".rpc" 后缀拼通道名 → rc=1 且 E2 点名
#   T6 豁免面：tests/ 下同调用不阻断（过判会逼开发者绕开门禁）
#   T7 实现面：corekern 自身持有该 API 不阻断（机制归位）
#   T8 树缺席：rc=3（不得静默跳过）
#
# 用法: selfcheck/layer-check.sh
# 退出码: 0 = 全部断言符合预期；1 = 判定矩阵失守；2 = 前置缺席
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AHUB="$(cd "$SCRIPT_DIR/../../../../../.." && pwd)"
GATE="${GATES_DIR}/layer-check.sh"
REAL_ROOT="$AHUB"

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

if [ ! -f "$GATE" ]; then
    log_err "前置缺席：${GATE}"
    exit 2
fi

run_iso() {
    LAYER_ROOT="$1" bash "$GATE" 2>&1
}

# 期望红：rc=1 且由预期段名点名。
expect_red() {
    local name="$1" marker="$2" root="$3" out rc
    out="$(run_iso "$root")" && rc=0 || rc=$?
    expect_rc "$name" 1 "$rc"
    printf '%s\n' "$out" | grep -q "$marker" \
        || { log_err "${name}: 未由 ${marker} 点名"; printf '%s\n' "$out" | tail -8; exit 1; }
    log_ok "${name}: ${marker} 点名成立"
}

expect_green() {
    local name="$1" root="$2" out rc
    out="$(run_iso "$root")" && rc=0 || rc=$?
    expect_rc "$name" 0 "$rc"
}

# 夹具：最小可判定树（A/B/C/D/E 全绿）。只含判定所需最小结构。
make_base() {
    local root="$1"
    mkdir -p "$root/agent-workload/agentrt/daemons/demo/src"
    cat > "$root/agent-workload/agentrt/link-whitelist.txt" <<'EOF'
demo_d: airy_demo_service
EOF
    cat > "$root/agent-workload/agentrt/CMakeLists.txt" <<'EOF'
add_library(airy_demo_service STATIC src/svc.c)
add_library(demo_d STATIC daemons/demo/src/demo.c)
EOF
    printf '/* fixture */\nint demo_entry(void) { return 0; }\n' \
        > "$root/agent-workload/agentrt/daemons/demo/src/demo.c"
}

# ── T1: 生产树正向绿 ───────────────────────────────────────
section "T1: production tree green"
expect_green "T1 production audit" "$REAL_ROOT"

# ── T2: 夹具控制臂 ─────────────────────────────────────────
section "T2: fixture control arm"
make_base "$TMP/base"
expect_green "T2 fixture control" "$TMP/base"

# ── T3: E1 外户越界 ────────────────────────────────────────
section "T3: product-side bus reuse must map red"
cp -a "$TMP/base" "$TMP/t3"
mkdir -p "$TMP/t3/agent-workload/products/canary/src"
printf 'int x(void) { return (int)airy_ipc_connect("demo", 0); }\n' \
    > "$TMP/t3/agent-workload/products/canary/src/x.c"
expect_red "T3 product reuse" "E1." "$TMP/t3"

# ── T4: E1 内核外越界 ──────────────────────────────────────
section "T4: daemon-side bus reuse must map red"
cp -a "$TMP/base" "$TMP/t4"
printf 'int x(void) { return (int)airy_ipc_create_channel("demo", 0, 0, 0); }\n' \
    > "$TMP/t4/agent-workload/agentrt/daemons/demo/src/x.c"
expect_red "T4 daemon reuse" "E1." "$TMP/t4"

# ── T5: E2 .rpc 命名派生 ───────────────────────────────────
section "T5: .rpc name derivation must map red"
cp -a "$TMP/base" "$TMP/t5"
printf 'int x(char *c) { AIRY_MEMCPY(c, ".rpc", sizeof(".rpc")); return 0; }\n' \
    > "$TMP/t5/agent-workload/agentrt/daemons/demo/src/x.c"
expect_red "T5 rpc derivation" "E2." "$TMP/t5"

# ── T6: 豁免面（tests/）────────────────────────────────────
section "T6: tests/ exemption must stay green"
cp -a "$TMP/base" "$TMP/t6"
mkdir -p "$TMP/t6/agent-workload/agentrt/daemons/demo/tests"
printf 'int x(void) { return (int)airy_ipc_connect("demo", 0); }\n' \
    > "$TMP/t6/agent-workload/agentrt/daemons/demo/tests/t_x.c"
expect_green "T6 tests exemption" "$TMP/t6"

# ── T7: 实现面（corekern 自身）─────────────────────────────
section "T7: corekern implementation home must stay green"
cp -a "$TMP/base" "$TMP/t7"
mkdir -p "$TMP/t7/agent-workload/agentrt/atoms/corekern/src/ipc"
printf 'int x(void) { return (int)airy_ipc_connect("demo", 0); }\n' \
    > "$TMP/t7/agent-workload/agentrt/atoms/corekern/src/ipc/binder_channel.c"
expect_green "T7 corekern home" "$TMP/t7"

# ── T8: 树缺席 → rc=3 ──────────────────────────────────────
section "T8: absent tree = env error"
mkdir -p "$TMP/t8"
rc=0
run_iso "$TMP/t8" >/dev/null 2>&1 || rc=$?
expect_rc "T8 absent tree" 3 "$rc"

section "layer-check selfcheck verdict"
log_ok "全部断言符合预期（T1-T8）"
exit 0
