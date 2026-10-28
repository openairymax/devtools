#!/bin/bash
# 0.1.20 Gate 37 计费热路径门禁（方案 §3.7l / §9.1.2）
#
# 五条静态臂 + 两条证据臂，逐项可证伪：
#   A1 单同步点   —— cost_tracker.c 的强落盘调用只出现在 cost_write 的
#                    `if (wok && sync)` 保护块内（窗口机制之外不存在第二条
#                    同步路径）；
#   A2 窗口 SSoT  —— COST_FLUSH_MS / COST_FLUSH_OPS 各只出现一次定义与一次
#                    消费（窗口不是死配置）；
#   A3 热路径闭环 —— service_request.c 同时出现 add / estimate / flush；
#   A4 测量臂在位 —— bench_cost_hotpath.c 已登记进测试源集，且在构建树注册；
#   A5 收尾隔离   —— service_request.c 不得出现 cost_tracker_save（退出路径
#                    的无条件同步不得回流到请求路径）；
#   D1 两臂证据   —— 两臂 n ≥ 100；单请求同步次数 ≤ G37_COST_SYNC_PER_REQ；
#                    同步总量 × G37_COST_SYNC_RATE ≤ n；fsync_probe ≥ 1
#                    （介入器探针，防「零同步 = 测量失明」的假绿）；
#   D2 p99 增量   —— 落盘臂与关闭落盘的对照臂 p99 差 ≤ G37_COST_P99_DELTA_US。
#
# 语义（不静默 PASS）：受审文件/阈值/构建树缺失 = 环境错误（rc 2）；判据
# 不满足或证据不可解析 = 违例（rc 1）。本门禁只读证据，不估算、不放宽。
#
# 构建树位于源码区外（工程铁律 4.1.1）：由 AIRYRT_BUILD_ROOT 或
# QUALITY_GATE_BUILD_DIR 指定；两者皆空视为环境错误。
# 用法: [AIRYRT_BUILD_ROOT=<build>] [G37_COST_ARTIFACT=<json>] \
#         g37-cost-hotpath-gate.sh
# 退出码: 0 = 通过；1 = 违例；2 = 环境错误
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# G37_ROOT 供 selfcheck 在快照树上施注单一突变；生产路径恒为脚本自身锚点。
PROJECT_ROOT="${G37_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
AGENTRT="${PROJECT_ROOT}/agent-workload/agentrt"
LLM_D="${AGENTRT}/daemons/llm_d"
COST_C="${LLM_D}/src/accounting/cost_tracker.c"
REQ_C="${LLM_D}/src/rpc/service_request.c"
TESTS_CMAKE="${LLM_D}/tests/CMakeLists.txt"
BENCH_C="${LLM_D}/tests/bench_cost_hotpath.c"
THRESHOLDS="${SCRIPT_DIR}/../thresholds.conf"
BUILD_ROOT="${AIRYRT_BUILD_ROOT:-${QUALITY_GATE_BUILD_DIR:-}}"

CASE_NAME="llm_d_bench_cost_hotpath"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

