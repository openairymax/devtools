#!/bin/bash
# Gate 37 selfcheck 计费热路径两臂门禁（0.1.20 方案 §3.7l / §9.1.2 / §9.3）
#
# 职责：g37-cost-hotpath-gate.sh 的七条臂逐条"植入必红"——门禁恒绿等于
#   给计费热路径发无限额度通行证，D1 的零同步结论将无法证伪。
#
# 用例（每例只在快照树上施注单一突变，红因归因唯一）：
#   T1 生产形态正向绿：真实源码树 + 真实构建树 rc=0
#   T2 A1 窗口外强同步：注入无守卫 fsync 调用 → rc=1 且 A1 点名
#   T3 A2 窗口 SSoT 失守：改坏宏消费点 → rc=1 且 A2 点名
#   T4 A3 请求路径断链：删去 flush 调用 → rc=1 且 A3 点名
#   T5 A5 收尾回流：请求路径注入 save → rc=1 且 A5 点名
#   T6 A4 测量臂脱钩：测试源集删去 bench → rc=1 且 A4 点名
#   T7 D1 单请求同步超限：sync_max=3 → rc=1
#   T8 D1 落盘频次超限：sync_total=512/n=512 → rc=1
#   T9 D1 介入器失明：probe=0 → rc=1（"零同步"必须有测量能力背书）
#   T10 D2 p99 增量越界：delta=99999us → rc=1
#   T11 受审文件缺席：rc=2（不得静默跳过）
#   T12 构建树未指定：rc=2（fail-closed）
#
# 用法: selfcheck/gate-37.sh
# 前置: AIRYRT_BUILD_ROOT 指向含 llm_d_bench_cost_hotpath 的构建树
# 退出码: 0 = 全部断言符合预期；1 = 判定矩阵失守；2 = 前置缺席
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AHUB="$(cd "$SCRIPT_DIR/../../../../../.." && pwd)"
GATE="${GATES_DIR}/g37-cost-hotpath-gate.sh"

SRC_COST="${AHUB}/agent-workload/agentrt/daemons/llm_d/src/accounting/cost_tracker.c"
SRC_REQ="${AHUB}/agent-workload/agentrt/daemons/llm_d/src/rpc/service_request.c"
SRC_CMAKE="${AHUB}/agent-workload/agentrt/daemons/llm_d/tests/CMakeLists.txt"
SRC_BENCH="${AHUB}/agent-workload/agentrt/daemons/llm_d/tests/bench_cost_hotpath.c"

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

for f in "$SRC_COST" "$SRC_REQ" "$SRC_CMAKE" "$SRC_BENCH"; do
    [ -f "$f" ] || { log_err "受审源文件缺席: ${f}"; exit 2; }
done

# 快照树：与生产同构，每个用例只变异一处。
make_base() {
    local root="$1" dir
    dir="$root/agent-workload/agentrt/daemons/llm_d"
    mkdir -p "$dir/src/accounting" "$dir/src/rpc" "$dir/tests"
    cp "$SRC_COST" "$dir/src/accounting/cost_tracker.c"
    cp "$SRC_REQ" "$dir/src/rpc/service_request.c"
    cp "$SRC_CMAKE" "$dir/tests/CMakeLists.txt"
    cp "$SRC_BENCH" "$dir/tests/bench_cost_hotpath.c"
}

