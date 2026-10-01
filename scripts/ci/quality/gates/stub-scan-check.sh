#!/bin/bash
# 0.1.19 G6 禁桩门禁（方案 §0.5 G6；铁律「严禁桩函数、桩实现」）
#
# 口径（台账 §0.1 / §1.2）：agentrt/ 下 *.c + *.h，排除 tests/。
# 判据：生产码内零未竟标记——TODO / FIXME / XXX / HACK / STUB（大写约定、
#   词边界）与 `#if 0` 死码块，任一命中即 FAIL（零容忍，无基线放宽）。
#   仅匹配大写标记：小写 `xxx` 系文档占位符（如 `builtin:xxx`），非桩标记；
#   注释内的 "not a stub" 等说明性小写用法亦不误伤。
# 用法: stub-scan-check.sh
# 退出码: 0 = 通过；1 = 存在桩标记；2 = 环境错误（树缺失）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
AGENTRT="${PROJECT_ROOT}/agent-workload/agentrt"

MODULES=(atoms commons daemons cupolas gateway heapstore protocols tools)

PATTERN='\b(TODO|FIXME|XXX|HACK|STUB)\b|^[[:space:]]*#[[:space:]]*if[[:space:]]+0([^[:alnum:]_]|$)'

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

log_ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err()  { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section()  { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

if [ ! -d "$AGENTRT" ]; then
    log_err "agentrt source tree not found: ${AGENTRT}"
    exit 2
fi

section "0.1.19 G6 stub-scan gate (zero-tolerance: TODO/FIXME/XXX/HACK/STUB, #if 0)"

violations=0
for m in "${MODULES[@]}"; do
    d="$AGENTRT/$m"
    if [ ! -d "$d" ]; then
        log_err "module tree missing: ${d}"
        exit 2
    fi
    hits=$(find "$d" -type f \( -name '*.c' -o -name '*.h' \) \
        | { grep -v '/tests/' || true; } | tr '\n' '\0' \
        | xargs -0 -r grep -InE "$PATTERN" || true)
    if [ -n "$hits" ]; then
        while IFS= read -r line; do
            log_err "$line"
        done <<< "$hits"
        n=$(printf '%s\n' "$hits" | wc -l)
        violations=$((violations + n))
    fi
done

section "0.1.19 G6 stub-scan gate"
if [ "$violations" -eq 0 ]; then
    log_ok "no unfinished-work markers in production sources"
    log_ok "0.1.19 G6 stub-scan gate PASSED"
    exit 0
else
    log_err "found ${violations} unfinished-work marker(s) — stubs are forbidden"
    log_err "0.1.19 G6 stub-scan gate FAILED"
    exit 1
fi
