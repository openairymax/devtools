#!/bin/bash
# 0.1.19 G37 性能预算门禁（方案 §3.6.4 / §3.6.6；证伪修正 F5）
#
# 四段逐项可验证：
#   G37-0 预算 SSoT —— g37-perf-budget.txt 三档齐备、字段合法（改表即改门禁）；
#   G37-1 轻量模式可达 —— svc_test_svc_model_defaults（D1：perf_mode 解析优先级）；
#   G37-2 消费闭环 —— svc_perf_resolve 在非测试源码被消费且比较 SVC_PERF_LIGHTWEIGHT
#         （lightweight 不是死配置，D1 的行为分支真实存在）；
#   G37-3 证据契约 —— g37-evidence-check.py 校验三档实测证据（TTFT / decode tps /
#         backend / perf_mode / 证据年龄 / 探针哈希）。
#
# 语义（不静默 PASS）：预算或构建树缺失 = 环境错误（rc 2）；某档未实测 =
# 环境限制（rc 2，--strict 下失败）；已实测但超阈值 / 后端不符 / 证据失配 =
# 违例（rc 1）。本门禁只读证据，不做任何测量，也不生成任何估算值。
#
# 构建树位于源码区外（工程铁律 4.1.1）：由 AIRYRT_BUILD_ROOT 或
# QUALITY_GATE_BUILD_DIR 指定；两者皆空视为环境错误。
# 用法: [AIRYRT_BUILD_ROOT=<build>] [G37_EVIDENCE=<json>] g37-perf-budget-gate.sh
# 退出码: 0 = 通过；1 = 性能预算违例；2 = 环境错误（树/构建树/证据缺失）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
AGENTRT="${PROJECT_ROOT}/agent-workload/agentrt"
DAEMONS="${AGENTRT}/daemons"
BUDGET="${SCRIPT_DIR}/g37-perf-budget.txt"
EVIDENCE="${G37_EVIDENCE:-${SCRIPT_DIR}/g37-perf-evidence.json}"
CHECKER="${SCRIPT_DIR}/g37-evidence-check.py"
PROBE="${PROJECT_ROOT}/tools/scripts/ops/benchmark/ttft_probe.py"
BUILD_ROOT="${AIRYRT_BUILD_ROOT:-${QUALITY_GATE_BUILD_DIR:-}}"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

