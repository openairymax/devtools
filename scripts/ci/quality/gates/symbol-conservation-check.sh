#!/bin/bash
# 0.1.19 G1 功能守恒门禁 —— 公开功能面符号快照双跑（方案 §6.3 G1 / 台账 §62）
#
# 立意：G1「功能守恒」的物理判据是「对外功能面不缩水」。AirymaxRT 的对外功能
#   面以 AIRY_API 标注的公开 C 函数符号为唯一权威表述（contracts 契约面）：
#   凡带 AIRY_API 的声明即对外承诺可调用，其消失即「功能消失」，不可静默发生。
# 口径（台账 §62「符号快照双跑（符号表 diff）」）：S = 生产码（排除 tests/ 与
#   third_party/）中 AIRY_API 标注的公开函数名集合。抽取必须锚定行首
#   `^\s*AIRY_API\b` 并先剔除 file:line 前缀，否则会误捕 export.h 的
#   `#define AIRY_API` 宏体（__attribute__/__declspec）与注释行；AIRY_API_REC_*
#   等宏常量因 \b 词边界（API 后接 _）天然不入集。
# 判据（双向守恒，方案 §6.3）：S0 = 基线快照，S1 = 当前工作树。
#   - 丢失方向 |S0\S1| > 0 → 硬 FAIL（对外功能消失，fail-closed）。
#   - 新增方向 |S1\S0| > 0 → FAIL，须以 --update-baseline 显式记账
#     （防漂移：公开面变更必须留痕并进入评审，与 contract-version-check 同纪律）。
#   - 两向皆空 → PASS。
# 基线：agentrt/g1-symbol-baseline.txt —— 公开功能面声明（SSoT），与工件同宿
#   （同 link-whitelist.txt 之于层界：门禁脚本在 tools，判据 SSoT 在 agentrt）。
#   故新增/收缩两向皆 fail-closed 时 PR 自包含——改面即随 PR 改基线，评审可见
#   记账，无跨仓耦合（tools 内 *-baseline.txt 为门禁棘轮态，语义不同）。
#   每行一个公开符号名，LC_ALL=C 排序去重。
# 特性：免构建、确定性、跨平台（不依赖 nm / 编译器），可在 Windows/Linux/macOS
#   源码树直接双跑。
# 用法: symbol-conservation-check.sh [--update-baseline]
# 退出码: 0 = 通过；1 = 公开面变更（丢失或未记账的新增）；2 = 环境错误
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
AGENTRT="${PROJECT_ROOT}/agent-workload/agentrt"
# 基线宿主 agentrt（判据 SSoT 与工件同宿，改面随 PR 记账；见头注释）
BASELINE="$AGENTRT/g1-symbol-baseline.txt"

UPDATE_BASELINE=0
if [ "${1:-}" = "--update-baseline" ]; then
    UPDATE_BASELINE=1
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

# 抽取 S1：生产码内 AIRY_API 公开函数符号集（确定性；先剔除 file:line 前缀再锚定）
extract_surface() {
    grep -rn "AIRY_API" --include=*.h --include=*.c "$AGENTRT" 2>/dev/null \
        | { grep -v '/tests/' || true; } \
        | { grep -v '/third_party/' || true; } \
        | cut -d: -f3- \
        | grep -oP '^\s*AIRY_API\b[^;{}]*?\b\K[A-Za-z_]\w*(?=\s*\()' \
        || true
}

count_lines() {
    local n
    n="$(printf '%s' "$1" | grep -c . || true)"
    echo "${n:-0}"
}

if [ ! -d "$AGENTRT" ]; then
    log_err "agentrt source tree not found: ${AGENTRT}"
    exit 2
fi

CUR_FILE="$(mktemp)"
trap 'rm -f "$CUR_FILE"' EXIT

extract_surface | LC_ALL=C sort -u > "$CUR_FILE"
cur_count="$(wc -l < "$CUR_FILE" | tr -d ' ')"

section "0.1.19 G1 functional-conservation gate (public surface: AIRY_API symbols)"

if [ "$UPDATE_BASELINE" -eq 1 ]; then
    added=""
    removed=""
    if [ -f "$BASELINE" ]; then
        added="$(comm -13 "$BASELINE" "$CUR_FILE" || true)"
        removed="$(comm -23 "$BASELINE" "$CUR_FILE" || true)"
    else
        added="$(cat "$CUR_FILE")"
    fi
    cp "$CUR_FILE" "$BASELINE"
    a_n="$(count_lines "$added")"
    r_n="$(count_lines "$removed")"
    log_ok "baseline re-recorded: ${cur_count} symbols (+${a_n} / -${r_n})"
    if [ "$a_n" -gt 0 ]; then
        echo "  added:"; printf '%s\n' "$added" | sed 's/^/    + /'
    fi
    if [ "$r_n" -gt 0 ]; then
        echo "  removed:"; printf '%s\n' "$removed" | sed 's/^/    - /'
    fi
    log_ok "0.1.19 G1 symbol-conservation gate PASSED (baseline re-recorded)"
    exit 0
fi

if [ ! -f "$BASELINE" ]; then
    log_err "baseline not found: ${BASELINE} (seed with: $0 --update-baseline)"
    exit 2
fi

base_count="$(grep -c . "$BASELINE" || true)"
lost="$(comm -23 "$BASELINE" "$CUR_FILE" || true)"
added="$(comm -13 "$BASELINE" "$CUR_FILE" || true)"
lost_n="$(count_lines "$lost")"
added_n="$(count_lines "$added")"

echo "  baseline S0: ${base_count} symbols"
echo "  current  S1: ${cur_count} symbols"

rc=0
if [ "$lost_n" -gt 0 ]; then
    log_err "lost |S0\\S1|=${lost_n} public symbols (functionality regression, fail-closed):"
    printf '%s\n' "$lost" | sed 's/^/    - /'
    rc=1
fi
if [ "$added_n" -gt 0 ]; then
    log_err "new |S1\\S0|=${added_n} public symbols require explicit accounting:"
    printf '%s\n' "$added" | sed 's/^/    + /'
    log_err "run '$0 --update-baseline' to record the public-surface change (must enter review)"
    rc=1
fi

if [ "$rc" -eq 0 ]; then
    log_ok "public surface conserved: |S0\\S1|=0 and |S1\\S0|=0 (${cur_count} symbols)"
    log_ok "0.1.19 G1 symbol-conservation gate PASSED"
fi
exit "$rc"