log_ok()  { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err() { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section() { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

violations=0
bench_log="$(mktemp "${TMPDIR:-/tmp}/g37c-case.XXXXXX")"
trap 'rm -f "$bench_log"' EXIT

fail() {
    log_err "$*"
    violations=$((violations + 1))
}

# A1：强落盘调用必须落在 `if (... sync ...)` 保护块内（向前 5 行内存在该守卫）。
probe_sync_guard() {
    awk '
        { line[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                if (line[i] !~ /(^|[^[:alnum:]_])(fsync|_commit)[[:space:]]*\(/)
                    continue
                calls++
                guarded = 0
                for (j = i - 5; j < i; j++)
                    if (j >= 1 && line[j] ~ /if[[:space:]]*\(.*[^[:alnum:]_]sync[^[:alnum:]_]/)
                        guarded = 1
                if (!guarded) {
                    print "unguarded strong-sync call at line " i ": " line[i]
                    bad++
                }
            }
            if (calls == 0) print "no strong-sync call found: window mechanism is gone"
            exit (bad || calls == 0) ? 1 : 0
        }
    ' "$COST_C"
}

# A2：窗口阈值各一次定义 + 一次消费。
probe_window_ssot() {
    local ms ops
    ms=$(grep -c 'COST_FLUSH_MS' "$COST_C" || true)
    ops=$(grep -c 'COST_FLUSH_OPS' "$COST_C" || true)
    [ "$ms" = "2" ] && [ "$ops" = "2" ] && return 0
    echo "COST_FLUSH_MS=${ms} COST_FLUSH_OPS=${ops} (expected 2 = 1 define + 1 use)"
    return 1
}

# A3/A5：请求路径的形态。
probe_hotpath_shape() {
    local rc=0
    grep -q 'cost_tracker_add[[:space:]]*(' "$REQ_C" || { echo "no cost_tracker_add on request path"; rc=1; }
    grep -q 'cost_tracker_estimate[[:space:]]*(' "$REQ_C" || { echo "no cost_tracker_estimate on request path"; rc=1; }
    grep -q 'cost_tracker_flush[[:space:]]*(' "$REQ_C" || { echo "no cost_tracker_flush on request path"; rc=1; }
    if grep -q 'cost_tracker_save[[:space:]]*(' "$REQ_C"; then
        echo "unconditional save leaked into request path"
        rc=1
    fi
    return "$rc"
}

# A4：证据臂已登记进测试源集与构建树。
probe_bench_wired() {
    grep -q 'bench_cost_hotpath\.c' "$TESTS_CMAKE" || { echo "bench not listed in test sources"; return 1; }
    if ! ctest --test-dir "$BUILD_ROOT" -N -R "^${CASE_NAME}$" 2>/dev/null | grep -q "Test #"; then
        echo "case not registered in build tree: ${CASE_NAME}"
        return 1
    fi
    return 0
}

# 运行证据臂：介入器失灵（probe < 1）由被测程序自身以非零退出暴露。
run_bench() {
    if ! G37_COST_ARTIFACT="$ART" ctest --test-dir "$BUILD_ROOT" -R "^${CASE_NAME}$" \
        --output-on-failure >"$bench_log" 2>&1; then
        fail "case failed: ${CASE_NAME}"
        tail -8 "$bench_log" | sed 's/^/        /'
        return 1
    fi
    log_ok "case passed: ${CASE_NAME}"
    [ -f "$ART" ] || { fail "evidence not produced: ${ART}"; return 1; }
    return 0
}

# 证据读成 key=value；不可解析即失败（不猜、不补默认值）。
read_evidence() {
    python3 - "$ART" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    d = json.load(fh)
a, b = d["a"], d["b"]
print("n_a=%d" % d["n_a"])
print("n_b=%d" % d["n_b"])
print("sync_max_a=%d" % a["sync_max"])
print("sync_total_a=%d" % a["sync_total"])
print("sync_total_b=%d" % b["sync_total"])
print("p99_a=%.3f" % a["p99_us"])
print("p99_b=%.3f" % b["p99_us"])
print("p99_delta=%.3f" % d["p99_delta_us"])
print("probe=%d" % d["fsync_probe"])
PY
}

# 整数比较（阈值可能被改成非整数，非法即违例）。
ge() { [ "$1" -ge "$2" ] 2>/dev/null; }

section "0.1.20 G37 cost hot-path gate"
for f in "$COST_C" "$REQ_C" "$TESTS_CMAKE" "$BENCH_C" "$THRESHOLDS"; do
    [ -f "$f" ] || { log_err "受审文件缺失: ${f}"; exit 2; }
done
[ -n "$BUILD_ROOT" ] || {
    log_err "build tree not specified: set AIRYRT_BUILD_ROOT or QUALITY_GATE_BUILD_DIR"
    exit 2
}
[ -d "$BUILD_ROOT" ] || { log_err "build tree not found: ${BUILD_ROOT}"; exit 2; }

# shellcheck source=../thresholds.conf
source "$THRESHOLDS"
for v in "${G37_COST_P99_DELTA_US:-}" "${G37_COST_SYNC_PER_REQ:-}" "${G37_COST_SYNC_RATE:-}"; do
    case "$v" in
        ''|*[!0-9]*) log_err "thresholds.conf 缺 G37_COST_* 或非正整数"; exit 2 ;;
    esac
done
[ "${G37_COST_SYNC_PER_REQ}" -ge 1 ] && [ "${G37_COST_SYNC_RATE}" -ge 1 ] || {
    log_err "thresholds.conf 的 G37 频次口径必须为正"; exit 2;
}

section "A1 single sync point"
if msg=$(probe_sync_guard); then
    log_ok "strong-sync calls only inside the sync-guarded write block"
else
    while IFS= read -r line; do [ -n "$line" ] && fail "A1: ${line}"; done <<<"$msg"
fi

section "A2 flush window SSoT"
if msg=$(probe_window_ssot); then
    log_ok "flush window defined once and consumed"
else
    fail "A2: ${msg}"
fi

section "A3/A5 request-path shape"
if msg=$(probe_hotpath_shape); then
    log_ok "request path: add + estimate + flush, no unconditional save"
else
    while IFS= read -r line; do [ -n "$line" ] && fail "A3/A5: ${line}"; done <<<"$msg"
fi

section "A4 measurement arm wired"
if msg=$(probe_bench_wired); then
    log_ok "bench registered in test sources and build tree"
else
    fail "A4: ${msg}"
fi

section "D1/D2 two-arm evidence"
ART="${G37_COST_ARTIFACT:-}"
if [ -n "$ART" ] && [ -f "$ART" ]; then
    log_ok "evidence supplied: ${ART}"
else
    ART="${ART:-${TMPDIR:-/tmp}/g37-cost-hotpath-$$.json}"
    run_bench || ART=""
fi

if [ -n "$ART" ] && [ -f "$ART" ]; then
    if ev=$(read_evidence); then
        n_a=0; n_b=0; sync_max_a=0; sync_total_a=0; sync_total_b=0
        p99_a=0; p99_b=0; p99_delta=0; probe=0
        while IFS='=' read -r k v; do
            case "$k" in
                n_a) n_a=$v ;;
                n_b) n_b=$v ;;
                sync_max_a) sync_max_a=$v ;;
                sync_total_a) sync_total_a=$v ;;
                sync_total_b) sync_total_b=$v ;;
                p99_a) p99_a=$v ;;
                p99_b) p99_b=$v ;;
                p99_delta) p99_delta=$v ;;
                probe) probe=$v ;;
            esac
        done <<<"$ev"

        ge "$n_a" 100 && ge "$n_b" 100 \
            || fail "D1: sample size below 100 (n_a=${n_a} n_b=${n_b})"
        [ "$sync_max_a" -le "$G37_COST_SYNC_PER_REQ" ] \
            || fail "D1: ${sync_max_a} strong syncs in one request (> ${G37_COST_SYNC_PER_REQ})"
        [ $((sync_total_a * G37_COST_SYNC_RATE)) -le "$n_a" ] \
            || fail "D1: sync rate ${sync_total_a}/${n_a} above 1/${G37_COST_SYNC_RATE}"
        ge "$probe" 1 \
            || fail "D1: interposer probe is 0 — zero-sync evidence would be blind"
        awk -v d="$p99_delta" -v lim="$G37_COST_P99_DELTA_US" 'BEGIN { exit (d > lim) ? 1 : 0 }' \
            || fail "D2: p99 delta ${p99_delta}us above ${G37_COST_P99_DELTA_US}us"

        log_ok "arm A: n=${n_a} sync_total=${sync_total_a} sync_max=${sync_max_a} p99=${p99_a}us"
        log_ok "arm B: n=${n_b} sync_total=${sync_total_b} p99=${p99_b}us"
        log_ok "delta=${p99_delta}us limit=${G37_COST_P99_DELTA_US}us probe=${probe}"
    else
        fail "D1: evidence unparsable: ${ART}"
    fi
fi

section "0.1.20 G37 cost hot-path gate"
if [ "$violations" -gt 0 ]; then
    log_err "found ${violations} cost hot-path violation(s)"
    log_err "0.1.20 G37 cost hot-path gate FAILED"
    exit 1
fi
log_ok "0.1.20 G37 cost hot-path gate PASSED"
exit 0