log_ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err()  { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
log_warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*"; }
section()  { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

violations=0
env_missing=0
case_log="$(mktemp "${TMPDIR:-/tmp}/g37-case.XXXXXX")"
trap 'rm -f "$case_log"' EXIT

fail() {
    log_err "$*"
    violations=$((violations + 1))
}

# 运行单个 ctest 用例；不存在即判违例，失败输出末 8 行。
run_case() {
    local name="$1"
    if ! ctest --test-dir "$BUILD_ROOT" -N -R "^${name}$" 2>/dev/null | grep -q "Test #"; then
        fail "case not registered in build tree: ${name}"
        return 0
    fi
    if ctest --test-dir "$BUILD_ROOT" -R "^${name}$" --output-on-failure \
        >"$case_log" 2>&1; then
        log_ok "case passed: ${name}"
    else
        fail "case failed: ${name}"
        tail -8 "$case_log" | sed 's/^/        /'
    fi
}

# G37-0：预算表结构（三档齐备 + 数值/枚举合法）。
check_budget() {
    local problems
    problems=$(awk -F'|' '
        /^[[:space:]]*(#|$)/ { next }
        NF != 6 { print "malformed line " FNR ": expected 6 fields"; next }
        {
            tier = $1
            if (tier !~ /^(cloud|local_gpu|local_cpu)$/) {
                print "line " FNR ": unknown tier " tier
                next
            }
            if (seen[tier]++) print "line " FNR ": duplicate tier " tier
            if ($2 !~ /^[0-9]+$/) print "line " FNR ": bad ttft_max_ms"
            if ($3 !~ /^[0-9]+$/) print "line " FNR ": bad decode_min_tps"
            if ($4 !~ /^(any|sycl|vulkan|cpu|cuda|metal|rocm|openai)$/)
                print "line " FNR ": bad backend " $4
            if ($5 !~ /^(any|full|lightweight|auto)$/)
                print "line " FNR ": bad perf_mode " $5
            rows++
        }
        END {
            split("cloud local_gpu local_cpu", need, " ")
            for (i = 1; i <= 3; i++)
                if (!seen[need[i]]) print "missing tier " need[i]
            if (rows != 3) print "expected 3 tier rows, got " rows
        }
    ' "$BUDGET")
    if [ -n "$problems" ]; then
        while IFS= read -r line; do fail "budget: ${line}"; done <<<"$problems"
    else
        log_ok "budget SSoT: 3 tiers, thresholds well-formed"
    fi
}

# G37-2：svc_perf_resolve 在非测试源码被消费，且存在 lightweight 行为分支。
probe_perf_consume() {
    local hits
    hits=$(grep -rl 'svc_perf_resolve[[:space:]]*(' "$DAEMONS" \
        --include='*.c' 2>/dev/null | grep -v '/tests/' || true)
    [ -n "$hits" ] || return 1
    grep -rq 'SVC_PERF_LIGHTWEIGHT' "$DAEMONS" --include='*.c' \
        --exclude-dir=tests 2>/dev/null || return 1
    printf '%s\n' "$hits"
}

section "0.1.19 G37 performance-budget gate"
[ -d "$DAEMONS" ] || { log_err "daemon tree not found: ${DAEMONS}"; exit 2; }
[ -f "$BUDGET" ] || { log_err "budget SSoT not found: ${BUDGET}"; exit 2; }
[ -n "$BUILD_ROOT" ] || {
    log_err "build tree not specified: set AIRYRT_BUILD_ROOT or QUALITY_GATE_BUILD_DIR"
    exit 2
}
[ -d "$BUILD_ROOT" ] || { log_err "build tree not found: ${BUILD_ROOT}"; exit 2; }

section "G37-0 budget SSoT"
check_budget

section "G37-1 lightweight mode reachable"
run_case svc_test_svc_model_defaults

section "G37-2 perf-mode consumption closure"
if consumers=$(probe_perf_consume); then
    while IFS= read -r file; do
        [ -n "$file" ] && log_ok "perf mode consumed: ${file#"$PROJECT_ROOT"/}"
    done <<<"$consumers"
else
    fail "svc_perf_resolve is not consumed by non-test source"
fi

section "G37-3 measured evidence contract"
if [ ! -f "$EVIDENCE" ]; then
    log_warn "no measured evidence: ${EVIDENCE}"
    log_warn "tiers cloud/local_gpu/local_cpu are unmeasured on this machine"
    env_missing=1
elif [ ! -f "$CHECKER" ]; then
    log_warn "evidence checker not found: ${CHECKER}"
    env_missing=1
else
    check_rc=0
    check_out=$(python3 "$CHECKER" --budget "$BUDGET" --evidence "$EVIDENCE" \
        --probe "$PROBE" --version-file "${AGENTRT}/VERSION" \
        --max-age-days "${G37_MAX_AGE_DAYS:-180}" 2>&1) || check_rc=$?
    echo "$check_out" | sed 's/^/        /'
    case "$check_rc" in
        0) log_ok "all measured tiers within budget" ;;
        2) log_warn "evidence incomplete: environment limitation"; env_missing=1 ;;
        *) fail "performance budget violated (checker rc=${check_rc})" ;;
    esac
fi

section "0.1.19 G37 performance-budget gate"
if [ "$violations" -gt 0 ]; then
    log_err "found ${violations} performance-budget violation(s)"
    log_err "0.1.19 G37 performance-budget gate FAILED"
    exit 1
fi
if [ "$env_missing" -ne 0 ]; then
    log_warn "gate cannot conclude: measured evidence unavailable"
    log_warn "run ttft_probe.py on each deployment tier, then re-run this gate"
    exit 2
fi
log_ok "0.1.19 G37 performance-budget gate PASSED"
exit 0
