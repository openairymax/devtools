#!/bin/bash
# llm_d 形态样本门禁（0.1.19 gen5 五件套装配）
#
# 权威依据：
#   0.1.19-架构文档.md §4.3 五件套（.manifest / main.c / svc.c / modules/ / 唯一私有头）
#   0.1.19-架构文档.md §5.4 结构规约六条
#   0.1.19-L1-SSoT收敛台账.md §33/§34 落点裁定：
#     src/ 顶层裸文件 6 → 3：main.c(生成) / svc.c(手写) / <户>_internal.h(唯一私有头)，
#     均属五件套固定落点，先留 src/ 根、不 churn 生成器；7 领域源全部入子域。
#
# 断言：
#   A1  7 域成形：src/{bootstrap,adapter,rpc,config,accounting,providers,router} 全为目录
#   A2  src/ 顶层裸文件 = 五件套固定落点 {main.c, svc.c} + 恰 1 个唯一私有头 *_internal.h
#   A3  include/ 头集 = 2 发布头 + 1 生成头（白名单集合断言，防换名漂移）
#   A4  唯一私有头及各域 internal.h 拆片后每片入度 ≤ 5
#   A5  内层域（providers/router/accounting/config）对发布头 include 边 = 0（FATAL）
#   A6  装配域（bootstrap/adapter）对发布头残余边入基线只减不增（ops 装配现实，收敛驱动）
#
# 基线：v16-sample-baseline.txt（A6 台账）；--update-baseline 重建。
# 用法: sample-form-check.sh [--update-baseline]
# 退出码: 0 = 通过；1 = 存在违例；2 = 环境错误
set -euo pipefail
# 判据与宿主 locale 无关：排序/集合比较统一走字节序
export LC_ALL=C

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

# ── A2: src/ 顶层裸文件 = 五件套固定落点 ─────────────────────
section "A2: src/ top-level bare files = five-piece landing points"
bare_bad=0
priv_heads=0
while IFS= read -r f; do
    base="${f##*/}"
    case "$base" in
        main.c|svc.c) ;;
        *_internal.h) priv_heads=$((priv_heads + 1)) ;;
        *)  log_err "unexpected bare file at src/ top level: src/${base}"
            log_err "    allowed: main.c, svc.c, one *_internal.h"
            bare_bad=$((bare_bad + 1)) ;;
    esac
done < <(find "${LLM_D}/src" -maxdepth 1 -type f | sort)
if [ "$priv_heads" -ne 1 ]; then
    log_err "src/ top-level private headers = ${priv_heads}, must be exactly 1"
    bare_bad=$((bare_bad + 1))
fi
if [ "$bare_bad" -eq 0 ]; then
    log_ok "src/ top-level = {main.c, svc.c} + 1 private head"
else
    VIOLATIONS=$((VIOLATIONS + 1))
fi

# ── A3: include/ 头集 = 2 发布头 + 1 生成头 ──────────────────
section "A3: include/ header set (2 published + 1 generated)"
expected_headers="llm_service.h daemon_llm_ops_bootstrap.h svc_llm_d.h"
actual_headers=$( ( cd "${LLM_D}/include" && ls *.h 2>/dev/null ) | sort | tr '\n' ' ' | sed 's/ $//' || true )
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
        "${LLM_D}/src" "${LLM_D}/tests" 2>/dev/null | wc -l || true)
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
for hdr in $( ( cd "${LLM_D}/include" && ls *.h 2>/dev/null ) || true ); do
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
