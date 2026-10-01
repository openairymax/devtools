#!/bin/bash
# 0.1.19 G2 体积硬门禁 + 里程碑阶梯（方案 §0.2 阶梯执法 / §0.5 G2）
#
# 口径（台账 §0.1）：agentrt/ 八模块（atoms commons daemons cupolas gateway
#   heapstore protocols tools）下 *.c + *.h，排除 tests/，另计 cmake/ 组织码。
# 阶梯（方案 §0.2）：M1 ≤348,000 / M2 ≤313,000 / M3 ≤312,000 / M4 ≤293,000 /
#   M5 ≤243,000 / M6 ≤232,000 / M7 ≤184,000 / M8 ≤121,000 / M9 ≤117,000 /
#   M10 <100,000。
# 判据：实测总量 ≤ 当前 pin 里程碑上限即 PASS；超出即 FAIL——未达阶梯值即
#   停线整改，不得带入下一里程碑。实测已达下一里程碑时以 --advance 推进 pin。
# 基线：v16-loc-budget-baseline.txt —— 每行 <键>=<值>；current=<M#>。
# 用法: loc-budget-check.sh [--advance]
# 退出码: 0 = 通过；1 = 超出当前上限；2 = 环境错误（树/基线缺失）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
AGENTRT="${PROJECT_ROOT}/agent-workload/agentrt"
BASELINE="$SCRIPT_DIR/v16-loc-budget-baseline.txt"

MODULES=(atoms commons daemons cupolas gateway heapstore protocols tools)

# 里程碑阶梯：名 -> 上限（M10 为 <100,000，取 99,999 作计数断言）
MILESTONES=(M1 M2 M3 M4 M5 M6 M7 M8 M9 M10)
CEIL_M1=348000
CEIL_M2=313000
CEIL_M3=312000
CEIL_M4=293000
CEIL_M5=243000
CEIL_M6=232000
CEIL_M7=184000
CEIL_M8=121000
CEIL_M9=117000
CEIL_M10=99999

ADVANCE=0
if [ "${1:-}" = "--advance" ]; then
    ADVANCE=1
fi

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_YELLOW='\033[0;33m'
COLOR_RESET='\033[0m'

log_ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*"; }
log_err()  { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section()  { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

ceil_of() {
    local var="CEIL_$1"
    echo "${!var}"
}

idx_of() {
    local i
    for i in "${!MILESTONES[@]}"; do
        if [ "${MILESTONES[$i]}" = "$1" ]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

if [ ! -d "$AGENTRT" ]; then
    log_err "agentrt source tree not found: ${AGENTRT}"
    exit 2
fi

if [ ! -f "$BASELINE" ]; then
    log_err "baseline not found: ${BASELINE} (expected line: current=<M#>)"
    exit 2
fi

current="$(sed -n 's/^current=//p' "$BASELINE" | head -n1)"
if [ -z "$current" ]; then
    log_err "baseline missing 'current=' key: ${BASELINE}"
    exit 2
fi

cur_idx="$(idx_of "$current")" || {
    log_err "unknown milestone in baseline: current=${current}"
    exit 2
}

section "0.1.19 G2 LOC budget gate (pin=${current}, scope: 8 modules + cmake/, tests/ excluded)"

total=0
for m in "${MODULES[@]}"; do
    d="$AGENTRT/$m"
    if [ ! -d "$d" ]; then
        log_err "module tree missing: ${d}"
        exit 2
    fi
    n=$(find "$d" -type f \( -name '*.c' -o -name '*.h' \) \
        | { grep -v '/tests/' || true; } | tr '\n' '\0' | xargs -0 -r cat | wc -l)
    total=$((total + n))
    printf '  %-10s %8d\n' "$m" "$n"
done

cmake_loc=0
if [ -d "$AGENTRT/cmake" ]; then
    cmake_loc=$(find "$AGENTRT/cmake" -type f \( -name '*.c' -o -name '*.h' \) \
        | tr '\n' '\0' | xargs -0 -r cat | wc -l)
fi
total=$((total + cmake_loc))
printf '  %-10s %8d\n' "cmake" "$cmake_loc"
echo "  ----------------------"
printf '  %-10s %8d\n' "TOTAL" "$total"

ceiling="$(ceil_of "$current")"
next_idx=$((cur_idx + 1))

if [ "$ADVANCE" -eq 1 ]; then
    if [ "$next_idx" -ge "${#MILESTONES[@]}" ]; then
        log_err "--advance: ${current} is the terminal milestone"
        exit 2
    fi
    next="${MILESTONES[$next_idx]}"
    next_ceiling="$(ceil_of "$next")"
    if [ "$total" -gt "$next_ceiling" ]; then
        log_err "--advance refused: total=$total exceeds ${next} ceiling=${next_ceiling}"
        exit 1
    fi
    echo "current=${next}" > "$BASELINE"
    log_ok "milestone advanced: ${current} -> ${next} (total=${total} <= ${next_ceiling})"
    current="$next"
    ceiling="$next_ceiling"
    cur_idx="$next_idx"
    next_idx=$((next_idx + 1))
fi

section "0.1.19 G2 loc-budget gate"

if [ "$total" -gt "$ceiling" ]; then
    log_err "total=${total} exceeds pin ${current} ceiling=${ceiling} by $((total - ceiling))"
    log_err "阶梯执法：未达阶梯值即停线整改，不得带入下一里程碑"
    exit 1
fi

log_ok "total=${total} <= ${current} ceiling=${ceiling} (slack=$((ceiling - total)))"

if [ "$next_idx" -lt "${#MILESTONES[@]}" ]; then
    next="${MILESTONES[$next_idx]}"
    next_ceiling="$(ceil_of "$next")"
    if [ "$total" -le "$next_ceiling" ]; then
        log_warn "next milestone ${next} (<=${next_ceiling}) already met — run --advance"
    else
        log_warn "gap to ${next} ceiling=${next_ceiling}: $((total - next_ceiling))"
    fi
fi

log_ok "0.1.19 G2 loc-budget gate PASSED"
exit 0
