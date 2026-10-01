#!/bin/bash
# AgentRT 代码质量检查入口（薄封装）
#
# 立意：门禁的唯一实现在 gates/ 下——G25 圈复杂度门禁 complexity-check.sh、
#   G26 重复率门禁 clone-check.sh；阈值统一取自 thresholds.conf（唯一权威源）。
#   本脚本不再自行实现任何检查（旧版内联 5.0/3.5/10 阈值、且调用了 jscpd/lizard
#   并不存在的 --manager 选项），仅顺序调用二者并汇总退出码，消除双轨口径漂移。
# 用法: check-quality.sh
# 退出码: 0 = 全部通过；2 = 存在告警（无阻断）；1 = 存在阻断；3 = 环境错误
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CX_GATE="${SCRIPT_DIR}/gates/complexity-check.sh"
DUP_GATE="${SCRIPT_DIR}/gates/clone-check.sh"

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

main() {
    local missing=0
    [ -f "$CX_GATE" ]  || { log_err "missing gate: ${CX_GATE}"; missing=1; }
    [ -f "$DUP_GATE" ] || { log_err "missing gate: ${DUP_GATE}"; missing=1; }
    [ "$missing" -eq 0 ] || return 3

    local cx_rc=0 dup_rc=0

    section "G25 complexity (thresholds from thresholds.conf)"
    bash "$CX_GATE" || cx_rc=$?

    section "G26 duplication (target/ceiling from thresholds.conf)"
    bash "$DUP_GATE" || dup_rc=$?

    section "Quality check summary"
    log_info "complexity gate rc=${cx_rc}, duplication gate rc=${dup_rc}"

    local rc=0
    if [ "$cx_rc" -eq 3 ] || [ "$dup_rc" -eq 3 ]; then
        rc=3
    elif [ "$cx_rc" -eq 1 ] || [ "$dup_rc" -eq 1 ]; then
        rc=1
    elif [ "$cx_rc" -eq 2 ] || [ "$dup_rc" -eq 2 ]; then
        rc=2
    fi

    case "$rc" in
        0) log_ok "quality checks passed" ;;
        2) log_warn "quality checks passed with warnings" ;;
        3) log_err "quality checks: environment error" ;;
        *) log_err "quality checks failed" ;;
    esac
    return "$rc"
}

main "$@"