# 通过证据：与 D1/D2 全部判据相容（n=512、零同步、probe=1、delta 小）。
write_evidence() {
    local path="$1" sync_max="$2" sync_total="$3" probe="$4" delta="$5"
    python3 - "$path" "$sync_max" "$sync_total" "$probe" "$delta" <<'PY'
import json, sys
path, sync_max, sync_total, probe, delta = sys.argv[1:6]
doc = {
    "n_a": 512, "n_b": 512, "warm": 16,
    "a": {"sync_total": int(sync_total), "sync_max": int(sync_max),
          "p50_us": 1.0, "p95_us": 2.0, "p99_us": 80.0, "max_us": 120.0},
    "b": {"sync_total": 0, "sync_max": 0,
          "p50_us": 0.05, "p95_us": 0.08, "p99_us": 0.096, "max_us": 0.3},
    "p99_delta_us": float(delta),
    "fsync_probe": int(probe),
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
}

# 隔离执行：$1=快照根 $2=证据文件（空则真跑 bench）
run_iso() {
    G37_ROOT="$1" AIRYRT_BUILD_ROOT="$BUILD" G37_COST_ARTIFACT="${2:-}" bash "$GATE"
}

# 反向用例：必须 rc=1 且由预期臂点名。
expect_red() {
    local name="$1" marker="$2" root="$3" art="$4" out rc
    out="$(run_iso "$root" "$art" 2>&1)" && rc=0 || rc=$?
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
AIRYRT_BUILD_ROOT="$BUILD" bash "$GATE" >/dev/null 2>&1 || rc=$?
expect_rc "T1 production audit" 0 "$rc"

make_base "$TMP/base"
GOOD="$TMP/good.json"
write_evidence "$GOOD" 0 0 1 79.9

# ── T2: A1 窗口外强同步 ─────────────────────────────────────
section "T2: unguarded strong sync must map red"
cp -a "$TMP/base" "$TMP/t2"
mutate "$TMP/t2/agent-workload/agentrt/daemons/llm_d/src/accounting/cost_tracker.c" \
    '1i void g37_injected(void) { (void)fsync(0); }'
expect_red "T2 unguarded sync" "A1:" "$TMP/t2" "$GOOD"

# ── T3: A2 窗口 SSoT 失守 ───────────────────────────────────
section "T3: broken window SSoT must map red"
cp -a "$TMP/base" "$TMP/t3"
mutate "$TMP/t3/agent-workload/agentrt/daemons/llm_d/src/accounting/cost_tracker.c" \
    '/pending < COST_FLUSH_OPS/d'
expect_red "T3 window ssot" "A2:" "$TMP/t3" "$GOOD"

# ── T4: A3 请求路径断链 ─────────────────────────────────────
section "T4: flush missing on request path must map red"
cp -a "$TMP/base" "$TMP/t4"
mutate "$TMP/t4/agent-workload/agentrt/daemons/llm_d/src/rpc/service_request.c" \
    '/cost_tracker_flush[[:space:]]*(/d'
expect_red "T4 flush removed" "no cost_tracker_flush" "$TMP/t4" "$GOOD"

# ── T5: A5 收尾回流 ─────────────────────────────────────────
section "T5: save leaked into request path must map red"
cp -a "$TMP/base" "$TMP/t5"
mutate "$TMP/t5/agent-workload/agentrt/daemons/llm_d/src/rpc/service_request.c" \
    '1i /* injected */ (void)cost_tracker_save(ct, "x");'
expect_red "T5 save leaked" "unconditional save" "$TMP/t5" "$GOOD"

# ── T6: A4 测量臂脱钩 ───────────────────────────────────────
section "T6: bench unwired from test sources must map red"
cp -a "$TMP/base" "$TMP/t6"
mutate "$TMP/t6/agent-workload/agentrt/daemons/llm_d/tests/CMakeLists.txt" \
    '/bench_cost_hotpath\.c/d'
expect_red "T6 bench unwired" "bench not listed" "$TMP/t6" "$GOOD"

# ── T7: D1 单请求同步超限 ───────────────────────────────────
section "T7: per-request sync above budget must map red"
write_evidence "$TMP/sync1.json" 3 24 1 79.9
expect_red "T7 sync per request" "strong syncs in one request" "$TMP/base" "$TMP/sync1.json"

# ── T8: D1 落盘频次超限 ─────────────────────────────────────
section "T8: sync frequency above budget must map red"
write_evidence "$TMP/rate.json" 1 512 1 79.9
expect_red "T8 sync rate" "sync rate" "$TMP/base" "$TMP/rate.json"

# ── T9: D1 介入器失明 ───────────────────────────────────────
section "T9: blind interposer must map red"
write_evidence "$TMP/blind.json" 0 0 0 79.9
expect_red "T9 blind probe" "interposer probe is 0" "$TMP/base" "$TMP/blind.json"

# ── T10: D2 p99 增量越界 ────────────────────────────────────
section "T10: p99 delta above budget must map red"
write_evidence "$TMP/delta.json" 0 0 1 99999
expect_red "T10 p99 delta" "p99 delta" "$TMP/base" "$TMP/delta.json"

# ── T11: 受审文件缺席 → rc=2 ────────────────────────────────
section "T11: missing audited file = env error"
cp -a "$TMP/base" "$TMP/t11"
rm -f "$TMP/t11/agent-workload/agentrt/daemons/llm_d/src/accounting/cost_tracker.c"
rc=0
run_iso "$TMP/t11" "$GOOD" >/dev/null 2>&1 || rc=$?
expect_rc "T11 audited file missing" 2 "$rc"

# ── T12: 构建树未指定 → rc=2 ────────────────────────────────
section "T12: unspecified build tree = env error"
rc=0
env -u AIRYRT_BUILD_ROOT -u QUALITY_GATE_BUILD_DIR bash "$GATE" >/dev/null 2>&1 || rc=$?
expect_rc "T12 build tree missing" 2 "$rc"

section "Gate 37 selfcheck verdict"
log_ok "全部断言符合预期（T1-T12）"
exit 0
