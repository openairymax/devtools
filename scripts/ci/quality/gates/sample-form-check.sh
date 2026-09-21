#!/bin/bash
# V16.10 (0.1.18 plan §12.16.3.4 S6): llm_d 样本形态门禁
#
# 断言（0.1.18-架构改进方案.md:1958）：
#   A1  7 域成形：src/{bootstrap,adapter,rpc,config,accounting,providers,router} 全为目录
#   A2  src/ 顶层裸文件数 = 0
#   A3  include/ 仅 2 头（白名单集合断言，防换名漂移）
#   A4  llm_service_internal.h 拆片后每片入度 ≤ 5
#   A5  内层域（providers/router/accounting/config）对发布头 include 边 = 0（S2 判据，FATAL）
#   A6  装配域（bootstrap/adapter）对发布头残余边入基线只减不增（ops 装配现实，收敛驱动）
#
# 基线：v16-sample-baseline.txt（A6 台账）；--update-baseline 重建。
# 用法: sample-form-check.sh [--update-baseline]
# 退出码: 0 = 通过；1 = 存在违例
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
LLM_D="${PROJECT_ROOT}/agent-workload/agentrt/daemons/llm_d"
BASELINE="$SCRIPT_DIR/v16-sample-baseline.txt"
UPDATE_BASELINE=0
if [ "${1:-}" = "--update-baseline" ]; then
    UPDATE_BASELINE=1
fi

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_YELLOW='\033[0;33m'
COLOR_RESET='\033[0m'

log_info() { echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET}  $*"; }
log_ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*"; }
log_err()  { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section()  { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

VIOLATIONS=0
SHRUNK=0

if [ ! -d "$LLM_D" ]; then
    log_err "llm_d source tree not found: ${LLM_D}"
    exit 2
fi

# ── A1: 7 域成形 ──────────────────────────────────────────────
section "A1: seven-domain layout"
for d in bootstrap adapter rpc config accounting providers router; do
    if [ -d "${LLM_D}/src/${d}" ]; then
        log_ok "src/${d}/"
    else
        log_err "missing domain dir: src/${d}/"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
done

# ── A2: src/ 顶层裸文件 = 0 ──────────────────────────────────
section "A2: no bare files at src/ top level"
bare=$(find "${LLM_D}/src" -maxdepth 1 -type f | wc -l)
if [ "$bare" -eq 0 ]; then
    log_ok "src/ top-level bare files = 0"
else
    log_err "src/ top-level bare files = ${bare} (must be 0)"
    find "${LLM_D}/src" -maxdepth 1 -type f | sed 's/^/    /'
    VIOLATIONS=$((VIOLATIONS + 1))
fi

# ── A3: include/ 仅 2 头（白名单） ────────────────────────────
section "A3: include/ exactly two published headers"
expected_headers="llm_service.h daemon_llm_ops_bootstrap.h"
actual_headers=$(cd "${LLM_D}/include" && ls *.h 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')
expected_sorted=$(echo "$expected_headers" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
if [ "$actual_headers" = "$expected_sorted" ]; then
    log_ok "include/ = { ${actual_headers} }"
else
    log_err "include/ header set drifted: got [${actual_headers}] expected [${expected_sorted}]"
    VIOLATIONS=$((VIOLATIONS + 1))
fi

# ── A4: 拆片入度 ≤ 5 ─────────────────────────────────────────
section "A4: internal header fan-in <= 5"
MAX_FANIN=5
while IFS= read -r hdr; do
    rel="${hdr#"${LLM_D}/src/"}"
    cnt=$(grep -rl --include='*.c' --include='*.h' "#include \"${rel}\"" \
        "${LLM_D}/src" "${LLM_D}/tests" 2>/dev/null | wc -l)
    if [ "$cnt" -le "$MAX_FANIN" ]; then
        log_ok "${rel}: fan-in ${cnt} <= ${MAX_FANIN}"
    else
        log_err "${rel}: fan-in ${cnt} > ${MAX_FANIN}"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
done < <(find "${LLM_D}/src" -name '*internal*.h' | sort)

# ── A5 + A6: 发布头反向边 ────────────────────────────────────
section "A5/A6: published-header reverse edges"
declare -a A6_ENTRIES=()
for hdr in $(cd "${LLM_D}/include" && ls *.h 2>/dev/null); do
    # 内层域：硬断言零边（S2 判据）
    for d in providers router accounting config; do
        hits=$(grep -rl "include \"${hdr}\"\|include <${hdr}>" \
            "${LLM_D}/src/${d}" 2>/dev/null | wc -l || true)
        if [ "$hits" -gt 0 ]; then
            log_err "reverse edge: ${hdr} included from src/${d}/ (inner domain, must be 0)"
            grep -rn "include \"${hdr}\"\|include <${hdr}>" "${LLM_D}/src/${d}" 2>/dev/null | \
                sed "s|${LLM_D}/||; s/^/    /"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    done
    # 装配域：残余边入基线只减不增
    while IFS= read -r f; do
        key="${f#"${LLM_D}/"}:${hdr}"
        A6_ENTRIES+=("$key")
    done < <(grep -rl "include \"${hdr}\"\|include <${hdr}>" \
        "${LLM_D}/src/bootstrap" "${LLM_D}/src/adapter" 2>/dev/null | sort || true)
done

section "A6: assembly-domain baseline (bootstrap/adapter)"
if [ "$UPDATE_BASELINE" -eq 1 ]; then
    printf '%s\n' "${A6_ENTRIES[@]}" | sort -u > "$BASELINE"
    log_ok "baseline rewritten: ${BASELINE} ($(wc -l < "$BASELINE") entries)"
else
    : > /tmp/v16_sample_seen.$$
    for key in "${A6_ENTRIES[@]}"; do
        echo "$key" >> /tmp/v16_sample_seen.$$
    done
    sort -u /tmp/v16_sample_seen.$$ > /tmp/v16_sample_seen_s.$$
    while IFS= read -r key; do
        if grep -qxF "$key" "$BASELINE" 2>/dev/null; then
            log_warn "baseline entry: ${key}"
        else
            log_err "NEW reverse edge not in baseline: ${key}"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    done < /tmp/v16_sample_seen_s.$$
    if [ -s "$BASELINE" ]; then
        while IFS= read -r key; do
            [ -z "$key" ] && continue
            if ! grep -qxF "$key" /tmp/v16_sample_seen_s.$$; then
                log_ok "baseline entry resolved (shrunk): ${key}"
                SHRUNK=$((SHRUNK + 1))
            fi
        done < "$BASELINE"
    fi
    rm -f /tmp/v16_sample_seen.$$ /tmp/v16_sample_seen_s.$$
fi

# ── 汇总 ─────────────────────────────────────────────────────
echo ""
if [ "$VIOLATIONS" -eq 0 ]; then
    log_ok "V16.10 sample-form gate PASSED (shrunk: ${SHRUNK})"
    exit 0
else
    log_err "V16.10 sample-form gate FAILED: ${VIOLATIONS} violation(s)"
    exit 1
fi
