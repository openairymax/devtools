#!/bin/bash
# V16.1 上限轨 (0.1.18 plan §12.16.7): daemons/* LOC 上限门禁
#
# 规则（0.1.18-架构改进方案.md:1948）：
#   ① 上限轨——全 daemons/* 的 LOC < 9,000（口径：src/ + 本模块 include/，
#      排除 tests/；common 不享隐式豁免，另走 V16.6 口径裁决）；
#   ② 最小完备轨（每 daemon 清理单，V16.14）为流程判据，不在本脚本断言。
#   超标者仅允许附清理任务号的豁免（同 B14-1 机制，登记于基线文件）。
#
# 基线：v16-loc-ceiling-baseline.txt —— 每行 <daemon>|<登记时LOC>|<豁免任务号>；
#   豁免条目 LOC 只减不增：增长即 FAIL（豁免是清理过渡态，不是增长许可）；
#   清理落地后 --update-baseline 以当前值刷新超标条目（保留 ref；达标条目移除）。
# 用法: loc-ceiling-check.sh [--update-baseline]
# 退出码: 0 = 通过；1 = 存在违例
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
AGENTRT="${PROJECT_ROOT}/agent-workload/agentrt"
DAEMONS_DIR="${AGENTRT}/daemons"
BASELINE="$SCRIPT_DIR/v16-loc-ceiling-baseline.txt"
LOC_CEILING=9000
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

if [ ! -d "$DAEMONS_DIR" ]; then
    log_err "daemons source tree not found: ${DAEMONS_DIR}"
    exit 2
fi

violations=0
declare -a UPDATE_LINES=()

section "V16.1 LOC ceiling gate (ceiling=${LOC_CEILING}, scope: src/ + include/, tests/ excluded)"

for dir_path in "$DAEMONS_DIR"/*/; do
    name="$(basename "$dir_path")"
    # 无 src/ 且无 include/ 的顶层条目（scripts 等）不在 LOC 口径内
    if [ ! -d "$dir_path/src" ] && [ ! -d "$dir_path/include" ]; then
        continue
    fi
    # 仅对存在的目录 find：find 对不存在路径会 exit 1，pipefail 下不可容忍
    scan_paths=()
    if [ -d "$dir_path/src" ]; then scan_paths+=("$dir_path/src"); fi
    if [ -d "$dir_path/include" ]; then scan_paths+=("$dir_path/include"); fi
    loc=$(find "${scan_paths[@]}" -type f \( -name '*.c' -o -name '*.h' \) \
          | { grep -v '/tests/' || true; } | tr '\n' '\0' | xargs -0 -r cat | wc -l)
    if [ "$loc" -lt "$LOC_CEILING" ]; then
        log_ok "$name loc=$loc (< ${LOC_CEILING})"
        continue
    fi
    entry=$(grep -m1 "^${name}|" "$BASELINE" 2>/dev/null || true)
    reg_loc="$(echo "$entry" | cut -d'|' -f2)"
    ref="$(echo "$entry" | cut -d'|' -f3)"
    if [ -z "$entry" ] || [ -z "$reg_loc" ] || [ -z "$ref" ]; then
        log_err "$name loc=$loc exceeds ceiling ${LOC_CEILING}, no baseline entry with exemption ref (V16.1/B14-1)"
        violations=$((violations + 1))
        continue
    fi
    if [ "$UPDATE_BASELINE" -eq 1 ]; then
        UPDATE_LINES+=("${name}|${loc}|${ref}")
        log_warn "$name baseline entry refreshed: loc=${loc} (ref=${ref})"
        continue
    fi
    if [ "$loc" -gt "$reg_loc" ]; then
        log_err "$name loc=$loc grew beyond registered ${reg_loc} (ref=${ref}) — exemption is a cleanup transition, not a growth permit"
        violations=$((violations + 1))
    elif [ "$loc" -lt "$reg_loc" ]; then
        log_warn "$name loc=$loc shrunk below registered ${reg_loc} (ref=${ref}) — consider --update-baseline"
    else
        log_ok "$name loc=$loc (exempted, ref=${ref})"
    fi
done

if [ "$UPDATE_BASELINE" -eq 1 ]; then
    : > "$BASELINE"
    for line in "${UPDATE_LINES[@]:-}"; do
        [ -n "$line" ] && echo "$line" >> "$BASELINE"
    done
    echo "baseline rewritten: $BASELINE (${#UPDATE_LINES[@]} entries)"
fi

section "V16.1 loc-ceiling gate"
if [ "$violations" -eq 0 ]; then
    log_ok "V16.1 loc-ceiling gate PASSED"
    exit 0
else
    log_err "V16.1 loc-ceiling gate FAILED"
    exit 1
fi
