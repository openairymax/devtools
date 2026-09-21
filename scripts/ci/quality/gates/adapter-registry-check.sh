#!/bin/bash
# V16.11 (0.1.18 plan §12.16.3): llm_d 适配注册门禁
#
# 断言（0.1.18-架构改进方案.md:1959）：
#   A1  adapters/adapter_table.c 存在且含注册表（g_adapter_table）
#   A2  adapters/*.c 零直接 I/O 调用（出网唯一入口 = providers/core provider_http_exec）
#   A3  表驱动完整性：adapters/*.c 定义的 provider_adapter_t 单例与
#       adapter_table.c 表内符号集合完全一致（新增厂商唯一改动点 = 表尾加行 + 单文件）
#
# 用法: adapter-registry-check.sh
# 退出码: 0 = 通过；1 = 存在违例
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
ADAPTERS="${PROJECT_ROOT}/agent-workload/agentrt/daemons/llm_d/src/providers/adapters"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

log_ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}    $*"; }
log_err()  { echo -e "${COLOR_RED}[ERR]${COLOR_RESET}   $*"; }
section()  { echo -e "\n${COLOR_CYAN}═══ $1 ═══${COLOR_RESET}"; }

VIOLATIONS=0

if [ ! -d "$ADAPTERS" ]; then
    log_err "adapters dir not found: ${ADAPTERS}"
    exit 2
fi

# ── A1: 注册表存在 ───────────────────────────────────────────
section "A1: adapter_table.c registry"
TABLE="${ADAPTERS}/adapter_table.c"
if [ ! -f "$TABLE" ]; then
    log_err "adapter_table.c missing"
    exit 1
fi
if grep -q 'g_adapter_table\[\]' "$TABLE"; then
    log_ok "g_adapter_table[] registry present"
else
    log_err "g_adapter_table[] registry not found in adapter_table.c"
    VIOLATIONS=$((VIOLATIONS + 1))
fi

# ── A2: 零直接 I/O ───────────────────────────────────────────
section "A2: no direct I/O in adapters/*.c"
IO_RE='(fork|execv[pe]*|system|popen|fopen|open|socket|connect|listen|bind|accept|opendir|mkdir)\('
io_hits=$(grep -rnE "$IO_RE" "${ADAPTERS}"/*.c 2>/dev/null | \
    grep -v '^\s*[^:]*:[0-9]*:\s*\*\|/\*\|^\s*\*\|\*/' | \
    grep -v 'provider_http_exec' || true)
if [ -z "$io_hits" ]; then
    log_ok "adapters/*.c: zero direct I/O calls"
else
    log_err "direct I/O calls found in adapters/*.c:"
    echo "$io_hits" | sed "s|${ADAPTERS}/|    |"
    VIOLATIONS=$((VIOLATIONS + 1))
fi

# ── A3: 表驱动完整性 ─────────────────────────────────────────
section "A3: table-driven completeness"
# 适配文件中定义的单例：const provider_adapter_t NAME = {
defined=$(grep -hE '^const provider_adapter_t [a-z_0-9]+ =' \
    "${ADAPTERS}"/*.c 2>/dev/null | sed -E 's/const provider_adapter_t ([a-z_0-9]+).*/\1/' | sort -u || true)
# 表体引用的符号：g_adapter_table[] 块内的 &NAME
in_table=$(sed -n '/g_adapter_table\[\]/,/};/p' "$TABLE" 2>/dev/null | \
    grep -oE '&[a-z_0-9]+' | sed 's/^&//' | sort -u || true)
defined_missing=0
for sym in $defined; do
    if echo "$in_table" | grep -qx "$sym"; then
        log_ok "registered: ${sym}"
    else
        log_err "adapter singleton defined but NOT in table: ${sym}"
        VIOLATIONS=$((VIOLATIONS + 1))
        defined_missing=1
    fi
done
# 表内符号反向核对定义存在
for sym in $in_table; do
    if ! echo "$defined" | grep -qx "$sym"; then
        log_err "table references undefined adapter: ${sym}"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
done
if [ "$defined_missing" -eq 0 ] && [ -n "$defined" ]; then
    log_ok "table <-> definitions consistent ($(echo "$defined" | wc -l) adapters)"
fi

echo ""
if [ "$VIOLATIONS" -eq 0 ]; then
    log_ok "V16.11 adapter-registry gate PASSED"
    exit 0
else
    log_err "V16.11 adapter-registry gate FAILED: ${VIOLATIONS} violation(s)"
    exit 1
fi
